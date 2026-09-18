-- Aftercare messages
-- ------------------
-- Adds what the app needs to send a client a care note the moment their
-- treatment is marked Completed:
--
--   bookings.client_phone   the number to message (reception types it in)
--   bookings.aftercare_ok   whether the client agreed to be contacted
--   services.aftercare      the note for that treatment, written by a doctor
--
-- Run this in the Supabase SQL Editor BEFORE publishing the new app version.
-- If the app sends these fields to a database that has not got the columns
-- yet, the whole record is rejected, so the order matters.
--
-- Safe to run more than once.

alter table public.bookings add column if not exists client_phone text not null default '';
alter table public.bookings add column if not exists aftercare_ok boolean not null default false;
alter table public.services add column if not exists aftercare    text not null default '';

-- A client's phone number is personal data, so it must not be readable by
-- the public catalog role. These columns sit on tables that are already
-- restricted to signed-in staff by the existing row-level security policies,
-- so nothing further is needed here — but check that the bookings policies
-- still say `authenticated` and not `public` after running this.
