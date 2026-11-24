-- 002: per-gym name + plan fees, payment details, plan switch on payment
-- Already-live project pe ye chalao. Naye project pe sirf schema.sql kaafi hai.

alter table public.settings add column if not exists gym_name text not null default 'My Gym';
alter table public.settings add column if not exists plan_fees jsonb not null
  default '{"Monthly":1200,"Quarterly":3300,"Half-yearly":6000,"Yearly":10500}'::jsonb;
alter table public.settings alter column template set default
  'Namaste {name}! {gym} ki {plan} fees ₹{amount} ki due date {date} hai. Please time pe jama kar dein. Dhanyavaad 🙏';

alter table public.payments add column if not exists plan text
  check (plan in ('Monthly','Quarterly','Half-yearly','Yearly'));
alter table public.payments add column if not exists mode text not null default 'Cash'
  check (mode in ('Cash','UPI','Card','Bank'));
alter table public.payments add column if not exists note text;

-- Payment record karo, plan switch bhi isi mein.
-- Due date: (purani due ya payment date, jo baad mein ho) + naye plan ke mahine.
create or replace function public.record_payment(
  p_member  bigint,
  p_plan    text,
  p_amount  integer,
  p_mode    text default 'Cash',
  p_paid_on date default null,
  p_note    text default null
) returns date
language plpgsql
security invoker
set search_path = public
as $$
declare
  m       public.members;
  paid    date := coalesce(p_paid_on, (now() at time zone 'Asia/Kolkata')::date);
  months  int;
  std_fee int;
  new_due date;
begin
  select * into m from public.members where id = p_member for update;
  if not found then raise exception 'Member nahi mila'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'Amount galat hai'; end if;

  months := case p_plan when 'Monthly' then 1 when 'Quarterly' then 3
                        when 'Half-yearly' then 6 when 'Yearly' then 12 end;
  if months is null then raise exception 'Plan galat hai: %', p_plan; end if;

  select (plan_fees ->> p_plan)::int into std_fee from public.settings where owner_id = auth.uid();
  new_due := (greatest(m.due, paid) + make_interval(months => months))::date;

  insert into public.payments (member_id, amount, paid_on, plan, mode, note)
  values (p_member, p_amount, paid, p_plan, coalesce(p_mode, 'Cash'), nullif(trim(p_note), ''));

  update public.members
     set plan = p_plan,
         fee = coalesce(std_fee, case when p_plan = m.plan then m.fee else p_amount end),
         due = new_due,
         reminded_on = null
   where id = p_member;
  return new_due;
end $$;

-- Purana "Paid ✓" button: same plan, standard fee
create or replace function public.mark_paid(p_member bigint)
returns date
language sql
security invoker
set search_path = public
as $$
  select public.record_payment(m.id, m.plan, m.fee, 'Cash', null, null)
  from public.members m where m.id = p_member;
$$;

revoke execute on function public.record_payment(bigint, text, integer, text, date, text) from public, anon;
grant  execute on function public.record_payment(bigint, text, integer, text, date, text) to authenticated;
revoke execute on function public.mark_paid(bigint) from public, anon;
grant  execute on function public.mark_paid(bigint) to authenticated;
