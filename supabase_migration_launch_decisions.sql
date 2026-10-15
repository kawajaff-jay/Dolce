-- ============================================================================
--  Dolce+  —  OWNER DECISIONS (orders, client privacy, refunds & points,
--             no-show / reschedule, consistent dates)
--  FOR REVIEW. Run once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Deletes no records.
--  Run it BEFORE pushing the matching app update.
-- ============================================================================
--  1. Bookings: a "No-show" status; admin rescheduling with a change log;
--     every booking date stored as a real date (date_iso), its time as a real
--     time (time_of_day) and the exact moment as start_at (Erbil time zone).
--     The display text is rewritten from those, so all rows look the same.
--  2. Shop orders: saved in the database with their items. Prices come from
--     the products table, not from the phone. Stock is only taken when staff
--     mark the order Completed (paid). Refunds are recorded separately and can
--     put the items back in stock once.
--  3. Points: earned only for a Completed booking or a Completed + paid
--     order. A refund takes back points in proportion to the money refunded,
--     as a new "reverse" line in the history (nothing is edited or deleted).
--     The same refund can never reverse twice. If the client already spent
--     those points, the shortfall is recorded on that line and shown to staff.
--  4. Clients: owners see everyone; other staff see only clients who have a
--     booking, an order or points history in one of their own brands.
--  5. Clients cancelling / rescheduling their own booking: prepared but OFF
--     until the owner sets the deadline (setting 'client_booking_changes').
-- ============================================================================

-- ---- helpers ----------------------------------------------------------------
create or replace function public.digits10(t text)
returns text language sql immutable as $$
  select right(regexp_replace(coalesce(t, ''), '\D', '', 'g'), 10);
$$;

-- Settings values are stored as JSON text inside the value column (live: jsonb
-- holding a string). Read either shape as a JSON object.
create or replace function public.setting_json(k text)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare raw text; begin
  select s.value::text into raw from public.settings s where s.key = k;
  if raw is null then return '{}'::jsonb; end if;
  begin
    if left(btrim(raw), 1) = '"' then raw := (raw::jsonb) #>> '{}'; end if;
    return coalesce(raw::jsonb, '{}'::jsonb);
  exception when others then return '{}'::jsonb; end;
end; $$;

-- ============================================================================
--  1. BOOKINGS
-- ============================================================================
alter table public.bookings add column if not exists time_of_day    time;
alter table public.bookings add column if not exists start_at       timestamptz;
alter table public.bookings add column if not exists reschedule_log jsonb not null default '[]'::jsonb;
alter table public.bookings add column if not exists refunded_usd   numeric(12,2) not null default 0;

