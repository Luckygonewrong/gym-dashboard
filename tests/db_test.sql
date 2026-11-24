-- DB tests: local Postgres pe chalao (tests/run_db_tests.sh). Supabase pe mat chalao.
\set ON_ERROR_STOP on
insert into auth.users values ('11111111-1111-1111-1111-111111111111'),('22222222-2222-2222-2222-222222222222');
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
insert into settings(plan_fees) values ('{"Monthly":1000,"Quarterly":2700,"Half-yearly":5000,"Yearly":9000}');
insert into members(name,phone,plan,fee,due) values
 ('Late','9000000001','Monthly',1000,(current_date - 10)),
 ('Early','9000000002','Monthly',1000,(current_date + 10)),
 ('Switch','9000000003','Quarterly',2700,'2026-01-31');

do $$
declare d date; f int;
begin
  -- aaj se: today + 30 din
  d := record_payment(1,'Monthly',1000,'Cash',current_date,null,'today');
  assert d = current_date + 30, 'today failed';
  -- due se, early payer
  d := record_payment(2,'Monthly',1000,'Online',current_date,null,'due');
  assert d = current_date + 10 + 30, 'due failed';
  -- Feb ki koi confusion nahi: 31 Jan + 30 din = 2 Mar; plan switch with discount
  d := record_payment(3,'Monthly',500,'Cash','2026-01-15',null,'due');
  assert d = '2026-03-02', '30-day failed: ' || d;
  select fee into f from members where id = 3;
  assert f = 1000, 'switch should store standard fee, got ' || f;
  -- har plan ke din
  assert plan_days('Quarterly') = 90 and plan_days('Half-yearly') = 180 and plan_days('Yearly') = 365, 'plan days wrong';
  -- same plan with discount keeps old fee
  perform record_payment(1,'Monthly',700,'Cash',current_date,null,'auto');
  select fee into f from members where id = 1;
  assert f = 1000, 'discount leaked into fee: ' || f;
  -- bad plan rejected, nothing saved
  begin perform record_payment(1,'Weekly',100); assert false, 'bad plan accepted';
  exception when raise_exception then null; end;
end $$;

-- duplicate phone blocked for same owner
do $$ begin
  insert into members(name,phone,plan,fee,due) values ('Dup','9000000001','Monthly',1000,current_date);
  assert false, 'duplicate phone accepted';
exception when unique_violation then null; end $$;

-- monthly_collection sums in DB
select count(*) = 1 as one_row_this_month from monthly_collection(6) where month = date_trunc('month', (now() at time zone 'Asia/Kolkata')::date)::date;

-- other owner sees nothing, can use same phone
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$ begin
  assert (select count(*) from members) = 0, 'RLS leak';
  assert (select count(*) from monthly_collection(6)) = 0, 'RLS leak in stats';
  insert into members(name,phone,plan,fee,due) values ('Other','9000000001','Monthly',1200,current_date);
  assert plan_fee(auth.uid(),'Yearly') = 10500, 'default fee wrong';
end $$;
select 'ALL DB TESTS PASSED' as result;
