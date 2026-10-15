-- ============================================================================
--  Dolce+  —  SECURE STAFF SIGN-IN (wrong-PIN limits and temporary lockout)
--  FOR REVIEW. Run once in Supabase → SQL Editor → New query → Run.
--  Safe to run more than once. Used by the Edge Function "staff-auth".
-- ============================================================================
--  * 5 wrong PINs for one login within 15 minutes → that login is locked for
--    15 minutes.
--  * 30 wrong PINs from one network address within an hour → that address is
--    locked for an hour.
--  * Only the Edge Function (service role) can read or change these counters.
--  * profiles.secure_pin_at shows which staff already use the secure password
--    (set the first time they sign in through the new screen).
-- ============================================================================
alter table public.profiles add column if not exists secure_pin_at timestamptz;

create table if not exists public.staff_login_attempts (
  key          text primary key,           -- 'acct:<login slug>' or 'ip:<address>'
  fails        integer not null default 0,
  window_start timestamptz not null default now(),
  locked_until timestamptz,
  updated_at   timestamptz not null default now()
);
alter table public.staff_login_attempts enable row level security;
revoke all on public.staff_login_attempts from anon, authenticated;

create or replace function public.staff_login_gate(p_account text, p_ip text)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select jsonb_build_object('locked', true, 'until', max(locked_until))
       from public.staff_login_attempts
      where key in ('acct:' || p_account, 'ip:' || p_ip) and locked_until > now()
     having max(locked_until) is not null),
    '{"locked": false}'::jsonb);
$$;

create or replace function public.staff_login_record(p_account text, p_ip text, p_ok boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.staff_login_attempts; i public.staff_login_attempts;
begin
  if p_ok then
    delete from public.staff_login_attempts where key = 'acct:' || p_account;
    return '{"ok": true}'::jsonb;
  end if;
  insert into public.staff_login_attempts (key, fails, window_start)
  values ('acct:' || p_account, 1, now())
  on conflict (key) do update set
    fails = case when staff_login_attempts.window_start < now() - interval '15 minutes'
                 then 1 else staff_login_attempts.fails + 1 end,
    window_start = case when staff_login_attempts.window_start < now() - interval '15 minutes'
                 then now() else staff_login_attempts.window_start end,
    updated_at = now()
  returning * into a;
  if a.fails >= 5 then
    update public.staff_login_attempts set locked_until = now() + interval '15 minutes', fails = 0,
           window_start = now() where key = a.key returning * into a;
  end if;
  insert into public.staff_login_attempts (key, fails, window_start)
  values ('ip:' || p_ip, 1, now())
  on conflict (key) do update set
    fails = case when staff_login_attempts.window_start < now() - interval '1 hour'
                 then 1 else staff_login_attempts.fails + 1 end,
    window_start = case when staff_login_attempts.window_start < now() - interval '1 hour'
                 then now() else staff_login_attempts.window_start end,
    updated_at = now()
  returning * into i;
  if i.fails >= 30 then
    update public.staff_login_attempts set locked_until = now() + interval '1 hour', fails = 0,
           window_start = now() where key = i.key returning * into i;
  end if;
  if coalesce(a.locked_until, '-infinity') > now() or coalesce(i.locked_until, '-infinity') > now() then
    return jsonb_build_object('locked', true, 'until', greatest(a.locked_until, i.locked_until));
  end if;
  return jsonb_build_object('locked', false, 'left', 5 - a.fails);
end; $$;

revoke all on function public.staff_login_gate(text, text) from public, anon, authenticated;
revoke all on function public.staff_login_record(text, text, boolean) from public, anon, authenticated;
grant execute on function public.staff_login_gate(text, text) to service_role;
grant execute on function public.staff_login_record(text, text, boolean) to service_role;

notify pgrst, 'reload schema';
