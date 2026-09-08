-- ============================================================================
--  Dolce / Polished / Core  —  AUTH & STAFF LOGIN SETUP
--  Run this AFTER supabase_schema.sql.
-- ============================================================================
--
--  HOW STAFF LOGIN ACTUALLY WORKS
--  On screen it looks the same as it always did: pick your name, type your
--  4-digit PIN. Behind that, every employee has a real (hidden) Supabase
--  account. Its email address is a placeholder nobody ever emails
--  (emp-<random>@staff.dolce-app.internal) and its password is that person's
--  PIN with a fixed prefix added, because Supabase requires at least six
--  characters. The PIN itself is never stored anywhere in the app or in these
--  tables — Supabase stores it hashed, the same way it stores any password.
--
--  The login screen needs to list who works here BEFORE anyone has logged in,
--  which is what the function below is for. It hands out names only. PINs,
--  departments and section permissions stay private until that person
--  actually signs in.
-- ============================================================================


-- ----------------------------------------------------------------------------
--  list_staff_names() — the names on the login screen
-- ----------------------------------------------------------------------------
--  SECURITY DEFINER lets this read the profiles table even though the caller
--  is not logged in yet. It deliberately returns three harmless columns and
--  never brands, tabs, is_owner or anything else.
create or replace function public.list_staff_names()
returns table (id uuid, name text, login_slug text)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.id, p.name, p.login_slug
  from public.profiles p
  where p.login_slug is not null
  order by p.name;
$$;

revoke all on function public.list_staff_names() from public;
grant execute on function public.list_staff_names() to anon, authenticated;

-- The permission helpers used by the security rules are called by the database
-- itself while checking a policy, but granting execute explicitly keeps things
-- predictable.
grant execute on function public.my_brands()          to authenticated;
grant execute on function public.my_tabs()            to authenticated;
grant execute on function public.is_owner()           to authenticated;
grant execute on function public.has_tab(text)        to authenticated;
grant execute on function public.can_brand(text)      to authenticated;
grant execute on function public.can_brands(text[])   to authenticated;
grant execute on function public.can_write(text,text) to authenticated;


-- ----------------------------------------------------------------------------
--  Housekeeping: if an auth user is deleted, its profile goes with it
-- ----------------------------------------------------------------------------
--  This is already handled by "references auth.users(id) on delete cascade"
--  in the schema file. Nothing to do here — noted so it is not a mystery.


-- ============================================================================
--  ONE-TIME BOOTSTRAP  —  read this, then run the part you need
-- ============================================================================
--
--  1. MAKE YOURSELF THE OWNER
--     An owner can see everything and manage employees. If your account is
--     not flagged as owner yet, run this once with your own name:
--
--        update public.profiles
--        set is_owner = true,
--            brands   = array['dolce','polished','core'],
--            tabs     = array['overview','bookings','products','services',
--                             'offers','gallery','employees','reports','purchases']
--        where name = 'Kawa';
--
--
--  2. CHECK WHO EXISTS RIGHT NOW
--     Useful before and after, to see exactly what the database thinks:
--
--        select name, is_owner, brands, tabs, login_slug from public.profiles
--        order by name;
--
--
--  3. IF A PROFILE IS MISSING ITS LOGIN NAME
--     A profile with no login_slug will not appear on the login screen. That
--     normally means the row was created by hand rather than through the
--     Employees tab. Give it one:
--
--        update public.profiles
--        set login_slug = replace(gen_random_uuid()::text, '-', '')
--        where login_slug is null;
--
--
--  4. TURN OFF EMAIL CONFIRMATION (important, do this once)
--     Staff accounts use placeholder email addresses that can never receive a
--     confirmation link. If Supabase is set to require confirmation, creating
--     a new employee will appear to work but that person will not be able to
--     log in. In the Supabase dashboard go to:
--
--        Authentication -> Sign In / Providers -> Email
--        -> turn OFF "Confirm email"
--
--     This is a dashboard setting, not something SQL can change.
-- ============================================================================
