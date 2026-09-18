\set ON_ERROR_STOP on
\pset pager off

-- ============================================================================
--  Dolce / Polished / Core  —  SECURITY RULE TESTS
-- ============================================================================
--  WHAT THIS IS
--  A set of 39 checks that prove the database's security rules actually do
--  what they are supposed to: that a visitor who is not logged in cannot read
--  your customer list or change a price, that Dolce reception cannot see
--  Polished's bookings, that a gallery photo cannot be made public without
--  consent, and so on. Each check prints "pass" or stops with a loud failure.
--
--  *** DO NOT RUN THIS ON YOUR REAL SUPABASE DATABASE. ***
--  It creates fake staff, fake bookings and fake customers on purpose. It is
--  meant for a scratch copy of the database only. To make that mistake
--  impossible, the file refuses to run unless a switch has been set first,
--  which only the local test stub does.
--
--  HOW TO RUN IT (on a local test database, not Supabase):
--    psql -f supabase_local_test_stub.sql   (sets the switch, fakes Supabase)
--    psql -f supabase_schema.sql
--    psql -f supabase_auth_setup.sql
--    psql -f supabase_seed.sql
--    psql -f supabase_rls_test.sql
-- ============================================================================

do $$
begin
  if coalesce(current_setting('dolce.allow_test', true),'') <> 'yes' then
    raise exception
      'REFUSING TO RUN. This file creates fake test data and must never be run on the real database. If this really is a scratch test database, run supabase_local_test_stub.sql first.';
  end if;
end $$;


-- three staff members, exactly like the app's defaults
insert into auth.users (id,email) values
 ('11111111-1111-1111-1111-111111111111','kawa@x'),
 ('22222222-2222-2222-2222-222222222222','sara@x'),
 ('33333333-3333-3333-3333-333333333333','aya@x')
on conflict do nothing;

insert into public.profiles (id,name,login_slug,brands,tabs,is_owner) values
 ('11111111-1111-1111-1111-111111111111','Kawa','slug-kawa',
   array['dolce','polished','core'],
   array['overview','bookings','products','services','offers','gallery','employees','reports','purchases'], true),
 ('22222222-2222-2222-2222-222222222222','Sara','slug-sara', array['dolce'], array['bookings'], false),
 ('33333333-3333-3333-3333-333333333333','Aya','slug-aya', array['polished'], array['bookings','gallery'], false)
on conflict (id) do nothing;

insert into public.bookings (id,brand,service_name,date_label,time_label,status,client_name) values
 ('bk_dolce','dolce','Hydrafacial','Sep 9, 2026','11:00 AM','Confirmed','Zhino A.'),
 ('bk_polished','polished','Balayage Color','Sep 9, 2026','2:30 PM','Requested','Rawa S.')
on conflict (id) do nothing;

insert into public.media (id,brand,visibility,consent,note,data_url) values
 ('md_pub','dolce','public',true,'public before/after','x'),
 ('md_priv','dolce','private',false,'private client record','x')
on conflict (id) do nothing;

insert into public.clients (id,phone,name) values ('c_1','9647500000000','Test Client')
on conflict (id) do nothing;

create or replace function pg_temp.expect(label text, got boolean, want boolean)
returns void language plpgsql as $$
begin
  if got is distinct from want then
    raise exception 'FAIL: % (expected %, got %)', label, want, got;
  else
    raise notice 'pass: %', label;
  end if;
end $$;

-- helper: does this statement succeed?
create or replace function pg_temp.try(sql text)
returns boolean language plpgsql as $$
begin
  execute sql; return true;
exception when others then return false;
end $$;

-- ===================== ANONYMOUS VISITOR (not logged in) =====================
set role anon;
select pg_temp.expect('anon can read the service catalog',        (select count(*) from services) >= 18, true);
select pg_temp.expect('anon can read products',                   (select count(*) from products) >= 6, true);
select pg_temp.expect('anon can see PUBLIC gallery items',        (select count(*) from media) = 1, true);
select pg_temp.expect('anon CANNOT see private client photos',    exists(select 1 from media where visibility='private'), false);
select pg_temp.expect('anon CANNOT read the customer list',
  pg_temp.try($$select count(*) from clients$$), false);
select pg_temp.expect('anon CANNOT read the booking diary',
  pg_temp.try($$select count(*) from bookings$$), false);
select pg_temp.expect('anon CANNOT change a price',
  pg_temp.try($$update services set price_usd=1 where id='hydra'$$) and (select price_usd from public.services where id='hydra')=1, false);
select pg_temp.expect('anon CANNOT add a service',
  pg_temp.try($$insert into services (id,brand,name) values ('hack','dolce','Free')$$), false);
select pg_temp.expect('anon CAN request a booking',
  pg_temp.try($$insert into bookings (id,brand,service_name,status,client_name) values ('bk_anon','dolce','Botox','Requested','Walk-in')$$), true);
select pg_temp.expect('anon CANNOT self-confirm a booking',
  pg_temp.try($$insert into bookings (id,brand,service_name,status,client_name) values ('bk_bad','dolce','Botox','Confirmed','Walk-in')$$), false);
