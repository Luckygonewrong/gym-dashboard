-- 006: Iron House admin: kitne gym jude, 7 din trial, ₹2000/month, gym ka data, Excel export
-- (005 ke baad chalao. Naye project pe sirf schema.sql kaafi hai.)
-- Admin banane ke liye (SQL Editor mein, apne email se):
--   insert into public.admins (user_id) select id from auth.users where lower(email) = lower('tumhara@email.com');

-- ========== private schema: API (PostgREST) se nahi dikhta ==========
create schema if not exists private;
revoke all on schema private from public;

-- ========== admins: koi API se padh/likh nahi sakta, sirf SQL Editor ==========
create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ========== gyms (tumhare customers) ==========
create table if not exists public.gyms (
  id            bigint generated always as identity primary key,
  gym_name      text not null check (length(trim(gym_name)) > 0),
  owner_name    text not null check (length(trim(owner_name)) > 0),
  owner_email   text not null check (owner_email ~ '^[^@\s]+@[^@\s]+$'),
  phone         text check (phone ~ '^[6-9][0-9]{9}$'),
  city          text,
  monthly_price integer not null default 2000 check (monthly_price >= 0),
  trial_start   date not null default (now() at time zone 'Asia/Kolkata')::date,
  paid_until    date,
  note          text,
  created_at    timestamptz not null default now()
);
create unique index if not exists gyms_owner_email on public.gyms (lower(owner_email));

create table if not exists public.gym_payments (
  id         bigint generated always as identity primary key,
  gym_id     bigint not null references public.gyms(id) on delete cascade,
  amount     integer not null check (amount >= 0),
  days       integer not null check (days > 0),
  paid_on    date not null default (now() at time zone 'Asia/Kolkata')::date,
  mode       text not null default 'Online' check (mode in ('Cash','Online')),
  note       text,
  created_at timestamptz not null default now()
);

alter table public.gyms         enable row level security;
alter table public.gym_payments enable row level security;
drop policy if exists "admin gyms" on public.gyms;
drop policy if exists "admin gym payments" on public.gym_payments;
create policy "admin gyms" on public.gyms for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "admin gym payments" on public.gym_payments for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.gyms, public.gym_payments to authenticated;
revoke all on public.gyms, public.gym_payments from anon;

-- ========== gym ka subscription payment: paid_until aage badhao ==========
-- Trial 7 din: trial_start se trial_start + 6 tak (dono din shamil).
create or replace function public.admin_gym_paid(
  p_gym    bigint,
  p_amount integer,
  p_days   integer default 30,
  p_mode   text default 'Online',
  p_note   text default null
) returns date
language plpgsql
security invoker            -- gyms pe admin RLS lagu
set search_path = public
as $$
declare
  g        public.gyms;
  today    date := (now() at time zone 'Asia/Kolkata')::date;
  new_till date;
begin
  if not public.is_admin() then raise exception 'Sirf admin'; end if;
  select * into g from public.gyms where id = p_gym for update;
  if not found then raise exception 'Gym nahi mila'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'Amount galat hai'; end if;
  if p_days is null or p_days <= 0 then raise exception 'Din galat hain'; end if;

  new_till := greatest(coalesce(g.paid_until, g.trial_start + 6), today) + p_days;
  insert into public.gym_payments (gym_id, amount, days, mode, note)
  values (p_gym, p_amount, p_days, coalesce(p_mode, 'Online'), nullif(trim(p_note), ''));
  update public.gyms set paid_until = new_till where id = p_gym;
  return new_till;
end $$;

-- ========== har gym ka hisaab (andar ka function, API se nahi chalta) ==========
create or replace function private.gym_overview()
returns table (
  gym_id bigint, gym_name text, owner_name text, owner_email text, phone text, city text,
  monthly_price integer, trial_start date, trial_end date, paid_until date,
  status text, days_left integer, login_created boolean, last_login date,
  members bigint, overdue_members bigint, pending_amount bigint,
  collected_this_month bigint, paid_to_you bigint
)
language sql
stable
security definer
set search_path = public
as $$
  with t as (select (now() at time zone 'Asia/Kolkata')::date as today)
  select g.id, g.gym_name, g.owner_name, g.owner_email, g.phone, g.city,
         g.monthly_price, g.trial_start, g.trial_start + 6, g.paid_until,
         case when g.paid_until >= t.today then 'Paid'
              when g.trial_start + 6 >= t.today then 'Trial'
              else 'Expired' end,
         greatest(g.trial_start + 6, coalesce(g.paid_until, g.trial_start + 6)) - t.today,
         u.id is not null,
         (u.last_sign_in_at at time zone 'Asia/Kolkata')::date,
         coalesce(ms.members, 0), coalesce(ms.overdue, 0), coalesce(ms.pending, 0),
         coalesce(ps.this_month, 0), coalesce(gp.total, 0)
  from public.gyms g
  cross join t
  left join auth.users u on lower(u.email) = lower(g.owner_email)
  left join lateral (
    select count(*) as members,
           count(*) filter (where m.due < t.today) as overdue,
           coalesce(sum(m.fee) filter (where m.due < t.today), 0) as pending
    from public.members m where m.owner_id = u.id
  ) ms on true
  left join lateral (
    select sum(p.amount) as this_month
    from public.payments p
    where p.owner_id = u.id and p.paid_on >= date_trunc('month', t.today)::date
  ) ps on true
  left join lateral (
    select sum(x.amount) as total from public.gym_payments x where x.gym_id = g.id
  ) gp on true
  order by g.created_at, g.id;
