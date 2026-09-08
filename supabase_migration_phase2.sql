-- ============================================================================
-- One Account. Three Brands. — Phase 2 migration (Admin CRUD cloud sync)
--
-- Why this file exists: the app now syncs Products, Services, Offers,
-- Bookings, Purchases, Product Sales, Register Closes, Gallery and Clients
-- to the shared database (not just read the public catalog like before).
-- That newer app code expects a few extra columns that the original
-- supabase_schema.sql didn't have yet. This file adds them.
--
-- Safe to re-run. Every statement either adds something that doesn't exist
-- yet, or leaves existing data untouched — nothing here deletes a column or
-- a row.
--
-- Run this AFTER supabase_schema.sql, supabase_seed.sql and
-- supabase_auth_setup.sql, in the same SQL Editor.
-- ============================================================================

-- ---------- Services: display order + an image ----------
alter table services add column if not exists image text;
alter table services add column if not exists sort_order int not null default 0;

-- ---------- Bookings: the app now saves the date/time as text the way it
-- shows them on screen (e.g. "Sep 9, 2026"), plus a real calendar date
-- alongside for sorting/filtering. ----------
alter table bookings add column if not exists date_label text;
alter table bookings add column if not exists time_label text;
alter table bookings add column if not exists date_iso date;

-- ---------- Purchases: now records the product's name and a supplier, and
-- splits cost into unit cost x quantity = total (instead of one lump sum).
-- ----------
alter table purchases add column if not exists name text;
alter table purchases add column if not exists unit_cost_usd numeric(10,2);
alter table purchases add column if not exists total_usd numeric(10,2);
alter table purchases add column if not exists supplier text;
alter table purchases add column if not exists date_label text;
alter table purchases add column if not exists date_iso date;

-- ---------- Product sales: same idea — name, unit price x qty = total, and
-- who bought it. ----------
alter table product_sales add column if not exists name text;
alter table product_sales add column if not exists unit_price_usd numeric(10,2);
alter table product_sales add column if not exists total_usd numeric(10,2);
alter table product_sales add column if not exists client_name text;
alter table product_sales add column if not exists date_label text;
alter table product_sales add column if not exists date_iso date;

-- ---------- Register closes: a single end-of-day close can now cover more
-- than one brand at once (e.g. closing Dolce + Polished together at one
-- front desk), so "brand" (one) becomes "brands" (a list). The old single
-- "brand" column is kept and made optional rather than deleted, so nothing
-- already saved is lost. ----------
alter table register_closes alter column brand drop not null;
alter table register_closes add column if not exists brands text[] not null default '{}';
alter table register_closes add column if not exists expected_total_usd numeric(10,2);
alter table register_closes add column if not exists counted_cash_usd numeric(10,2);
alter table register_closes add column if not exists counted_card_usd numeric(10,2);
alter table register_closes add column if not exists counted_total_usd numeric(10,2);
alter table register_closes add column if not exists date_label text;
alter table register_closes add column if not exists date_iso date;

-- ---------- Clients: loyalty points ----------
alter table clients add column if not exists points int not null default 0;

-- ---------- Security fix to match the "brands" list above: a register
-- close covering several brands needs to be visible to staff who can see
-- ANY of those brands, not just staff matching the old single "brand"
-- column. This replaces the generic rule for this one table only. ----------
drop policy if exists "staff brand access" on register_closes;
create policy "staff brand access" on register_closes for all
  using (
    current_profile_is_owner()
    or brand = any(current_profile_brands())
    or brands && current_profile_brands()
  )
  with check (
    current_profile_is_owner()
    or brand = any(current_profile_brands())
    or brands && current_profile_brands()
  );
