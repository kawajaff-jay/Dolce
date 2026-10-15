-- ============================================================================
--  Dolce+  —  AUDIT FIXES (bookings, stock, points permissions)
--  FOR REVIEW. Run once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Deletes nothing and changes no existing rows.
--  Run it BEFORE pushing the matching app update (commit "Audit fixes").
-- ============================================================================
--  1. busy_slots()  — the client app can see which times are already booked
--     (date + time only: no names, no numbers), so a slot someone else has
--     booked no longer looks free.
--  2. A booking from a client or guest is refused if that brand already has a
--     booking (not cancelled) at the same date and time — the same rule the
--     app already used on screen, now checked by the database, including two
--     requests arriving at the same moment. Staff bookings are not blocked
--     (reception decides). Client/guest bookings always arrive as Requested
--     with no reminders pre-ticked.
--  3. Stock is changed by the database when a sale or a delivery is saved, in
--     the same step, so two devices can no longer overwrite each other's stock
--     and a sale of more than is in stock is refused.
--  4. Adding or removing D+ points needs the same access the app already
--     requires (owner, or the Loyalty / Bookings section, for that brand).
--     Opening balances and expiries stay owner-only.
-- ============================================================================

-- ---- 1. Booked times for the client app (no personal data) ------------------
create or replace function public.busy_slots(p_brand text, p_from date, p_to date)
returns table (date_iso date, time_label text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select distinct b.date_iso, b.time_label
    from public.bookings b
   where b.brand = p_brand
     and b.status <> 'Cancelled'
     and b.date_iso is not null
     and b.date_iso between p_from and least(p_to, p_from + 62)
     and coalesce(b.time_label, '') <> '';
$$;
revoke all on function public.busy_slots(text, date, date) from public;
grant execute on function public.busy_slots(text, date, date) to anon, authenticated;

-- ---- 2. One client/guest booking per brand, date and time ---------------------
create or replace function public.booking_request_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_staff() then
    return new;                       -- reception and managers decide for themselves
  end if;
  new.status := 'Requested';
  new.reminders := '{}'::jsonb;
  if coalesce(new.time_label, '') = '' then
    return new;
  end if;
  -- Two requests for the same slot at the same moment wait for each other here.
  perform pg_advisory_xact_lock(hashtext('booking-slot:' || coalesce(new.brand, '') || ':' ||
           coalesce(new.date_iso::text, new.date_label, '') || ':' || new.time_label));
  if exists (
    select 1 from public.bookings b
     where b.id <> new.id
       and b.brand = new.brand
       and b.status <> 'Cancelled'
       and b.time_label = new.time_label
       and (case when new.date_iso is not null and b.date_iso is not null
                 then b.date_iso = new.date_iso
                 else b.date_label = new.date_label end)
  ) then
    raise exception 'SLOT_TAKEN' using errcode = '23P01',
      hint = 'That time was just booked by someone else.';
  end if;
  return new;
end;
$$;
drop trigger if exists bookings_request_guard on public.bookings;
create trigger bookings_request_guard before insert on public.bookings
  for each row execute function public.booking_request_guard();

-- ---- 3. Stock moves with sales and deliveries, in the database ----------------
create or replace function public.product_sale_stock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if coalesce(new.product_id, '') = '' then
    return new;
  end if;
  update public.products set stock = stock - new.qty
   where id = new.product_id and stock >= new.qty;
  if not found and exists (select 1 from public.products where id = new.product_id) then
    raise exception 'OUT_OF_STOCK' using errcode = '23514',
      hint = 'Not enough of this product in stock for that sale.';
  end if;
  return new;
end;
$$;
drop trigger if exists product_sales_stock on public.product_sales;
create trigger product_sales_stock after insert on public.product_sales
  for each row execute function public.product_sale_stock();

create or replace function public.purchase_stock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if coalesce(new.product_id, '') <> '' then
    update public.products set stock = stock + new.qty where id = new.product_id;
  end if;
  return new;
end;
$$;
drop trigger if exists purchases_stock on public.purchases;
create trigger purchases_stock after insert on public.purchases
  for each row execute function public.purchase_stock();

-- ---- 4. Who may add or remove D+ points ---------------------------------------
drop policy if exists pt_staff_add on public.point_transactions;
create policy pt_staff_add on public.point_transactions for insert to authenticated
  with check (
    public.is_staff()
    and created_by = auth.uid()
    and (
      public.is_owner()
      or (kind in ('earn', 'redeem', 'adjust', 'bonus')
          and (public.has_tab('loyalty') or public.has_tab('bookings'))
          and (coalesce(brand, '') in ('', 'all') or public.can_brand(brand)))
    )
  );

notify pgrst, 'reload schema';
