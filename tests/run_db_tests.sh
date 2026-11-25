#!/usr/bin/env bash
# Local Postgres pe schema + DB tests. Usage: PGHOST=... PGPORT=... tests/run_db_tests.sh
# Ek khaali database chahiye (supabase ka auth.uid() yahan stub hai).
set -euo pipefail
cd "$(dirname "$0")/.."
psql -v ON_ERROR_STOP=1 -q <<'SQL'
create schema if not exists auth;
create table if not exists auth.users(id uuid primary key, email text, last_sign_in_at timestamptz);
create or replace function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
do $$ begin create role anon; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated; exception when duplicate_object then null; end $$;
grant usage on schema auth to authenticated; grant select on auth.users to authenticated;
SQL
psql -v ON_ERROR_STOP=1 -q -f schema.sql
psql -v ON_ERROR_STOP=1 -q -f tests/db_test.sql
psql -v ON_ERROR_STOP=1 -q -f tests/admin_test.sql
