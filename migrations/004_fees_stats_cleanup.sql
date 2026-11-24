-- 004: har owner ki apni plan fees, monthly collection RPC, unique phone,
--      plan switch pe standard fee, purani cheezein saaf
-- (003 ke baad chalao. Naye project pe sirf schema.sql kaafi hai.)

-- ---------- settings: plan fees per owner ----------
alter table public.settings add column if not exists plan_fees jsonb not null
  default '{"Monthly":1200,"Quarterly":3300,"Half-yearly":6000,"Yearly":10500}'::jsonb;
alter table public.settings alter column template set default
  'Namaste {name}! Aapki {plan} fees ₹{amount} ki due date {date} hai. Please time pe jama kar dein. Dhanyavaad 🙏';
alter table public.settings drop column if exists gym_name;

-- ---------- ek owner ke paas ek phone number ek hi baar ----------
create unique index if not exists members_owner_phone on public.members (owner_id, phone);

-- ---------- plan ki standard fee (settings, warna default) ----------
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

-- ---------- payment: discount sirf is payment pe, member ki fee = plan ki standard fee ----------
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
security invoker
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

-- ---------- dashboard: mahine ka total database mein hi jodo (1000-row limit se bachne ke liye) ----------
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

-- ---------- purani cheezein ----------
drop function if exists public.mark_paid(bigint);

-- ---------- permissions ----------
revoke execute on function public.plan_fee(uuid, text) from public, anon;
revoke execute on function public.record_payment(bigint, text, integer, text, date, text, text) from public, anon;
revoke execute on function public.monthly_collection(integer) from public, anon;
grant  execute on function public.plan_fee(uuid, text) to authenticated;
grant  execute on function public.record_payment(bigint, text, integer, text, date, text, text) to authenticated;
grant  execute on function public.monthly_collection(integer) to authenticated;
