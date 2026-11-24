-- 003: Paid button options: plan, Cash/Online, aaj se ya due date se
-- (002 ke baad chalao)

alter table public.payments add column if not exists plan text
  check (plan in ('Monthly','Quarterly','Half-yearly','Yearly'));
alter table public.payments add column if not exists mode text not null default 'Cash';
alter table public.payments add column if not exists note text;
alter table public.payments drop constraint if exists payments_mode_check;
alter table public.payments add constraint payments_mode_check
  check (mode in ('Cash','Online','UPI','Card','Bank'));

drop function if exists public.record_payment(bigint, text, integer, text, date, text);

-- p_from: 'today' = aaj se naya plan, 'due' = jab se due tha,
--         'auto' = jo baad mein ho (purana behaviour)
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

  update public.members
     set plan = p_plan,
         fee = case when p_plan = m.plan then m.fee else p_amount end,
         due = new_due,
         reminded_on = null
   where id = p_member;
  return new_due;
end $$;

create or replace function public.mark_paid(p_member bigint)
returns date
language sql
security invoker
set search_path = public
as $$
  select public.record_payment(m.id, m.plan, m.fee, 'Cash', null, null, 'auto')
  from public.members m where m.id = p_member;
$$;

revoke execute on function public.record_payment(bigint, text, integer, text, date, text, text) from public, anon;
grant  execute on function public.record_payment(bigint, text, integer, text, date, text, text) to authenticated;
