-- ============================================================================
--  Dolce+  —  D+ LOYALTY PROGRAM (phase 1)
--  Run this whole file once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Nothing is deleted.
-- ============================================================================
--  * point_transactions — every point added or removed, with the reason, the
--    staff member and the money that earned it. It is a ledger: rows are never
--    edited or deleted; a mistake is fixed with a new "adjust" row.
--  * clients.points stays as the balance, kept in step automatically from the
--    ledger (staff can no longer type a balance in directly).
--  * rewards — the D+ Rewards Shop (owner edits; everyone can see active ones).
--  * bookings.source — 'app' when the client booked in Dolce+ (1.25x points).
--  Membership level (Member / Gold / Black) is worked out from the money spent
--  in the last 12 months (the "spend" column), never from the points balance,
--  so redeeming a reward never lowers a client's level.
-- ============================================================================

alter table public.bookings add column if not exists source text not null default '';

create table if not exists public.point_transactions (
  id          uuid primary key default gen_random_uuid(),
  client_id   text not null,
  kind        text not null check (kind in ('earn','redeem','adjust','bonus','expire','opening')),
  points      integer not null,
  spend       numeric(12,2) not null default 0,
  brand       text not null default '',
  booking_id  text,
  reward_id   text,
  reason      text not null default '',
  staff_name  text not null default '',
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  constraint pt_reason_needed check (kind not in ('adjust','redeem') or length(btrim(reason)) > 0),
  constraint pt_sign check (
    (kind in ('earn','bonus','opening') and points >= 0) or
    (kind in ('redeem','expire') and points <= 0) or kind = 'adjust')
);
create index if not exists pt_client_idx on public.point_transactions (client_id, created_at desc);
-- A booking can earn points only once.
create unique index if not exists pt_one_earn_per_booking on public.point_transactions (booking_id) where kind = 'earn';

alter table public.point_transactions enable row level security;

drop policy if exists pt_staff_read  on public.point_transactions;
drop policy if exists pt_client_read on public.point_transactions;
drop policy if exists pt_staff_add   on public.point_transactions;
create policy pt_staff_read  on public.point_transactions for select to authenticated using (public.is_staff());
create policy pt_client_read on public.point_transactions for select to authenticated
  using (client_id = any(public.my_client_ids()));
create policy pt_staff_add   on public.point_transactions for insert to authenticated
  with check (public.is_staff() and created_by = auth.uid());
-- (no update / delete policies: the ledger cannot be rewritten from the app)
revoke update, delete on public.point_transactions from anon, authenticated;

-- Keep clients.points equal to the ledger, and never let a balance go below 0.
create or replace function public.apply_point_transaction()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare bal integer;
begin
  select points into bal from public.clients where id::text = new.client_id for update;
  if not found then
    raise exception 'Unknown client' using errcode = '23503';
  end if;
  if coalesce(bal, 0) + new.points < 0 then
    raise exception 'Not enough points (balance %)', coalesce(bal, 0) using errcode = '23514';
  end if;
  update public.clients set points = coalesce(points, 0) + new.points where id::text = new.client_id;
  return new;
end;
$$;
drop trigger if exists pt_apply on public.point_transactions;

-- Opening balances: whatever clients already have becomes their first row
-- (only once, and before the trigger exists so it is not counted twice).
insert into public.point_transactions (client_id, kind, points, reason, staff_name, created_by)
select c.id::text, 'opening', c.points, 'Opening balance', 'System', null
  from public.clients c
 where coalesce(c.points, 0) > 0
   and not exists (select 1 from public.point_transactions p where p.client_id = c.id::text);

create trigger pt_apply before insert on public.point_transactions
  for each row execute function public.apply_point_transaction();

-- From now on the balance changes only through the ledger. (Staff may still
-- edit a client's name and phone.)
create or replace function public.guard_client_points()
returns trigger
language plpgsql
as $$
begin
  if new.points is distinct from old.points and pg_trigger_depth() < 2 and auth.uid() is not null then
    new.points := old.points;
  end if;
  return new;
end;
$$;
drop trigger if exists clients_guard_points on public.clients;
create trigger clients_guard_points before update on public.clients
  for each row execute function public.guard_client_points();

-- Rewards Shop
create table if not exists public.rewards (
  id          text primary key,
  name        text not null,
  name_ar     text not null default '',
  name_ku     text not null default '',
  brand       text not null default 'all',
  points      integer not null check (points > 0),
  active      boolean not null default true,
  starts_on   date,
  ends_on     date,
  sort_order  integer not null default 0,
  created_at  timestamptz not null default now()
);
alter table public.rewards enable row level security;
drop policy if exists rewards_read  on public.rewards;
drop policy if exists rewards_write on public.rewards;
create policy rewards_read  on public.rewards for select to anon, authenticated using (true);
create policy rewards_write on public.rewards for all to authenticated
  using (public.is_owner()) with check (public.is_owner());
grant select on public.rewards to anon, authenticated;
grant insert, update, delete on public.rewards to authenticated;
grant select, insert on public.point_transactions to authenticated;

-- The launch rewards from the loyalty guide (only added if the shop is empty).
insert into public.rewards (id, name, name_ar, name_ku, brand, points, sort_order)
select * from (values
  ('rw_matcha',   'Free matcha at Core', 'ماتشا مجانية في Core', 'ماتچای بێبەرامبەر لە Core', 'core', 150, 10),
  ('rw_socks',    'Core grip socks', 'جوارب Core المانعة للانزلاق', 'گۆرەوی Core', 'core', 250, 20),
  ('rw_pol15',    '$15 Polished service credit', 'رصيد 15$ لخدمات Polished', '15$ باڵانس بۆ خزمەتگوزاری Polished', 'polished', 350, 30),
  ('rw_poladd',   'Complimentary Polished add-on', 'إضافة مجانية في Polished', 'زیادکراوێکی بێبەرامبەر لە Polished', 'polished', 500, 40),
  ('rw_dol30',    '$30 Dolce treatment credit', 'رصيد 30$ لعلاجات Dolce', '30$ باڵانس بۆ چارەسەری Dolce', 'dolce', 600, 50),
  ('rw_coreclass','Complimentary Core class', 'حصة مجانية في Core', 'وانەیەکی بێبەرامبەر لە Core', 'core', 750, 60),
  ('rw_dolprem',  'Premium Dolce treatment / facial add-on', 'علاج مميز أو إضافة للعناية بالبشرة في Dolce', 'چارەسەری تایبەت یان زیادکراوی پێست لە Dolce', 'dolce', 1000, 70),
  ('rw_dol75',    '$75 Dolce treatment credit', 'رصيد 75$ لعلاجات Dolce', '75$ باڵانس بۆ چارەسەری Dolce', 'dolce', 1500, 80),
  ('rw_all100',   '$100 reward across Dolce / Polished / Core', 'مكافأة 100$ في Dolce وPolished وCore', 'خەڵاتی 100$ لە Dolce و Polished و Core', 'all', 2000, 90)
) v(id, name, name_ar, name_ku, brand, points, sort_order)
where not exists (select 1 from public.rewards);

notify pgrst, 'reload schema';