do $$ declare c record; begin
  for c in select conname from pg_constraint
            where conrelid = 'public.bookings'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%status%' loop
    execute format('alter table public.bookings drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.bookings add constraint bookings_status_ck
  check (status in ('Requested','Confirmed','Completed','Cancelled','No-show')) not valid;

-- Real date + real time + exact moment, and one display format for all rows.
create or replace function public.bookings_normalize_dates()
returns trigger language plpgsql as $$
declare tl text := upper(btrim(coalesce(new.time_label, '')));
        dl text := btrim(coalesce(new.date_label, ''));
begin
  new.time_of_day := null;
  begin
    if tl ~ '^\d{1,2}:\d{2}\s*(AM|PM)$' then
      new.time_of_day := to_timestamp(regexp_replace(tl, '\s*(AM|PM)$', ' \1'), 'HH12:MI AM')::time;
    elsif tl ~ '^\d{1,2}:\d{2}$' then
      new.time_of_day := tl::time;
    end if;
  exception when others then new.time_of_day := null; end;
  if new.time_of_day is not null then
    new.time_label := to_char(new.time_of_day, 'FMHH12:MI AM');
  end if;
  if new.date_iso is null then
    begin
      if dl ~ '^[A-Za-z]{3,9} \d{1,2}, \d{4}$' then new.date_iso := to_date(dl, 'Mon DD, YYYY');
      elsif dl ~ '^\d{1,2} [A-Za-z]{3,9} \d{4}$' then new.date_iso := to_date(dl, 'DD Mon YYYY');
      elsif dl ~ '^\d{4}-\d{2}-\d{2}$' then new.date_iso := dl::date;
      end if;   -- numeric dates like 3/4/2026 are ambiguous and are left alone
    exception when others then new.date_iso := null; end;
  end if;
  if new.date_iso is not null then
    new.date_label := to_char(new.date_iso, 'Mon FMDD, YYYY');
  end if;
  new.start_at := case when new.date_iso is not null and new.time_of_day is not null
                       then (new.date_iso + new.time_of_day) at time zone 'Asia/Baghdad' end;
  return new;
end; $$;
drop trigger if exists bookings_normalize_dates on public.bookings;
create trigger bookings_normalize_dates before insert or update on public.bookings
  for each row execute function public.bookings_normalize_dates();

-- Bookings typed straight into the SQL editor (owner / service) are not
-- client requests: only the app's client and guest bookings are checked.
create or replace function public.booking_request_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if public.is_staff() or current_user not in ('anon', 'authenticated') and auth.uid() is null then
    return new;
  end if;
  new.status := 'Requested';
  new.reminders := '{}'::jsonb;
  if coalesce(new.time_label, '') = '' then
    return new;
  end if;
  perform pg_advisory_xact_lock(hashtext('booking-slot:' || coalesce(new.brand, '') || ':' ||
           coalesce(new.date_iso::text, new.date_label, '') || ':' || new.time_label));
  if exists (
    select 1 from public.bookings b
     where b.id <> new.id
       and b.brand = new.brand
       and b.status <> 'Cancelled'
       and (b.time_label = new.time_label or (new.time_of_day is not null and b.time_of_day = new.time_of_day))
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

-- Fill the new columns for existing rows (only the date/time columns change).
update public.bookings set time_label = time_label where start_at is null or time_of_day is null;

-- ============================================================================
--  2. SHOP ORDERS
-- ============================================================================
create table if not exists public.orders (
  id            text primary key,
  ref           text not null,
  brand         text not null,
  client_id     text,
  client_name   text not null default '',
  client_phone  text not null default '',
  lang          text not null default '',
  source        text not null default 'app',
  status        text not null default 'Pending'
                check (status in ('Pending','Confirmed','Completed','Cancelled','Refunded')),
  paid          boolean not null default false,
  total_usd     numeric(12,2) not null default 0 check (total_usd >= 0),
  refunded_usd  numeric(12,2) not null default 0 check (refunded_usd >= 0),
  restocked     boolean not null default false,
  note          text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  confirmed_at  timestamptz,
  completed_at  timestamptz,
  cancelled_at  timestamptz,
  constraint orders_refund_le_total check (refunded_usd <= total_usd)
);
create index if not exists orders_brand_created_idx on public.orders (brand, created_at desc);
create index if not exists orders_client_idx on public.orders (client_id);

create table if not exists public.order_items (
  id             uuid primary key default gen_random_uuid(),
  order_id       text not null references public.orders(id) on delete cascade,
  product_id     text not null,
  name           text not null,
  option         text not null default '',
  qty            integer not null check (qty > 0),
  unit_price_usd numeric(12,2) not null check (unit_price_usd >= 0),
  line_total_usd numeric(12,2) not null check (line_total_usd >= 0)
);
create index if not exists order_items_order_idx on public.order_items (order_id);

create table if not exists public.order_refunds (
  id          text primary key,          -- made by the app per refund: a repeat is ignored
  order_id    text not null references public.orders(id),
  amount_usd  numeric(12,2) not null check (amount_usd > 0),
  restock     boolean not null default false,
  reason      text not null default '',
  points_reversed integer not null default 0,
  points_shortfall integer not null default 0,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);
create table if not exists public.booking_refunds (
  id          text primary key,
  booking_id  text not null,
  amount_usd  numeric(12,2) not null check (amount_usd > 0),
  reason      text not null default '',
  points_reversed integer not null default 0,
  points_shortfall integer not null default 0,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now()
);

alter table public.orders          enable row level security;
alter table public.order_items     enable row level security;
alter table public.order_refunds   enable row level security;
alter table public.booking_refunds enable row level security;
revoke all on public.orders, public.order_items, public.order_refunds, public.booking_refunds from anon, authenticated;
grant select on public.orders, public.order_items, public.order_refunds, public.booking_refunds to authenticated;

drop policy if exists orders_staff_read on public.orders;
create policy orders_staff_read on public.orders for select to authenticated
  using ((public.has_tab('products') or public.has_tab('reports') or public.has_tab('clients')
          or public.has_tab('loyalty') or public.has_tab('overview')) and public.can_brand(brand));
drop policy if exists orders_client_read on public.orders;
create policy orders_client_read on public.orders for select to authenticated
  using (client_id = any(public.my_client_ids()));
drop policy if exists order_items_read on public.order_items;
create policy order_items_read on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id));   -- follows the order's rule
drop policy if exists order_refunds_read on public.order_refunds;
create policy order_refunds_read on public.order_refunds for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id));
drop policy if exists booking_refunds_read on public.booking_refunds;
create policy booking_refunds_read on public.booking_refunds for select to authenticated
  using (exists (select 1 from public.bookings b where b.id = booking_id));

