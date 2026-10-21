-- ============================================================================
--  Dolce+  —  BOOK CORE CLASSES INTO MINDBODY FROM THE APP
--  FOR REVIEW. Run once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Deletes no data; changes no bookings.
-- ============================================================================
--  mindbody_clients — which Mindbody client each Dolce+ client is, so the
--  same person is never added to CORE's Mindbody twice. Written only by the
--  server function "mindbody-book"; the app cannot read or change it.
-- ============================================================================
create table if not exists public.mindbody_clients (
  user_id      uuid primary key,
  client_id    text not null default '',
  mb_client_id text not null,
  created_at   timestamptz not null default now()
);
alter table public.mindbody_clients enable row level security;
revoke all on public.mindbody_clients from anon, authenticated;
grant all on public.mindbody_clients to service_role;

notify pgrst, 'reload schema';
