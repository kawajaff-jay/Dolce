-- ============================================================================
--  LOCAL TEST STUB — never run this on Supabase
-- ============================================================================
--  Supabase provides a few things automatically (an "auth" area holding login
--  accounts, and the anon / authenticated roles). A plain local Postgres does
--  not, so this file fakes just enough of them to let the real schema and the
--  security tests run on a throwaway database.
--
--  It also flips the switch that supabase_rls_test.sql checks for, which is
--  what stops that test file from ever running against your live data.
-- ============================================================================

-- Local-only stub that imitates the bits of Supabase the schema depends on,
-- so the real SQL files can be tested before being run for real.
create extension if not exists pgcrypto;
do $$ begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role nologin; end if;
end $$;
create schema if not exists auth;
create table if not exists auth.users (id uuid primary key default gen_random_uuid(), email text);
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid;
$$;
grant usage on schema public to anon, authenticated, service_role;

-- Flip the "this is a throwaway test database" switch.
do $$ begin
  execute format('alter database %I set dolce.allow_test = %L', current_database(), 'yes');
end $$;
set dolce.allow_test = 'yes';