-- The price a client pays: the products table decides, never the phone.
create or replace function public.product_unit_price(p public.products)
returns numeric language sql immutable as $$
  select case when coalesce(p.discount_percent, 0) > 0
              then round(p.price_usd * (100 - p.discount_percent) / 100.0)
              else p.price_usd end;
$$;

-- Client app: place an order for ONE brand. Saved as Pending; nothing is
-- charged and no stock is taken yet. Repeating the same p_id returns the
-- order already saved (a lost reply never makes a second order).
create or replace function public.place_order(
  p_id text, p_brand text, p_items jsonb, p_name text default null,
  p_phone text default null, p_lang text default '')
returns table (order_id text, order_ref text, total_usd numeric)
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  uid uuid := auth.uid();
  cid text; nm text := left(btrim(coalesce(p_name, '')), 80);
  ph text := left(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), 20);
  it jsonb; pr public.products; q int; opt text; unit numeric; tot numeric := 0; n int := 0;
  ref text;
begin
  if coalesce(p_id, '') !~ '^[A-Za-z0-9_-]{8,64}$' then raise exception 'BAD_ORDER_ID' using errcode = '22023'; end if;
  if exists (select 1 from public.orders o where o.id = p_id) then
    return query select o.id, o.ref, o.total_usd from public.orders o where o.id = p_id; return;
  end if;
  if p_brand not in ('dolce','polished','core') then raise exception 'BAD_BRAND' using errcode = '22023'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 30 then
    raise exception 'NO_ITEMS' using errcode = '22023';
  end if;
  if uid is not null and not public.is_staff() then
    select x into cid from unnest(public.my_client_ids()) x limit 1;
    if cid is not null then
      select coalesce(nullif(nm, ''), c.name), coalesce(nullif(ph, ''), c.phone::text, c.contact_phone, '')
        into nm, ph from public.clients c where c.id::text = cid;
    end if;
  end if;
  if nm = '' then raise exception 'NAME_REQUIRED' using errcode = '22023'; end if;
  if length(regexp_replace(ph, '\D', '', 'g')) < 8 then raise exception 'PHONE_REQUIRED' using errcode = '22023'; end if;
  -- A small brake against floods of fake orders from one number.
  if (select count(*) from public.orders o
       where public.digits10(o.client_phone) = public.digits10(ph)
         and o.created_at > now() - interval '1 hour') >= 10 then
    raise exception 'TOO_MANY_ORDERS' using errcode = 'P0001';
  end if;

  ref := upper(left(p_brand, 1)) || '-' || upper(substr(md5(p_id), 1, 5));
  insert into public.orders (id, ref, brand, client_id, client_name, client_phone, lang, total_usd)
  values (p_id, ref, p_brand, cid, nm, ph, left(coalesce(p_lang, ''), 5), 0);

  for it in select * from jsonb_array_elements(p_items) loop
    q := coalesce((it->>'qty')::int, 0);
    opt := left(coalesce(it->>'option', ''), 60);
    if q < 1 or q > 20 then raise exception 'BAD_QTY' using errcode = '22023'; end if;
    select * into pr from public.products where id = it->>'product_id';
    if not found or pr.active is false or pr.brand <> p_brand then
      raise exception 'UNAVAILABLE:%', coalesce(pr.name, it->>'product_id') using errcode = 'P0001';
    end if;
    if coalesce(pr.stock, 0) < q then
      raise exception 'OUT_OF_STOCK:%', pr.name using errcode = 'P0001';
    end if;
    unit := public.product_unit_price(pr);
    insert into public.order_items (order_id, product_id, name, option, qty, unit_price_usd, line_total_usd)
    values (p_id, pr.id, pr.name, opt, q, unit, unit * q);
    tot := tot + unit * q; n := n + 1;
  end loop;
  update public.orders set total_usd = tot where id = p_id;
  return query select p_id, ref, tot;
