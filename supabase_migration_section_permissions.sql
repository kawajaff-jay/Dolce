-- ============================================================================
--  Dolce+  —  STAFF PERMISSIONS FOLLOW THEIR SECTIONS (not just their brand)
--  FOR REVIEW. Run once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Deletes no data.
-- ============================================================================
--  What the live check showed: the database still has old rules called
--  "staff brand access" on bookings, products, product sales, purchases,
--  register closes and media. They let ANY staff member change ANYTHING in
--  those tables for their brand — a nail technician with only the Bookings
--  section could, through the database, change product prices or delete the
--  day's sales. The app hides those screens, but the database did not.
--
--  This file replaces them with the rules the app already follows: each
--  section in Admin → Employees (Bookings, Products, Purchases, Reports,
--  Gallery, Services, Offers) is needed to change that kind of record, for the
--  staff member's own brands. Owners keep full access.
--
--  BEFORE RUNNING: open Admin → Employees and check every staff member has the
--  sections they really use. After this, a section that is not ticked really
--  is closed for them.
-- ============================================================================

-- Helpers (same definitions as supabase_schema.sql; re-created so this file
-- does not depend on what an older setup left behind).
create or replace function public.my_tabs()
returns text[] language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select p.tabs from public.profiles p where p.id = auth.uid()), '{}'::text[]);
$$;
create or replace function public.my_brands()
returns text[] language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select p.brands from public.profiles p where p.id = auth.uid()), '{}'::text[]);
$$;
create or replace function public.has_tab(t text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_owner() or (t = any(public.my_tabs()));
$$;
create or replace function public.can_brand(b text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_owner() or (b = any(public.my_brands()));
$$;
create or replace function public.can_brands(bs text[])
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select public.is_owner() or (coalesce(array_length(bs, 1), 0) > 0 and bs <@ public.my_brands());
$$;
create or replace function public.can_write(t text, b text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select auth.uid() is not null and public.has_tab(t) and public.can_brand(b);
$$;

-- ---- Bookings -----------------------------------------------------------------
-- Reading stays open to the screens that show bookings (Bookings, Overview,
-- Reports, Clients, Loyalty) for the staff member's brands.
drop policy if exists bookings_staff_read on public.bookings;
create policy bookings_staff_read on public.bookings for select to authenticated
  using ((public.has_tab('bookings') or public.has_tab('overview') or public.has_tab('reports')
          or public.has_tab('clients') or public.has_tab('loyalty')) and public.can_brand(brand));
drop policy if exists bookings_staff_insert on public.bookings;
create policy bookings_staff_insert on public.bookings for insert to authenticated
  with check (public.can_write('bookings', brand));
drop policy if exists bookings_staff_update on public.bookings;
create policy bookings_staff_update on public.bookings for update to authenticated
  using (public.can_write('bookings', brand)) with check (public.can_write('bookings', brand));
drop policy if exists bookings_staff_delete on public.bookings;
create policy bookings_staff_delete on public.bookings for delete to authenticated
  using (public.can_write('bookings', brand));
drop policy if exists "staff brand access" on public.bookings;

-- ---- Products (catalogue read stays public) ------------------------------------
drop policy if exists products_read on public.products;
create policy products_read on public.products for select to anon, authenticated using (true);
drop policy if exists products_insert on public.products;
create policy products_insert on public.products for insert to authenticated
  with check (public.can_write('products', brand));
drop policy if exists products_update on public.products;
create policy products_update on public.products for update to authenticated
  using (public.can_write('products', brand)) with check (public.can_write('products', brand));
drop policy if exists products_delete on public.products;
create policy products_delete on public.products for delete to authenticated
  using (public.can_write('products', brand));
drop policy if exists "staff brand access" on public.products;

-- ---- Product sales --------------------------------------------------------------
drop policy if exists product_sales_read on public.product_sales;
create policy product_sales_read on public.product_sales for select to authenticated
  using ((public.has_tab('products') or public.has_tab('reports') or public.has_tab('overview')) and public.can_brand(brand));
drop policy if exists product_sales_write on public.product_sales;
create policy product_sales_write on public.product_sales for insert to authenticated
  with check (public.can_write('products', brand));
drop policy if exists product_sales_update on public.product_sales;
create policy product_sales_update on public.product_sales for update to authenticated
  using (public.can_write('products', brand)) with check (public.can_write('products', brand));
drop policy if exists product_sales_delete on public.product_sales;
create policy product_sales_delete on public.product_sales for delete to authenticated
  using (public.can_write('products', brand));
drop policy if exists "staff brand access" on public.product_sales;

-- ---- Purchases (deliveries) -----------------------------------------------------
drop policy if exists purchases_staff on public.purchases;
create policy purchases_staff on public.purchases for all to authenticated
  using (public.can_write('purchases', brand)) with check (public.can_write('purchases', brand));
drop policy if exists purchases_reports_read on public.purchases;
create policy purchases_reports_read on public.purchases for select to authenticated
  using ((public.has_tab('reports') or public.has_tab('products')) and public.can_brand(brand));
drop policy if exists "staff brand access" on public.purchases;

-- ---- Register closes (Reports) --------------------------------------------------
drop policy if exists register_closes_staff on public.register_closes;
create policy register_closes_staff on public.register_closes for all to authenticated
  using (public.has_tab('reports') and public.can_brands(brands))
  with check (public.has_tab('reports') and public.can_brands(brands));
drop policy if exists "staff brand access" on public.register_closes;

-- ---- Gallery media --------------------------------------------------------------
drop policy if exists media_staff_read on public.media;
create policy media_staff_read on public.media for select to authenticated
  using (public.has_tab('gallery') and public.can_brand(brand));
drop policy if exists media_staff_write on public.media;
create policy media_staff_write on public.media for all to authenticated
  using (public.can_write('gallery', brand)) with check (public.can_write('gallery', brand));
drop policy if exists "staff brand access" on public.media;

-- ---- Services and offers (same pattern, in case they carry the old rule too) ----
drop policy if exists services_read on public.services;
create policy services_read on public.services for select to anon, authenticated using (true);
drop policy if exists services_insert on public.services;
create policy services_insert on public.services for insert to authenticated
  with check (public.can_write('services', brand));
drop policy if exists services_update on public.services;
create policy services_update on public.services for update to authenticated
  using (public.can_write('services', brand)) with check (public.can_write('services', brand));
drop policy if exists services_delete on public.services;
create policy services_delete on public.services for delete to authenticated
  using (public.can_write('services', brand));
drop policy if exists "staff brand access" on public.services;

drop policy if exists offers_read on public.offers;
create policy offers_read on public.offers for select to anon, authenticated using (true);
drop policy if exists offers_insert on public.offers;
create policy offers_insert on public.offers for insert to authenticated
  with check (public.can_write('offers', brand));
drop policy if exists offers_update on public.offers;
create policy offers_update on public.offers for update to authenticated
  using (public.can_write('offers', brand)) with check (public.can_write('offers', brand));
drop policy if exists offers_delete on public.offers;
create policy offers_delete on public.offers for delete to authenticated
  using (public.can_write('offers', brand));
drop policy if exists "staff brand access" on public.offers;

notify pgrst, 'reload schema';

-- What is left afterwards (one table of results):
select tablename, policyname, cmd from pg_policies
 where schemaname = 'public'
   and tablename in ('bookings','products','product_sales','purchases','register_closes','media','services','offers')
 order by tablename, policyname;
