\set ON_ERROR_STOP on
do $$ begin
  if coalesce(current_setting('dolce.allow_test', true),'') <> 'yes' then
    raise exception 'REFUSING TO RUN on a real database.';
  end if;
end $$;

create or replace function pg_temp.expect(label text, got boolean, want boolean)
returns void language plpgsql as $$
begin
  got := coalesce(got,false);
  if got is distinct from want then raise exception 'FAIL: % (expected %, got %)', label, want, got;
  else raise notice 'pass: %', label; end if;
end $$;
create or replace function pg_temp.try(sql text)
returns boolean language plpgsql as $$
begin execute sql; return true; exception when others then return false; end $$;

-- a stranger who signed up with an email (no staff profile), and two clients
insert into auth.users (id,email,phone,phone_confirmed_at) values
 ('44444444-4444-4444-4444-444444444444','stranger@x',null,null),
 ('55555555-5555-5555-5555-555555555555',null,'9647501112222',now()),
 ('66666666-6666-6666-6666-666666666666',null,'9647503334444',now()),
 ('77777777-7777-7777-7777-777777777777',null,'9647509990000',null)
on conflict do nothing;
-- reception already added client #5 by phone (local format), with points
insert into public.clients (id,phone,name,points) values ('c_rec','07501112222','Lana (reception)',450) on conflict do nothing;
insert into public.bookings (id,brand,service_name,status,client_name,client_phone) values
 ('bk_lana_old','dolce','Botox','Confirmed','Lana','0750 111 2222'),
 ('bk_other','polished','Nails','Confirmed','Someone','07509998888')
on conflict do nothing;

-- ===================== STRANGER (logged in, not staff, no phone) =============
set role authenticated;
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
select pg_temp.expect('stranger CANNOT make themselves owner',
  pg_temp.try($$insert into profiles (id,name,is_owner,brands,tabs) values ('44444444-4444-4444-4444-444444444444','Hacker',true,array['dolce'],array['employees'])$$), false);
select pg_temp.expect('stranger CANNOT read the customer list', (select count(*) from clients) > 0, false);
select pg_temp.expect('stranger CANNOT read the booking diary', (select count(*) from bookings) > 0, false);
select pg_temp.expect('stranger CANNOT change a customer''s points',
  pg_temp.try($$update clients set points=99999 where id='c_1'$$) and (select points from public.clients where id='c_1')=99999, false);
select pg_temp.expect('stranger CANNOT change photo positions',
  pg_temp.try($$insert into settings (key,value) values ('image_focus','{}') on conflict (key) do update set value='{}'$$), false);
select pg_temp.expect('stranger CANNOT upload to the media store',
  pg_temp.try($$insert into storage.objects (bucket_id,name) values ('media','x.jpg')$$), false);
select pg_temp.expect('stranger CANNOT claim a client account (no verified phone)',
  pg_temp.try($$select * from claim_my_client_account('X')$$), false);
select pg_temp.expect('stranger CANNOT turn client login on',
  pg_temp.try($$update settings set value='on' where key='client_login'$$) and (select value from public.settings where key='client_login')='on', false);
reset role;

-- ===================== STAFF SELF-PROMOTION =====================
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';   -- Sara, Dolce bookings only
select pg_temp.expect('Sara CANNOT make herself owner',
  pg_temp.try($$update profiles set is_owner=true where id='22222222-2222-2222-2222-222222222222'$$), false);
select pg_temp.expect('Sara CANNOT give herself more sections',
  pg_temp.try($$update profiles set tabs=array['bookings','employees'] where id='22222222-2222-2222-2222-222222222222'$$), false);
select pg_temp.expect('Sara CAN still change her own display name',
  pg_temp.try($$update profiles set name='Sara M.' where id='22222222-2222-2222-2222-222222222222'$$), true);
select pg_temp.expect('Sara (staff) CAN still read clients', (select count(*) from clients) > 0, true);
select pg_temp.expect('Sara CAN still save photo positions',
  pg_temp.try($$insert into settings (key,value) values ('image_focus','{}') on conflict (key) do update set value='{}'$$), true);
select pg_temp.expect('Sara CAN upload to the media store',
  pg_temp.try($$insert into storage.objects (bucket_id,name) values ('media','ok.jpg')$$), true);
reset role;

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';   -- Kawa, owner
select pg_temp.expect('owner CAN create a new staff profile',
  pg_temp.try($$insert into profiles (id,name,brands,tabs) values ('44444444-4444-4444-4444-444444444444','New Staff',array['core'],array['bookings'])$$), true);