end; $$;
revoke all on function public.place_order(text, text, jsonb, text, text, text) from public;
grant execute on function public.place_order(text, text, jsonb, text, text, text) to anon, authenticated;

-- Staff: accept or cancel an order (cancel only before it is completed).
create or replace function public.set_order_status(p_id text, p_status text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not public.can_write('products', o.brand) then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if p_status = 'Confirmed' and o.status = 'Pending' then
    update public.orders set status = 'Confirmed', confirmed_at = now(), updated_at = now() where id = p_id;
  elsif p_status = 'Cancelled' and o.status in ('Pending','Confirmed') then
    update public.orders set status = 'Cancelled', cancelled_at = now(), updated_at = now() where id = p_id;
  else
    raise exception 'BAD_STATUS_CHANGE' using errcode = 'P0001';
  end if;
end; $$;

-- Staff: the client paid and took the items. Stock is taken now (refused if
-- not enough), and each item is recorded as a product sale for the reports.
create or replace function public.complete_order(p_id text, p_paid boolean)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders; i record; k int := 0;
begin
  select * into o from public.orders where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not public.can_write('products', o.brand) then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if o.status = 'Completed' then return; end if;                     -- already done
  if o.status not in ('Pending','Confirmed') then raise exception 'BAD_STATUS_CHANGE' using errcode = 'P0001'; end if;
  if p_paid is not true then raise exception 'PAYMENT_REQUIRED' using errcode = 'P0001'; end if;
  for i in select * from public.order_items where order_id = p_id order by name loop
    k := k + 1;
    insert into public.product_sales (id, product_id, name, brand, qty, unit_price_usd, total_usd, client_name, date_label, date_iso)
    values ('ord-' || p_id || '-' || k, i.product_id, i.name || case when i.option <> '' then ' (' || i.option || ')' else '' end,
            o.brand, i.qty, i.unit_price_usd, i.line_total_usd, o.client_name,
            to_char((now() at time zone 'Asia/Baghdad')::date, 'Mon FMDD, YYYY'), (now() at time zone 'Asia/Baghdad')::date)
    on conflict (id) do nothing;          -- the stock trigger runs on each new sale row
  end loop;
  update public.orders set status = 'Completed', paid = true, completed_at = now(), updated_at = now() where id = p_id;
end; $$;

-- ============================================================================
--  3. POINTS: earn only when completed + paid; proportional reversal on refund
-- ============================================================================
alter table public.point_transactions add column if not exists order_id    text;
alter table public.point_transactions add column if not exists reverses_id uuid;
alter table public.point_transactions add column if not exists refund_ref  text;
alter table public.point_transactions add column if not exists shortfall   integer not null default 0;

do $$ declare c record; begin
  for c in select conname from pg_constraint
            where conrelid = 'public.point_transactions'::regclass and contype = 'c'
              and (pg_get_constraintdef(oid) ilike '%kind%') loop
    execute format('alter table public.point_transactions drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.point_transactions add constraint pt_kind_ck
  check (kind in ('earn','redeem','adjust','bonus','expire','opening','reverse'));
alter table public.point_transactions add constraint pt_reason_needed
  check (kind not in ('adjust','redeem') or length(btrim(reason)) > 0);
alter table public.point_transactions add constraint pt_sign check (
  (kind in ('earn','bonus','opening') and points >= 0) or
  (kind in ('redeem','expire','reverse') and points <= 0) or kind = 'adjust');

create unique index if not exists pt_one_earn_per_order on public.point_transactions (order_id) where kind = 'earn' and order_id is not null;
create unique index if not exists pt_one_reverse_per_refund on public.point_transactions (refund_ref) where kind = 'reverse';

-- Points are earned only for a Completed booking, or a Completed and paid order.
create or replace function public.pt_check_earn()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.kind <> 'earn' then return new; end if;
  if new.order_id is not null then
    if not exists (select 1 from public.orders o where o.id = new.order_id and o.status = 'Completed' and o.paid) then
      raise exception 'NOT_COMPLETED_PAID' using errcode = 'P0001', hint = 'Points are added only after the order is completed and paid.';
    end if;
  elsif new.booking_id is not null then
    if not exists (select 1 from public.bookings b where b.id = new.booking_id and b.status = 'Completed') then
      raise exception 'NOT_COMPLETED' using errcode = 'P0001', hint = 'Points are added only after the visit is marked Completed.';
    end if;
  else
    raise exception 'EARN_NEEDS_SOURCE' using errcode = 'P0001';
  end if;
  return new;
end; $$;
drop trigger if exists pt_check_earn on public.point_transactions;
create trigger pt_check_earn before insert on public.point_transactions
  for each row execute function public.pt_check_earn();

-- Take back points for a refund, in proportion to the money refunded.
-- Returns {due, reversed, shortfall}. Never makes a balance negative: what
-- was already spent is recorded as the shortfall on the same history line.
create or replace function public.reverse_points_for_refund(
  p_source text, p_target text, p_ref text, p_amount numeric, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.point_transactions; done_pts int; done_spend numeric; due int; spend_back numeric;
        bal int; taken int; prev jsonb;
begin
  select jsonb_build_object('due', -t.points + t.shortfall, 'reversed', -t.points, 'shortfall', t.shortfall, 'repeat', true)
    into prev from public.point_transactions t where t.kind = 'reverse' and t.refund_ref = p_ref;
  if prev is not null then return prev; end if;
  select * into e from public.point_transactions
   where kind = 'earn' and ((p_source = 'order' and order_id = p_target) or (p_source = 'booking' and booking_id = p_target))
   limit 1;
  if not found then return jsonb_build_object('due', 0, 'reversed', 0, 'shortfall', 0, 'no_points', true); end if;
  select coalesce(sum(-points + shortfall), 0), coalesce(sum(-spend), 0) into done_pts, done_spend
    from public.point_transactions where kind = 'reverse' and reverses_id = e.id;
  if e.spend > 0 then
    due := least(e.points - done_pts, round(e.points * least(p_amount, e.spend - done_spend) / e.spend)::int);
    spend_back := least(p_amount, e.spend - done_spend);
  else
    due := e.points - done_pts; spend_back := 0;
  end if;
  due := greatest(due, 0); spend_back := greatest(spend_back, 0);
  select points into bal from public.clients where id::text = e.client_id for update;
  taken := least(due, greatest(coalesce(bal, 0), 0));
  insert into public.point_transactions (client_id, kind, points, spend, brand, booking_id, order_id,
         reverses_id, refund_ref, shortfall, reason, staff_name)
  values (e.client_id, 'reverse', -taken, -spend_back, e.brand, e.booking_id, e.order_id,
          e.id, p_ref, due - taken, left(coalesce(p_reason, 'Refund'), 200),
          coalesce((select name from public.profiles where id = auth.uid()), ''));
  return jsonb_build_object('due', due, 'reversed', taken, 'shortfall', due - taken);
end; $$;
revoke all on function public.reverse_points_for_refund(text, text, text, numeric, text) from public;

-- Staff: refund (part of) a completed order. p_refund_id is made by the app
-- once per refund, so tapping twice or a lost reply never refunds twice.
create or replace function public.refund_order(p_id text, p_refund_id text, p_amount numeric,
  p_restock boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders; r jsonb; i record;
begin
  if exists (select 1 from public.order_refunds where id = p_refund_id) then
    select jsonb_build_object('repeat', true, 'reversed', points_reversed, 'shortfall', points_shortfall)
      into r from public.order_refunds where id = p_refund_id;
    return r;
  end if;
  select * into o from public.orders where id = p_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not public.can_write('products', o.brand) then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if o.status not in ('Completed','Refunded') then raise exception 'NOT_COMPLETED' using errcode = 'P0001'; end if;
  if coalesce(p_amount, 0) <= 0 or p_amount > o.total_usd - o.refunded_usd then
    raise exception 'BAD_AMOUNT' using errcode = 'P0001';
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then raise exception 'REASON_REQUIRED' using errcode = 'P0001'; end if;
  r := public.reverse_points_for_refund('order', p_id, 'order-refund:' || p_refund_id, p_amount, p_reason);
  insert into public.order_refunds (id, order_id, amount_usd, restock, reason, points_reversed, points_shortfall)
  values (p_refund_id, p_id, p_amount, coalesce(p_restock, false) and not o.restocked, left(p_reason, 200),
          coalesce((r->>'reversed')::int, 0), coalesce((r->>'shortfall')::int, 0));
  if coalesce(p_restock, false) and not o.restocked then
    for i in select product_id, sum(qty) q from public.order_items where order_id = p_id group by product_id loop
      update public.products set stock = stock + i.q where id = i.product_id;
    end loop;
  end if;
  update public.orders set refunded_usd = refunded_usd + p_amount,
         restocked = restocked or coalesce(p_restock, false),
         status = case when refunded_usd + p_amount >= total_usd then 'Refunded' else status end,
         updated_at = now()
   where id = p_id;
  return r;
end; $$;

-- Staff: refund (part of) a completed visit.
create or replace function public.refund_booking(p_booking_id text, p_refund_id text, p_amount numeric, p_reason text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings; r jsonb;
begin
  if exists (select 1 from public.booking_refunds where id = p_refund_id) then
    select jsonb_build_object('repeat', true, 'reversed', points_reversed, 'shortfall', points_shortfall)
      into r from public.booking_refunds where id = p_refund_id;
    return r;
  end if;
  select * into b from public.bookings where id = p_booking_id for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if not public.can_write('bookings', b.brand) then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if b.status <> 'Completed' then raise exception 'NOT_COMPLETED' using errcode = 'P0001'; end if;
  if coalesce(p_amount, 0) <= 0 then raise exception 'BAD_AMOUNT' using errcode = 'P0001'; end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then raise exception 'REASON_REQUIRED' using errcode = 'P0001'; end if;
  r := public.reverse_points_for_refund('booking', p_booking_id, 'booking-refund:' || p_refund_id, p_amount, p_reason);
  insert into public.booking_refunds (id, booking_id, amount_usd, reason, points_reversed, points_shortfall)
  values (p_refund_id, p_booking_id, p_amount, left(p_reason, 200),
          coalesce((r->>'reversed')::int, 0), coalesce((r->>'shortfall')::int, 0));
  update public.bookings set refunded_usd = refunded_usd + p_amount where id = p_booking_id;
  return r;
end; $$;

revoke all on function public.set_order_status(text, text) from public;
revoke all on function public.complete_order(text, boolean) from public;
revoke all on function public.refund_order(text, text, numeric, boolean, text) from public;
revoke all on function public.refund_booking(text, text, numeric, text) from public;
grant execute on function public.set_order_status(text, text) to authenticated;
grant execute on function public.complete_order(text, boolean) to authenticated;
grant execute on function public.refund_order(text, text, numeric, boolean, text) to authenticated;
grant execute on function public.refund_booking(text, text, numeric, text) to authenticated;

-- ============================================================================
--  4. CLIENT PRIVACY BETWEEN BRANDS
-- ============================================================================
create or replace function public.staff_can_see_client(cid text)
returns boolean language plpgsql stable security definer set search_path = public, pg_temp as $$
declare p1 text; p2 text;
begin
  if public.is_owner() then return true; end if;
  if not public.is_staff() then return false; end if;
  if not (public.has_tab('clients') or public.has_tab('bookings') or public.has_tab('loyalty') or public.has_tab('products')) then
    return false;
  end if;
  select public.digits10(c.phone::text), public.digits10(c.contact_phone) into p1, p2
    from public.clients c where c.id::text = cid;
  return exists (select 1 from public.bookings b where b.client_id::text = cid and public.can_brand(b.brand))
      or exists (select 1 from public.bookings b
                  where public.digits10(b.client_phone) <> '' and length(public.digits10(b.client_phone)) >= 8
                    and public.digits10(b.client_phone) in (p1, p2) and public.can_brand(b.brand))
      or exists (select 1 from public.point_transactions t where t.client_id = cid and t.brand <> '' and public.can_brand(t.brand))
      or exists (select 1 from public.orders o where o.client_id = cid and public.can_brand(o.brand));
end; $$;
revoke all on function public.staff_can_see_client(text) from public;
grant execute on function public.staff_can_see_client(text) to authenticated;

drop policy if exists clients_staff_read on public.clients;
create policy clients_staff_read on public.clients for select to authenticated
  using (public.staff_can_see_client(id::text));
drop policy if exists clients_staff_write on public.clients;
create policy clients_staff_write on public.clients for update to authenticated
  using (public.staff_can_see_client(id::text)) with check (public.staff_can_see_client(id::text));

drop policy if exists pt_staff_read on public.point_transactions;
create policy pt_staff_read on public.point_transactions for select to authenticated
  using (public.staff_can_see_client(client_id));
-- Adding points also needs the client to be visible to that staff member.
drop policy if exists pt_staff_add on public.point_transactions;
create policy pt_staff_add on public.point_transactions for insert to authenticated
  with check (
    public.is_staff()
    and created_by = auth.uid()
    and (
      public.is_owner()
      or (kind in ('earn', 'redeem', 'adjust', 'bonus')
          and (public.has_tab('loyalty') or public.has_tab('bookings'))
          and (coalesce(brand, '') in ('', 'all') or public.can_brand(brand))
          and (kind = 'earn' or public.staff_can_see_client(client_id)))
    )
  );

-- ============================================================================
--  5. CLIENTS CANCELLING / RESCHEDULING THEIR OWN BOOKING (prepared, OFF)
--     Turned on by the owner later: settings key 'client_booking_changes'
--     = {"enabled": true, "cutoff_hours": <hours before the appointment>}
-- ============================================================================
create or replace function public.client_booking_change_check(p_id text)
returns public.bookings language plpgsql stable security definer set search_path = public, pg_temp as $$
declare cfg jsonb := public.setting_json('client_booking_changes'); b public.bookings; cutoff numeric;
begin
  if auth.uid() is null or public.is_staff() then raise exception 'NOT_ALLOWED' using errcode = '42501'; end if;
  if coalesce((cfg->>'enabled')::boolean, false) is not true or (cfg->>'cutoff_hours') is null then
    raise exception 'CLIENT_CHANGES_DISABLED' using errcode = 'P0001';
  end if;
  cutoff := (cfg->>'cutoff_hours')::numeric;
  select * into b from public.bookings where id = p_id;
  if not found or not (b.client_id::text = any(public.my_client_ids())
                       or (public.my_phone10() <> '' and public.digits10(b.client_phone) = public.my_phone10())) then
    raise exception 'NOT_FOUND' using errcode = 'P0002';
  end if;
  if b.status not in ('Requested','Confirmed') then raise exception 'BAD_STATUS_CHANGE' using errcode = 'P0001'; end if;
  if b.start_at is null or b.start_at < now() + make_interval(mins => (cutoff * 60)::int) then
    raise exception 'TOO_LATE' using errcode = 'P0001';
  end if;
  return b;
end; $$;

create or replace function public.client_cancel_booking(p_id text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings := public.client_booking_change_check(p_id);
begin
  update public.bookings set status = 'Cancelled',
         reschedule_log = reschedule_log || jsonb_build_object('at', now(), 'by', 'client', 'action', 'cancel')
   where id = b.id;
end; $$;

create or replace function public.client_reschedule_booking(p_id text, p_date date, p_time text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.bookings := public.client_booking_change_check(p_id);
        cfg jsonb := public.setting_json('client_booking_changes'); t time; at timestamptz;
begin
  begin t := to_timestamp(upper(btrim(p_time)), 'HH12:MI AM')::time; exception when others then
    raise exception 'BAD_TIME' using errcode = '22023'; end;
  at := (p_date + t) at time zone 'Asia/Baghdad';
  if at < now() + make_interval(mins => ((cfg->>'cutoff_hours')::numeric * 60)::int) then
    raise exception 'TOO_LATE' using errcode = 'P0001';
  end if;
  perform pg_advisory_xact_lock(hashtext('booking-slot:' || b.brand || ':' || p_date::text || ':' || to_char(t, 'FMHH12:MI AM')));
  if exists (select 1 from public.bookings x where x.id <> b.id and x.brand = b.brand and x.status <> 'Cancelled'
              and x.date_iso = p_date and x.time_of_day = t) then
    raise exception 'SLOT_TAKEN' using errcode = '23P01';
  end if;
  update public.bookings set date_iso = p_date, date_label = to_char(p_date, 'Mon FMDD, YYYY'),
         time_label = to_char(t, 'FMHH12:MI AM'), status = 'Requested', reminders = '{}'::jsonb,
         reschedule_log = reschedule_log || jsonb_build_object('at', now(), 'by', 'client',
             'from', jsonb_build_object('date', b.date_label, 'time', b.time_label),
             'to', jsonb_build_object('date', to_char(p_date, 'Mon FMDD, YYYY'), 'time', to_char(t, 'FMHH12:MI AM')))
   where id = b.id;
end; $$;
revoke all on function public.client_booking_change_check(text) from public;
revoke all on function public.client_cancel_booking(text) from public;
revoke all on function public.client_reschedule_booking(text, date, text) from public;
grant execute on function public.client_cancel_booking(text) to authenticated;
grant execute on function public.client_reschedule_booking(text, date, text) to authenticated;

notify pgrst, 'reload schema';
