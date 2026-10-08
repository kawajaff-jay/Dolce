\set ON_ERROR_STOP on
do $$ begin
  if coalesce(current_setting('dolce.allow_test', true),'') <> 'yes' then raise exception 'REFUSING TO RUN on a real database.'; end if;
end $$;
create or replace function pg_temp.expect(label text, got boolean, want boolean)
returns void language plpgsql as $$
begin got := coalesce(got,false);
  if got is distinct from want then raise exception 'FAIL: % (expected %, got %)', label, want, got; else raise notice 'pass: %', label; end if; end $$;
create or replace function pg_temp.try(sql text) returns boolean language plpgsql as $$
begin execute sql; return true; exception when others then return false; end $$;

-- a client with 900 opening points (Shilan) and an email client (Rozh)
select id::text as shilan from clients where name like 'Shilan%' \gset
select id::text as rozh from clients where name='Rozh' \gset

set role authenticated;
-- STAFF (Sara, not owner)
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select pg_temp.expect('staff can add earned points', pg_temp.try(format($$insert into point_transactions(client_id,kind,points,spend,brand,booking_id,reason,staff_name) values (%L,'earn',150,120,'dolce','bk_t1','Booking','Sara')$$, :'shilan')), true);
select pg_temp.expect('balance went up to 1050', (select points=1050 from clients where id::text=:'shilan'), true);
select pg_temp.expect('same booking cannot earn twice', pg_temp.try(format($$insert into point_transactions(client_id,kind,points,spend,booking_id,staff_name) values (%L,'earn',150,120,'bk_t1','Sara')$$, :'shilan')), false);
select pg_temp.expect('redeem needs a reason', pg_temp.try(format($$insert into point_transactions(client_id,kind,points) values (%L,'redeem',-100)$$, :'shilan')), false);
select pg_temp.expect('staff can redeem a reward', pg_temp.try(format($$insert into point_transactions(client_id,kind,points,reward_id,reason,staff_name) values (%L,'redeem',-1000,'rw_dolprem','Reward: Premium','Sara')$$, :'shilan')), true);
select pg_temp.expect('balance now 50', (select points=50 from clients where id::text=:'shilan'), true);
select pg_temp.expect('cannot go below zero', pg_temp.try(format($$insert into point_transactions(client_id,kind,points,reason,staff_name) values (%L,'redeem',-100,'x','Sara')$$, :'shilan')), false);
select pg_temp.expect('earn cannot be negative', pg_temp.try(format($$insert into point_transactions(client_id,kind,points,staff_name) values (%L,'earn',-5,'Sara')$$, :'shilan')), false);
select pg_temp.expect('staff cannot pretend to be someone else', pg_temp.try(format($$insert into point_transactions(client_id,kind,points,reason,created_by) values (%L,'adjust',5,'x','11111111-1111-1111-1111-111111111111')$$, :'shilan')), false);
select pg_temp.expect('staff cannot edit the ledger', pg_temp.try($$update point_transactions set points=99999$$), false);
select pg_temp.expect('staff cannot delete the ledger', pg_temp.try($$delete from point_transactions$$), false);
update clients set points=99999 where id::text=:'shilan';
select pg_temp.expect('typing a balance directly is ignored', (select points=50 from clients where id::text=:'shilan'), true);
select pg_temp.try($$update rewards set points=1 where id='rw_matcha'$$);
select pg_temp.expect('staff cannot edit rewards', (select points=1 from rewards where id='rw_matcha'), false);

-- CLIENT (Rozh, email login)
set request.jwt.claim.sub = 'a1111111-1111-1111-1111-111111111111';
select pg_temp.expect('client cannot give themselves points', pg_temp.try(format($$insert into point_transactions(client_id,kind,points,staff_name) values (%L,'earn',5000,'me')$$, :'rozh')), false);
select pg_temp.expect('client cannot see others'' points history', (select count(*) from point_transactions where client_id=:'shilan')=0, true);
select pg_temp.expect('client sees rewards', (select count(*) from rewards)>0, true);

-- ANON
reset role; set role anon;
select pg_temp.expect('visitor sees rewards shop', (select count(*) from rewards)=9, true);
select pg_temp.expect('visitor cannot read ledger', pg_temp.try($$select count(*) from point_transactions$$), false);

-- OWNER
reset role; set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select pg_temp.try($$update rewards set points=160 where id='rw_matcha'$$);
select pg_temp.expect('owner can edit rewards', (select points=160 from rewards where id='rw_matcha'), true);
select pg_temp.expect('owner adjusts with reason', pg_temp.try(format($$insert into point_transactions(client_id,kind,points,reason,staff_name) values (%L,'adjust',25,'Goodwill','Kawa')$$, :'shilan')), true);
reset role;
update clients set points=75 where id::text=:'shilan';
select pg_temp.expect('SQL editor can still fix a balance', (select points=75 from clients where id::text=:'shilan'), true);
