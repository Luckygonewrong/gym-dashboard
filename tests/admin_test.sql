-- Admin / gyms / Excel export tests. Local Postgres pe (db_test.sql ke baad). Supabase pe mat chalao.
\set ON_ERROR_STOP on
reset role;
insert into auth.users (id, email, last_sign_in_at) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'admin@ironhouse.in', now()),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Owner2@Gym.com', now());
insert into public.admins (user_id) values ('aaaaaaaa-0000-0000-0000-000000000001');

-- gym owner 2 ke members
set role authenticated;
set request.jwt.claim.sub = 'bbbbbbbb-0000-0000-0000-000000000002';
insert into members (name, phone, plan, fee, due) values
  ('A', '9100000001', 'Monthly', 1000, current_date - 3),
  ('B', '9100000002', 'Monthly', 1000, current_date + 20);
do $$ begin
  assert not is_admin(), 'owner should not be admin';
  begin perform * from admin_gym_overview(); assert false, 'owner saw admin overview';
  exception when raise_exception then null; end;
  assert (select count(*) from gyms) = 0, 'owner can read gyms';
  begin insert into gyms (gym_name, owner_name, owner_email) values ('x','y','z@z.com'); assert false, 'owner inserted gym';
  exception when insufficient_privilege then null; end;
  begin perform admin_new_export_token('x'); assert false, 'owner made token';
  exception when raise_exception then null; end;
end $$;

-- admin
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
insert into gyms (gym_name, owner_name, owner_email, phone, trial_start) values
  ('Pulse Fitness', 'Rohit', 'owner2@gym.com', '9200000001', current_date - 2),   -- trial
  ('Old Gym', 'Aman', 'old@gym.com', null, current_date - 20);                     -- expired, login nahi
do $$
declare r record; d date; tok text;
begin
  assert is_admin(), 'admin not admin';
  select * into r from admin_gym_overview() where gym_name = 'Pulse Fitness';
  assert r.status = 'Trial', 'status ' || r.status;
  assert r.trial_end = current_date + 4, 'trial end';          -- 7 din: start..start+6
  assert r.days_left = 4, 'days left ' || r.days_left;
  assert r.login_created, 'email case-insensitive link failed';
  assert r.members = 2 and r.overdue_members = 1 and r.pending_amount = 1000, 'member stats';
  select * into r from admin_gym_overview() where gym_name = 'Old Gym';
  assert r.status = 'Expired' and not r.login_created and r.members = 0, 'expired gym';

  -- trial mein pay: trial end ke baad se 30 din
  d := admin_gym_paid((select id from gyms where gym_name = 'Pulse Fitness'), 2000);
  assert d = current_date + 4 + 30, 'paid_until during trial ' || d;
  -- expired gym pay: aaj se 30 din
  d := admin_gym_paid((select id from gyms where gym_name = 'Old Gym'), 2000, 30, 'Cash');
  assert d = current_date + 30, 'paid_until after expiry ' || d;
  select * into r from admin_gym_overview() where gym_name = 'Old Gym';
  assert r.status = 'Paid' and r.paid_to_you = 2000, 'after payment';

  assert (select count(*) from admin_members_export()) = 2, 'members export';

  -- Excel token
  tok := admin_new_export_token('Laptop');
  assert length(tok) = 64, 'token length';
  perform set_config('test.tok', tok, false);
end $$;

-- token ka sirf hash save hua
reset role;
do $$ begin
  assert (select count(*) from private.export_tokens where token_hash = current_setting('test.tok')) = 0, 'plain token stored';
  assert (select count(*) from private.export_tokens) = 1, 'token row missing';
end $$;

-- anon (Excel) token se
set role anon;
do $$
declare tok text := current_setting('test.tok');
begin
  assert (select count(*) from export_gyms(tok)) = 2, 'export_gyms';
  assert (select count(*) from export_members(tok)) = 2, 'export_members';
  begin perform * from export_gyms('wrong-token-wrong-token-wrong-token-xx'); assert false, 'bad token accepted';
  exception when raise_exception then null; end;
  begin perform * from gyms; assert false, 'anon read gyms';
  exception when insufficient_privilege then null; end;
  begin perform * from private.gym_overview(); assert false, 'anon called private';
  exception when insufficient_privilege then null; end;
end $$;

-- revoke
reset role;
set role authenticated;
set request.jwt.claim.sub = 'aaaaaaaa-0000-0000-0000-000000000001';
select admin_revoke_export_tokens() >= 1 as revoked;
reset role;
set role anon;
do $$ begin
  begin perform * from export_gyms(current_setting('test.tok')); assert false, 'revoked token works';
  exception when raise_exception then null; end;
end $$;
reset role;
select 'ALL ADMIN TESTS PASSED' as result;
