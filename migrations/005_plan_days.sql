-- 005: plan ki lambai mahine ki jagah din mein
--      Monthly 30, Quarterly 90, Half-yearly 180, Yearly 365
-- (004 ke baad chalao. Naye project pe sirf schema.sql kaafi hai.)

create or replace function public.plan_days(p_plan text)
returns integer
language sql
immutable
set search_path = public
as $$
  select case p_plan when 'Monthly' then 30 when 'Quarterly' then 90
                     when 'Half-yearly' then 180 when 'Yearly' then 365 end;
$$;

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
security invoker
set search_path = public
as $$
declare
  m       public.members;
  paid    date := coalesce(p_paid_on, (now() at time zone 'Asia/Kolkata')::date);
  days    int := public.plan_days(p_plan);
  start   date;
  new_due date;
begin
  select * into m from public.members where id = p_member for update;
  if not found then raise exception 'Member nahi mila'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'Amount galat hai'; end if;
  if days is null then raise exception 'Plan galat hai: %', p_plan; end if;

  start := case p_from when 'today' then paid
                       when 'due'   then m.due
                       else greatest(m.due, paid) end;
  new_due := start + days;

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

revoke execute on function public.plan_days(text) from public, anon;
grant  execute on function public.plan_days(text) to authenticated;