select pg_temp.expect('owner CAN change someone''s sections',
  pg_temp.try($$update profiles set tabs=array['bookings','gallery'] where id='44444444-4444-4444-4444-444444444444'$$), true);
select pg_temp.expect('owner CAN turn client login on',
  pg_temp.try($$update settings set value='on' where key='client_login'$$), true);
delete from profiles where id='44444444-4444-4444-4444-444444444444';
reset role;

-- ===================== CLIENT LANA (reception added her earlier) =============
set role authenticated;
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
select pg_temp.expect('Lana sees nothing before claiming', (select count(*) from clients) = 0, true);
select pg_temp.expect('Lana''s claim links the record reception made (keeps 450 pts)',
  (select points from claim_my_client_account(null)) = 450, true);
select pg_temp.expect('Lana now sees exactly one client record (hers)', (select count(*) from clients) = 1 and (select id from clients)='c_rec', true);
select pg_temp.expect('Lana sees her old booking made with her phone number', exists(select 1 from bookings where id='bk_lana_old'), true);
select pg_temp.expect('Lana CANNOT see other people''s bookings', exists(select 1 from bookings where id in ('bk_other','bk_dolce','bk_polished')), false);
select pg_temp.expect('Lana CAN request a booking for herself',
  pg_temp.try($$insert into bookings (id,brand,service_name,status,client_name,client_id,client_phone) values ('bk_lana_new','core','Reformer','Requested','Lana','c_rec','9647501112222')$$), true);
select pg_temp.expect('Lana sees her new booking', exists(select 1 from bookings where id='bk_lana_new'), true);
select pg_temp.expect('Lana CANNOT book as someone else',
  pg_temp.try($$insert into bookings (id,brand,service_name,status,client_name,client_id) values ('bk_x','core','Reformer','Requested','X','c_1')$$), false);
select pg_temp.expect('Lana CANNOT self-confirm a booking',
  pg_temp.try($$insert into bookings (id,brand,service_name,status,client_name,client_id) values ('bk_y','core','Reformer','Confirmed','Lana','c_rec')$$), false);
select pg_temp.expect('Lana CANNOT confirm her booking afterwards',
  pg_temp.try($$update bookings set status='Confirmed' where id='bk_lana_new'$$) and (select status from public.bookings where id='bk_lana_new')='Confirmed', false);
select pg_temp.expect('Lana CANNOT give herself points',
  pg_temp.try($$update clients set points=99999 where id='c_rec'$$) and (select points from public.clients where id='c_rec')=99999, false);
select pg_temp.expect('Lana CAN change her name', pg_temp.try($$select update_my_client_name('Lana H.')$$), true);
select pg_temp.expect('Lana''s new name is saved', (select name from public.clients where id='c_rec')='Lana H.', true);
select pg_temp.expect('Lana CANNOT create a staff profile',
  pg_temp.try($$insert into profiles (id,name,is_owner) values ('55555555-5555-5555-5555-555555555555','L',true)$$), false);
select pg_temp.expect('Lana CANNOT read staff profiles', exists(select 1 from profiles), false);
reset role;

-- ===================== NEW CLIENT RIBAZ ======================================
set role authenticated;
set request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
select pg_temp.expect('new client: first claim without a name asks for one (empty result)',
  (select count(*) from claim_my_client_account(null)) = 0, true);
select pg_temp.expect('new client: claim with a name creates the account at 0 pts',
  (select points from claim_my_client_account('Ribaz')) = 0, true);
select pg_temp.expect('new client: claiming again returns the same account',
  (select count(*) from claim_my_client_account('Other name')) = 1 and (select name from clients) = 'Ribaz', true);
select pg_temp.expect('new client sees only their own record', (select count(*) from clients) = 1, true);
select pg_temp.expect('new client CAN delete their account',
  pg_temp.try($$select delete_my_client_account()$$), true);
reset role;
select pg_temp.expect('deleted: login gone', exists(select 1 from auth.users where id='66666666-6666-6666-6666-666666666666'), false);
select pg_temp.expect('deleted: client record gone', exists(select 1 from public.clients where phone='9647503334444'), false);

-- ===================== UNVERIFIED PHONE ======================================
set role authenticated;
set request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';
select pg_temp.expect('unverified phone CANNOT claim an account',
  pg_temp.try($$select * from claim_my_client_account('Z')$$), false);
select pg_temp.expect('unverified phone sees no bookings', (select count(*) from bookings) = 0, true);
reset role;

-- staff cannot use client functions
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select pg_temp.expect('staff login CANNOT be deleted via the client button',
  pg_temp.try($$select delete_my_client_account()$$), false);
reset role;
