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

insert into auth.users (id,email,phone,phone_confirmed_at,email_confirmed_at) values
 ('a1111111-1111-1111-1111-111111111111','Rozh@Gmail.com',null,null,now()),
 ('a2222222-2222-2222-2222-222222222222','nobody@x.com',null,null,null),
 ('a3333333-3333-3333-3333-333333333333','sneaky@gmail.com',null,null,now())
on conflict do nothing;
insert into public.clients (id,phone,name,points) values (gen_random_uuid(),'07508887777','Shilan (reception)',900) on conflict do nothing;
insert into public.bookings (id,brand,service_name,status,client_name,client_phone) values
 ('bk_shilan','dolce','Filler','Confirmed','Shilan','0750 888 7777') on conflict do nothing;

set role authenticated;
-- verified email client
set request.jwt.claim.sub = 'a1111111-1111-1111-1111-111111111111';
select pg_temp.expect('email client, first call: no record yet (needs name)', (select count(*) from claim_my_client_account()) = 0, true);
select pg_temp.expect('email client, name but no phone: still waiting', (select count(*) from claim_my_client_account('Rozh')) = 0, true);
select pg_temp.expect('email client gets a new record with name+phone', (select count(*) from claim_my_client_account('Rozh','0750 123 4567')) = 1, true);
select pg_temp.expect('record stores lower-case email', (select email='rozh@gmail.com' from clients where user_id=auth.uid()), true);
select pg_temp.expect('number kept as contact_phone, not as verified phone', (select contact_phone='07501234567' and phone is null from clients where user_id=auth.uid()), true);
select pg_temp.expect('second login returns the same record', (select name from claim_my_client_account()) = 'Rozh', true);
select pg_temp.expect('email client sees only own record', (select count(*) from clients) = 1, true);

-- sneaky email user types someone else's (reception) phone
set request.jwt.claim.sub = 'a3333333-3333-3333-3333-333333333333';
select pg_temp.expect('sneaky: gets a NEW record, not Shilan''s', (select name from claim_my_client_account('Sneaky','07508887777')) = 'Sneaky', true);
select pg_temp.expect('sneaky: has 0 points (did not take Shilan''s 900)', (select points from clients where user_id=auth.uid()) = 0, true);
select pg_temp.expect('sneaky CANNOT see Shilan''s booking by phone', (select count(*) from bookings where id='bk_shilan') = 0, true);
select pg_temp.expect('sneaky CANNOT read Shilan''s record', (select count(*) from clients where name like 'Shilan%') = 0, true);

-- unconfirmed email
set request.jwt.claim.sub = 'a2222222-2222-2222-2222-222222222222';
select pg_temp.expect('unconfirmed email is refused', pg_temp.try($$select * from claim_my_client_account('X','0750 000 0000')$$), false);

-- verified WhatsApp client still links to the reception record
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
select pg_temp.expect('WhatsApp client still links to reception record', (select count(*) from claim_my_client_account()) = 1, true);
reset role;
select pg_temp.expect('Shilan''s record still unlinked', (select user_id is null from clients where name like 'Shilan%'), true);

-- someone who signed up with a PASSWORD (email never proven by a code)
set role authenticated;
set request.jwt.claim.sub = 'a4444444-4444-4444-4444-444444444444';
select pg_temp.expect('password signup (unproven email) is refused', pg_temp.try($$select * from claim_my_client_account('Fake','0750 222 3333')$$), false);
reset role;
