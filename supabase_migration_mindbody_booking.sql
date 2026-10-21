-- ============================================================================
--  Dolce+  —  BOOK CORE CLASSES INTO MINDBODY FROM THE APP (safety tables)
--  FOR REVIEW. Run once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Deletes no data; changes no bookings.
--  Only the server function "mindbody-book" reads or writes these tables;
--  the app cannot see or change them.
-- ============================================================================

-- Which Mindbody client each Dolce+ client is. One Mindbody client can belong
-- to only one Dolce+ account. linked_by: verified_contact | new_client | staff
create table if not exists public.mindbody_clients (
  user_id      uuid primary key,
  client_id    text not null default '',
  mb_client_id text not null,
  linked_by    text not null default '',
  created_at   timestamptz not null default now()
);
alter table public.mindbody_clients add column if not exists linked_by text not null default '';
create unique index if not exists mindbody_clients_mb_key on public.mindbody_clients (mb_client_id);

-- Accounts that could NOT be linked automatically (e.g. the verified phone and
-- e-mail point to two different Mindbody clients). Nothing is booked for them
-- until CORE checks and links the right client.
create table if not exists public.mindbody_link_issues (
  user_id        uuid primary key,
  client_id      text not null default '',
  reason         text not null default '',
  candidates     jsonb not null default '[]'::jsonb,
  verified_phone text not null default '',
  verified_email text not null default '',
  resolved       boolean not null default false,
  updated_at     timestamptz not null default now()
);

-- One booking attempt per client and class at a time, so repeated taps or
-- retries can never book the same class twice.
create table if not exists public.mindbody_booking_attempts (
  user_id    uuid not null,
  class_id   bigint not null,
  state      text not null default 'pending',   -- pending | booked | failed | unconfirmed | link_review
  detail     text not null default '',
  updated_at timestamptz not null default now(),
  primary key (user_id, class_id)
);

alter table public.mindbody_clients          enable row level security;
alter table public.mindbody_link_issues      enable row level security;
alter table public.mindbody_booking_attempts enable row level security;
revoke all on public.mindbody_clients, public.mindbody_link_issues, public.mindbody_booking_attempts from anon, authenticated;
grant all on public.mindbody_clients, public.mindbody_link_issues, public.mindbody_booking_attempts to service_role;

notify pgrst, 'reload schema';
