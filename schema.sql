-- Gym owner dashboard: poora Supabase schema (naye project ke liye)
-- Supabase → SQL Editor → New query → ye poora paste karke Run karo.
-- Already-live project pe ise mat chalao: wahan migrations/ folder ki files order mein chalao.

-- ========== Tables ==========
create table if not exists public.members (
  id          bigint generated always as identity primary key,
  owner_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name        text not null check (length(trim(name)) > 0),
  phone       text not null check (phone ~ '^[6-9][0-9]{9}$'),
  plan        text not null check (plan in ('Monthly','Quarterly','Half-yearly','Yearly')),
  fee         integer not null check (fee >= 0),
  due         date not null,
  reminded_on date,
  created_at  timestamptz not null default now()
);

create table if not exists public.payments (
  id         bigint generated always as identity primary key,
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  member_id  bigint references public.members(id) on delete set null,
  amount     integer not null check (amount >= 0),
  paid_on    date not null default (now() at time zone 'Asia/Kolkata')::date,
  created_at timestamptz not null default now(),
  plan       text check (plan in ('Monthly','Quarterly','Half-yearly','Yearly')),
  mode       text not null default 'Cash',
  note       text,
  constraint payments_mode_check check (mode in ('Cash','Online','UPI','Card','Bank'))
);

create table if not exists public.settings (
  owner_id  uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  template  text not null default
    'Namaste {name}! Aapki {plan} fees ₹{amount} ki due date {date} hai. Please time pe jama kar dein. Dhanyavaad 🙏',
  plan_fees jsonb not null default '{"Monthly":1200,"Quarterly":3300,"Half-yearly":6000,"Yearly":10500}'::jsonb
);

create index if not exists members_owner_due on public.members (owner_id, due);
create index if not exists payments_owner_date on public.payments (owner_id, paid_on);
create unique index if not exists members_owner_phone on public.members (owner_id, phone);

-- ========== API access (sirf logged-in users; RLS neeche filter karta hai) ==========
grant usage on schema public to authenticated;
grant select, insert, update, delete on public.members, public.payments, public.settings to authenticated;
revoke all on public.members, public.payments, public.settings from anon;

-- ========== Row Level Security: har owner sirf apna data dekhe ==========
alter table public.members  enable row level security;
alter table public.payments enable row level security;
alter table public.settings enable row level security;

drop policy if exists "own members"  on public.members;
drop policy if exists "own payments" on public.payments;
drop policy if exists "own settings" on public.settings;

create policy "own members"  on public.members  for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "own payments" on public.payments for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "own settings" on public.settings for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- ========== Plan ki standard fee (settings, warna default) ==========
create or replace function public.plan_fee(p_owner uuid, p_plan text)
returns integer
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(
    (select (s.plan_fees ->> p_plan)::int from public.settings s where s.owner_id = p_owner),
    case p_plan when 'Monthly' then 1200 when 'Quarterly' then 3300
                when 'Half-yearly' then 6000 when 'Yearly' then 10500 end
  );
$$;

-- ========== Payment: plan switch, Cash/Online, aaj se ya due date se ==========
-- p_from: 'today' = aaj se, 'due' = jab se due tha, 'auto' = jo baad mein ho
create or replace function public.record_payment(
  p_member  bigint,
  p_plan    text,
  p_amount  integer,
  p_mode    text default 'Cash',
  p_paid_on date default null,
  p_note    text default null,
  p_from    text default 'auto'
) returns date
language plpgsql
security invoker            -- RLS lagu rehta hai
set search_path = public
as $$
declare
  m       public.members;
  paid    date := coalesce(p_paid_on, (now() at time zone 'Asia/Kolkata')::date);
  months  int;
  start   date;
  new_due date;
begin
  select * into m from public.members where id = p_member for update;
  if not found then raise exception 'Member nahi mila'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'Amount galat hai'; end if;

  months := case p_plan when 'Monthly' then 1 when 'Quarterly' then 3
                        when 'Half-yearly' then 6 when 'Yearly' then 12 end;
  if months is null then raise exception 'Plan galat hai: %', p_plan; end if;

  start := case p_from when 'today' then paid
                       when 'due'   then m.due
                       else greatest(m.due, paid) end;
  new_due := (start + make_interval(months => months))::date;

  insert into public.payments (member_id, amount, paid_on, plan, mode, note)
  values (p_member, p_amount, paid, p_plan, coalesce(p_mode, 'Cash'), nullif(trim(p_note), ''));

  -- discount sirf is payment pe; plan badla toh member ki fee = naye plan ki standard fee
  update public.members
     set plan = p_plan,
         fee = case when p_plan = m.plan then m.fee else public.plan_fee(m.owner_id, p_plan) end,
         due = new_due,
         reminded_on = null
   where id = p_member;
  return new_due;
end $$;

-- ========== Dashboard: mahine ka total database mein hi jodo ==========
create or replace function public.monthly_collection(p_months integer default 6)
returns table (month date, total bigint, payments bigint)
language sql
stable
security invoker
set search_path = public
as $$
  select date_trunc('month', p.paid_on)::date, sum(p.amount), count(*)
  from public.payments p
  where p.paid_on >= (date_trunc('month', (now() at time zone 'Asia/Kolkata')::date)
                      - make_interval(months => greatest(p_months, 1) - 1))::date
  group by 1
  order by 1;
$$;

revoke execute on function public.plan_fee(uuid, text) from public, anon;
revoke execute on function public.record_payment(bigint, text, integer, text, date, text, text) from public, anon;
revoke execute on function public.monthly_collection(integer) from public, anon;
grant  execute on function public.plan_fee(uuid, text) to authenticated;
grant  execute on function public.record_payment(bigint, text, integer, text, date, text, text) to authenticated;
grant  execute on function public.monthly_collection(integer) to authenticated;
