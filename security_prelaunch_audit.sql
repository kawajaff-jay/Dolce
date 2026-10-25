-- ============================================================================
--  Dolce+  —  PRE-LAUNCH SECURITY AUDIT  (READ-ONLY: changes nothing)
--  Supabase → SQL Editor → New query → paste all → Run.
--  One table comes back (section · item · detail). Download it as CSV and
--  send it to Claude. It contains rule definitions and staff names, but no
--  client data, no PINs, no passwords and no secrets.
-- ============================================================================
with
-- 1. Tables: security rules on/off, and what the app key roles may do at table level
t as (
  select c.oid, n.nspname as s, c.relname as name, c.relrowsecurity as rls, c.relforcerowsecurity as force_rls
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where c.relkind in ('r','p') and n.nspname in ('public','storage')
),
rows as (
  select 1 as ord, 'table' as section, s || '.' || name as item,
    'rls=' || rls || ' force=' || force_rls ||
    ' | anon:' || concat_ws(',',
        case when has_table_privilege('anon', oid, 'SELECT') then 'S' end,
        case when has_table_privilege('anon', oid, 'INSERT') then 'I' end,
        case when has_table_privilege('anon', oid, 'UPDATE') then 'U' end,
        case when has_table_privilege('anon', oid, 'DELETE') then 'D' end) ||
    ' | authenticated:' || concat_ws(',',
        case when has_table_privilege('authenticated', oid, 'SELECT') then 'S' end,
        case when has_table_privilege('authenticated', oid, 'INSERT') then 'I' end,
        case when has_table_privilege('authenticated', oid, 'UPDATE') then 'U' end,
        case when has_table_privilege('authenticated', oid, 'DELETE') then 'D' end) as detail
  from t where s = 'public' or name = 'objects'

  union all
  -- 2. Every security rule, in full
  select 2, 'policy', schemaname || '.' || tablename || ' · ' || policyname,
    cmd || ' ' || permissive || ' roles=' || roles::text ||
    ' | USING: ' || coalesce(qual, '-') || ' | CHECK: ' || coalesce(with_check, '-')
  from pg_policies where schemaname in ('public','storage')

  union all
  -- 3. Database functions callable by the app key (visitor) or any logged-in user
  select 3, 'function', p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
    case when p.prosecdef then 'SECURITY DEFINER' else 'invoker' end ||
    ' | anon=' || has_function_privilege('anon', p.oid, 'EXECUTE') ||
    ' authenticated=' || has_function_privilege('authenticated', p.oid, 'EXECUTE') ||
    ' | search_path=' || coalesce(array_to_string(p.proconfig, ';'), 'NOT SET')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'

  union all
  -- 4. Storage folders: public or private, size and type limits
  select 4, 'bucket', id,
    'public=' || public || ' | size_limit=' || coalesce(file_size_limit::text, 'NONE') ||
    ' | types=' || coalesce(array_to_string(allowed_mime_types, ','), 'ANY')
  from storage.buckets

  union all
  -- 5. Staff accounts: secure sign-in status (no PINs shown)
  select 5, 'staff', coalesce(p.name, '(no name)'),
    'owner=' || coalesce(p.is_owner, false) ||
    ' | secure_pin_at=' || coalesce(to_jsonb(p)->>'secure_pin_at', 'NULL (old PIN password still works)') ||
    ' | last_sign_in=' || coalesce(to_char(u.last_sign_in_at, 'YYYY-MM-DD'), 'never') ||
    ' | brands=' || coalesce(to_jsonb(p)->>'brands', '?') || ' | tabs=' || coalesce(to_jsonb(p)->>'tabs', '?')
  from public.profiles p left join auth.users u on u.id = p.id

  union all
  -- 6. Logins by type (counts only)
  select 6, 'auth users', 'totals',
    'all=' || count(*) ||
    ' | staff=' || count(*) filter (where exists (select 1 from public.profiles p where p.id = u.id)) ||
    ' | phone=' || count(*) filter (where coalesce(u.phone,'') <> '') ||
    ' | email=' || count(*) filter (where coalesce(u.email,'') <> '' and u.email not like '%@staff.dolce-app.internal') ||
    ' | anonymous=' || count(*) filter (where coalesce((to_jsonb(u)->>'is_anonymous')::boolean, false))
  from auth.users u

  union all
  -- 7. Settings keys anyone can read (names and size only — no values)
  select 7, 'setting', key, 'length=' || length(value::text)
  from public.settings

  union all
  -- 9. Login-attempt table for staff lockouts (exists?)
  select 9, 'lockout table', 'staff_login_attempts',
    case when to_regclass('public.staff_login_attempts') is null then 'MISSING' else 'present' end

  union all
  select 9, 'mindbody tables', x,
    case when to_regclass('public.' || x) is null then 'MISSING' else 'present' end
  from unnest(array['mindbody_cache','mindbody_clients','mindbody_booking_attempts','mindbody_link_issues']) x

  union all
  -- 10. Extensions installed
  select 10, 'extension', extname, extversion from pg_extension
)
select section, item, detail from rows order by ord, item;
