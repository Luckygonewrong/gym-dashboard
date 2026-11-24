-- Gym owner dashboard: Supabase schema
-- Supabase → SQL Editor → New query → ye poora paste karke Run karo.

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
  created_at timestamptz not null default now()
);

create table if not exists public.settings (
  owner_id uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  template text not null
);

create index if not exists members_owner_due on public.members (owner_id, due);
create index if not exists payments_owner_date on public.payments (owner_id, paid_on);

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

-- ========== Fees paid: payment add + agli due date, ek hi transaction mein ==========
create or replace function public.mark_paid(p_member bigint)
returns date
language plpgsql
security invoker            -- RLS lagu rehta hai
set search_path = public
as $$
declare
  m       public.members;
  today   date := (now() at time zone 'Asia/Kolkata')::date;
  months  int;
  new_due date;
begin
  select * into m from public.members where id = p_member for update;
  if not found then raise exception 'Member nahi mila'; end if;

  months := case m.plan when 'Monthly' then 1 when 'Quarterly' then 3
                        when 'Half-yearly' then 6 when 'Yearly' then 12 end;
  new_due := (greatest(m.due, today) + make_interval(months => months))::date;

  insert into public.payments (member_id, amount, paid_on) values (p_member, m.fee, today);
  update public.members set due = new_due, reminded_on = null where id = p_member;
  return new_due;
end $$;

revoke execute on function public.mark_paid(bigint) from public, anon;
grant  execute on function public.mark_paid(bigint) to authenticated;