select pg_temp.expect('anon CAN sign up as a customer',
  pg_temp.try($$insert into clients (id,phone,name) values ('c_new','9647511111111','New')$$), true);
reset role;

-- ===================== SARA — Dolce reception, bookings only =================
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select pg_temp.expect('Sara sees Dolce bookings',        exists(select 1 from bookings where brand='dolce'), true);
select pg_temp.expect('Sara CANNOT see Polished bookings',exists(select 1 from bookings where brand='polished'), false);
select pg_temp.expect('Sara CAN confirm a Dolce booking',
  pg_temp.try($$update bookings set status='Confirmed' where id='bk_dolce'$$), true);
select pg_temp.expect('Sara CANNOT edit product prices (no Products tab)',
  pg_temp.try($$update products set price_usd=1 where id='p1'$$) and (select price_usd from public.products where id='p1')=1, false);
select pg_temp.expect('Sara CANNOT delete a service',
  pg_temp.try($$delete from services where id='hydra'$$) and not exists(select 1 from public.services where id='hydra'), false);
select pg_temp.expect('Sara CANNOT see private photos (no Gallery tab)',
  exists(select 1 from media where visibility='private'), false);
select pg_temp.expect('Sara sees only her own staff profile',     (select count(*) from profiles) = 1, true);
select pg_temp.expect('Sara CANNOT change the exchange rate',
  pg_temp.try($$update settings set value='1' where key='usd_to_iqd'$$) and (select value from public.settings where key='usd_to_iqd')='1', false);
reset role; reset request.jwt.claim.sub;

-- ===================== AYA — Polished, bookings + gallery ===================
set role authenticated;
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select pg_temp.expect('Aya sees Polished bookings',        exists(select 1 from bookings where brand='polished'), true);
select pg_temp.expect('Aya CANNOT see Dolce bookings',     exists(select 1 from bookings where brand='dolce'), false);
select pg_temp.expect('Aya CAN add a Polished gallery item',
  pg_temp.try($$insert into media (id,brand,visibility,consent,note,data_url) values ('md_aya','polished','private',false,'ok','x')$$), true);
select pg_temp.expect('Aya CANNOT add a Dolce gallery item',
  pg_temp.try($$insert into media (id,brand,visibility,consent,note,data_url) values ('md_aya2','dolce','private',false,'no','x')$$), false);
select pg_temp.expect('Aya CANNOT see Dolce private photos',
  exists(select 1 from media where brand='dolce' and visibility='private'), false);
select pg_temp.expect('Aya CANNOT log a purchase (no Purchases tab)',
  pg_temp.try($$insert into purchases (id,brand,qty,name) values ('pu_x','polished',1,'x')$$), false);
select pg_temp.expect('Aya CANNOT read the purchase ledger',
  (select count(*) from purchases) = 0, true);
reset role; reset request.jwt.claim.sub;

-- ===================== KAWA — owner ========================================
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select pg_temp.expect('Owner sees every booking',    (select count(*) from bookings) >= 2, true);
select pg_temp.expect('Owner sees every staff profile', (select count(*) from profiles) = 3, true);
select pg_temp.expect('Owner sees private photos',   exists(select 1 from media where visibility='private'), true);
select pg_temp.expect('Owner CAN change the exchange rate',
  pg_temp.try($$update settings set value='1500' where key='usd_to_iqd'$$), true);
select pg_temp.expect('Owner CAN edit any brand price',
  pg_temp.try($$update products set price_usd=70 where id='p1'$$), true);
select pg_temp.expect('Owner CAN close the register for all three brands',
  pg_temp.try($$insert into register_closes (id,date_label,brands,expected_total_usd) values ('rc_1','Sep 9, 2026',array['dolce','polished','core'],100)$$), true);
select pg_temp.expect('Owner CANNOT delete their own account',
  pg_temp.try($$delete from profiles where id='11111111-1111-1111-1111-111111111111'$$)
    and not exists(select 1 from public.profiles where id='11111111-1111-1111-1111-111111111111'), false);
reset role; reset request.jwt.claim.sub;

-- ===================== database-level safety net =============================
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select pg_temp.expect('A public gallery item without consent is rejected by the database',
  pg_temp.try($$insert into media (id,brand,visibility,consent,note,data_url) values ('md_noconsent','dolce','public',false,'no consent','x')$$), false);
select pg_temp.expect('A booking with a nonsense status is rejected',
  pg_temp.try($$insert into bookings (id,brand,status) values ('bk_bad2','dolce','Banana')$$), false);
select pg_temp.expect('A product with a nonsense brand is rejected',
  pg_temp.try($$insert into products (id,brand,name) values ('p_bad','tesco','x')$$), false);
select pg_temp.expect('A 150% discount is rejected',
  pg_temp.try($$insert into products (id,brand,name,discount_percent) values ('p_bad2','dolce','x',150)$$), false);
select pg_temp.expect('Negative stock is rejected',
  pg_temp.try($$insert into products (id,brand,name,stock) values ('p_bad3','dolce','x',-5)$$), false);
reset role; reset request.jwt.claim.sub;

-- ===================== the login screen list ================================
set role anon;
select pg_temp.expect('login screen can list staff names', (select count(*) from public.list_staff_names()) = 3, true);
reset role;
