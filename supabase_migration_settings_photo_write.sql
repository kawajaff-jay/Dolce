-- Fix: adding a product (or repositioning any photo) failed with
-- "new row violates row-level security policy for table settings", and
-- running the first version of this fix failed with
-- "function public.is_owner() does not exist".
--
-- What that second error means: the permission-checking functions this whole
-- app's security rules depend on -- is_owner(), has_tab(), can_brand(), etc
-- -- are described in supabase_schema.sql, but at least is_owner() was never
-- actually created in the real, live database. This script (re)creates all
-- of them. "create or replace" is safe to run even for ones that already
-- exist -- it just leaves them as they are.
--
-- Then, same as before: the "settings" table holds two unrelated things --
-- the USD/IQD exchange rate (usd_to_iqd, owner-only on purpose) and the
-- shared photo-position data used by every drag-to-position photo in the
-- app (image_focus, needed by any staff member who edits a photo). Both were
-- locked to owner-only; this opens image_focus to any signed-in staff member
-- while keeping the exchange rate owner-only.

-- ---- 1. Permission helper functions (recreated in case any are missing) ---

create or replace function public.my_brands()
returns text[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select p.brands from public.profiles p where p.id = auth.uid()), '{}'::text[]);
$$;

create or replace function public.my_tabs()
returns text[]
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select p.tabs from public.profiles p where p.id = auth.uid()), '{}'::text[]);
$$;

create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce((select p.is_owner from public.profiles p where p.id = auth.uid()), false);
$$;

create or replace function public.has_tab(t text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_owner() or (t = any(public.my_tabs()));
$$;

create or replace function public.can_brand(b text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_owner() or (b = any(public.my_brands()));
$$;

create or replace function public.can_brands(bs text[])
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.is_owner() or (bs <@ public.my_brands());
$$;

create or replace function public.can_write(t text, b text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select auth.uid() is not null and public.has_tab(t) and public.can_brand(b);
$$;

-- ---- 2. The settings table fix --------------------------------------------

drop policy if exists settings_write on public.settings;
create policy settings_write on public.settings for all to authenticated
  using (key = 'image_focus' or public.is_owner())
  with check (key = 'image_focus' or public.is_owner());