$$;

-- ========== saare gyms ke members (Excel ke liye) ==========
create or replace function private.members_export()
returns table (
  gym_name text, owner_email text, member_name text, phone text, plan text,
  fee integer, due date, status text, days_left integer
)
language sql
stable
security definer
set search_path = public
as $$
  with t as (select (now() at time zone 'Asia/Kolkata')::date as today)
  select g.gym_name, g.owner_email, m.name, m.phone, m.plan, m.fee, m.due,
         case when m.due < t.today then 'Overdue'
              when m.due <= t.today + 7 then 'Due soon'
              else 'Active' end,
         m.due - t.today
  from public.gyms g
  cross join t
  join auth.users u on lower(u.email) = lower(g.owner_email)
  join public.members m on m.owner_id = u.id
  order by g.gym_name, m.due, m.id;
$$;

revoke execute on function private.gym_overview() from public;
revoke execute on function private.members_export() from public;

-- ========== admin page ke liye (login wala admin) ==========
create or replace function public.admin_gym_overview()
returns table (
  gym_id bigint, gym_name text, owner_name text, owner_email text, phone text, city text,
  monthly_price integer, trial_start date, trial_end date, paid_until date,
  status text, days_left integer, login_created boolean, last_login date,
  members bigint, overdue_members bigint, pending_amount bigint,
  collected_this_month bigint, paid_to_you bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Sirf admin'; end if;
  return query select * from private.gym_overview();
end $$;

create or replace function public.admin_members_export()
returns table (
  gym_name text, owner_email text, member_name text, phone text, plan text,
  fee integer, due date, status text, days_left integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Sirf admin'; end if;
  return query select * from private.members_export();
end $$;

-- ========== Excel live link: secret token se (login ke bina) ==========
-- Token ka sirf hash save hota hai. Naya token banane se purane band nahi hote;
-- band karne ke liye admin_revoke_export_tokens().
create table if not exists private.export_tokens (
  token_hash text primary key,
  label      text,
  created_at timestamptz not null default now(),
  revoked    boolean not null default false
);

create or replace function private.check_token(p_token text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_token is null or length(p_token) < 32 or not exists (
    select 1 from private.export_tokens
    where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex') and not revoked
  ) then
    raise exception 'Token galat hai ya band ho chuka hai';
  end if;
end $$;
revoke execute on function private.check_token(text) from public;

create or replace function public.admin_new_export_token(p_label text default 'Excel')
returns text
language plpgsql
volatile
security definer
set search_path = public
as $$
declare tok text;
begin
  if not public.is_admin() then raise exception 'Sirf admin'; end if;
  tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into private.export_tokens (token_hash, label)
  values (encode(sha256(convert_to(tok, 'UTF8')), 'hex'), nullif(trim(p_label), ''));
  return tok;
end $$;

create or replace function public.admin_revoke_export_tokens()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare n integer;
begin
  if not public.is_admin() then raise exception 'Sirf admin'; end if;
  update private.export_tokens set revoked = true where not revoked;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.export_gyms(p_token text)
returns table (
  gym_id bigint, gym_name text, owner_name text, owner_email text, phone text, city text,
  monthly_price integer, trial_start date, trial_end date, paid_until date,
  status text, days_left integer, login_created boolean, last_login date,
  members bigint, overdue_members bigint, pending_amount bigint,
  collected_this_month bigint, paid_to_you bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform private.check_token(p_token);
  return query select * from private.gym_overview();
end $$;

create or replace function public.export_members(p_token text)
returns table (
  gym_name text, owner_email text, member_name text, phone text, plan text,
  fee integer, due date, status text, days_left integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform private.check_token(p_token);
  return query select * from private.members_export();
end $$;

-- ========== permissions ==========
revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.admin_gym_paid(bigint, integer, integer, text, text) from public, anon;
revoke execute on function public.admin_gym_overview() from public, anon;
revoke execute on function public.admin_members_export() from public, anon;
revoke execute on function public.admin_new_export_token(text) from public, anon;
revoke execute on function public.admin_revoke_export_tokens() from public, anon;
revoke execute on function public.export_gyms(text) from public;
revoke execute on function public.export_members(text) from public;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.admin_gym_paid(bigint, integer, integer, text, text) to authenticated;
grant execute on function public.admin_gym_overview() to authenticated;
grant execute on function public.admin_members_export() to authenticated;
grant execute on function public.admin_new_export_token(text) to authenticated;
grant execute on function public.admin_revoke_export_tokens() to authenticated;
grant execute on function public.export_gyms(text) to anon, authenticated;
grant execute on function public.export_members(text) to anon, authenticated;
