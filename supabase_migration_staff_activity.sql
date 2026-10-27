-- ============================================================================
--  Dolce+  —  STAFF ACTIVITY (who is online in Admin + login history)
--  Run once in Supabase → SQL Editor. Safe to run more than once.
--  Adds one table and five functions. Changes no existing data.
--
--  How it works
--   - When a staff member opens Admin (after signing in, or with a remembered
--     login) the app starts a "session" row. While Admin is open and on screen
--     it updates last_seen_at once a minute. "Log out" closes the session.
--   - Online now = an open session seen in the last 2½ minutes.
--   - A session with no log out (tab closed, phone locked) simply ends at its
--     last_seen_at.
--   - Only OWNERS can read it. Nobody can write rows directly: staff can only
--     start / update / close THEIR OWN sessions through the functions below.
--   - Stored per session: who, start, last seen, end, how it ended, and a short
--     device label (e.g. "Mac · Chrome"). No location, no IP address.
-- ============================================================================
create table if not exists public.staff_sessions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null,
  started_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  ended_at     timestamptz,
  end_reason   text not null default '',          -- logout | closed
  device       text not null default ''
);
create index if not exists staff_sessions_user_idx on public.staff_sessions (user_id, started_at desc);
create index if not exists staff_sessions_open_idx on public.staff_sessions (last_seen_at) where ended_at is null;

alter table public.staff_sessions enable row level security;
revoke all on public.staff_sessions from anon, authenticated;
grant select on public.staff_sessions to authenticated;
drop policy if exists staff_sessions_owner_read on public.staff_sessions;
create policy staff_sessions_owner_read on public.staff_sessions for select to authenticated using (public.is_owner());

-- Start a session for the signed-in staff member. Older open sessions of the
-- same person that went quiet are closed at their last_seen_at.
create or replace function public.staff_session_start(p_device text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare sid uuid;
begin
  if auth.uid() is null or not public.is_staff() then raise exception 'STAFF_ONLY'; end if;
  update public.staff_sessions set ended_at = last_seen_at, end_reason = 'closed'
   where user_id = auth.uid() and ended_at is null and last_seen_at < now() - interval '150 seconds';
  insert into public.staff_sessions (user_id, device)
    values (auth.uid(), left(regexp_replace(coalesce(p_device, ''), '[^A-Za-z0-9 ·./()-]', '', 'g'), 60))
    returning id into sid;
  return sid;
end; $$;

-- "Still here": only the person's own, still-open session. false = start a new one.
create or replace function public.staff_session_ping(p_id uuid)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then return false; end if;
  update public.staff_sessions set last_seen_at = now()
   where id = p_id and user_id = auth.uid() and ended_at is null
     and last_seen_at > now() - interval '15 minutes';
  return found;
end; $$;

create or replace function public.staff_session_end(p_id uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.staff_sessions set ended_at = now(), last_seen_at = now(), end_reason = 'logout'
   where id = p_id and user_id = auth.uid() and ended_at is null;
$$;

-- Owners: one line per staff member — online now, last seen, sessions today.
create or replace function public.staff_activity_summary()
returns table (user_id uuid, name text, online boolean, last_seen timestamptz, device text, sessions_today int)
language sql stable security definer set search_path = public, pg_temp as $$
  select p.id, p.name,
         exists (select 1 from public.staff_sessions s where s.user_id = p.id and s.ended_at is null
                  and s.last_seen_at > now() - interval '150 seconds'),
         (select max(s.last_seen_at) from public.staff_sessions s where s.user_id = p.id),
         (select s.device from public.staff_sessions s where s.user_id = p.id order by s.last_seen_at desc limit 1),
         (select count(*)::int from public.staff_sessions s where s.user_id = p.id
                  and s.started_at >= date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad')
    from public.profiles p
   where public.is_owner()
   order by p.name;
$$;

-- Owners: the history of one person (newest first).
create or replace function public.staff_activity_history(p_user uuid, p_limit int default 40)
returns table (started_at timestamptz, last_seen_at timestamptz, ended_at timestamptz, end_reason text, device text, online boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select s.started_at, s.last_seen_at, coalesce(s.ended_at, case when s.last_seen_at < now() - interval '150 seconds' then s.last_seen_at end),
         case when s.ended_at is not null then s.end_reason
              when s.last_seen_at < now() - interval '150 seconds' then 'closed' else '' end,
         s.device,
         s.ended_at is null and s.last_seen_at > now() - interval '150 seconds'
    from public.staff_sessions s
   where public.is_owner() and s.user_id = p_user
   order by s.started_at desc
   limit least(greatest(coalesce(p_limit, 40), 1), 200);
$$;

revoke all on function public.staff_session_start(text)               from public, anon;
revoke all on function public.staff_session_ping(uuid)                from public, anon;
revoke all on function public.staff_session_end(uuid)                 from public, anon;
revoke all on function public.staff_activity_summary()                from public, anon;
revoke all on function public.staff_activity_history(uuid, int)       from public, anon;
grant execute on function public.staff_session_start(text)            to authenticated;
grant execute on function public.staff_session_ping(uuid)             to authenticated;
grant execute on function public.staff_session_end(uuid)              to authenticated;
grant execute on function public.staff_activity_summary()             to authenticated;
grant execute on function public.staff_activity_history(uuid, int)    to authenticated;

notify pgrst, 'reload schema';

-- Result: should list 5 functions, visitor = false.
select p.proname as function, has_function_privilege('anon', p.oid, 'EXECUTE') as visitor
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and (p.proname like 'staff_session%' or p.proname like 'staff_activity%')
 order by 1;
