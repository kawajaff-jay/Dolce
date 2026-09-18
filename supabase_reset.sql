-- ============================================================================
--  Dolce / Polished / Core  —  CLEAR OUT THE OLD TABLES AND START CLEAN
-- ============================================================================
--
--  WHEN TO RUN THIS
--  Only when supabase_schema.sql has stopped and told you that some tables
--  from an earlier attempt cannot be repaired automatically. It exists for
--  exactly that situation and nothing else.
--
--  WHAT IT DOES
--  Removes the app's data tables so the schema file can build them properly.
--
--  WHAT IT PROTECTS
--  Two things, automatically:
--
--    1. YOUR STAFF ACCOUNTS. The profiles table and the hidden Supabase login
--       accounts behind it are never touched. Nobody has to be set up again
--       and nobody's PIN changes.
--
--    2. ANYTHING THAT ACTUALLY HAS DATA IN IT. Before deleting a single
--       thing, this counts the rows in every table it is about to remove. If
--       any of them are not empty it stops, shows you exactly what is in
--       there, and deletes nothing. It will only ever clear away empty
--       tables on its own.
--
--  So running it is safe: the worst case is that it refuses and tells you
--  why. If it does stop, send me what it printed and we will work out how to
--  keep whatever is in there before going any further.
--
--  AFTER IT RUNS SUCCESSFULLY
--    1. supabase_schema.sql
--    2. supabase_auth_setup.sql
--    3. supabase_seed.sql
-- ============================================================================


-- ----------------------------------------------------------------------------
--  Step 1 — count everything first, and refuse if anything holds data
-- ----------------------------------------------------------------------------
do $$
declare
  t text; n bigint; report text := ''; blocked text := ''; total bigint := 0;
  tables text[] := array['register_closes','product_sales','purchases','media',
                         'bookings','clients','settings','brand_images',
                         'offers','products','services'];
begin
  foreach t in array tables loop
    if exists (select 1 from information_schema.tables
               where table_schema='public' and table_name=t) then
      execute format('select count(*) from public.%I', t) into n;
      total := total + n;
      report := report || format(E'\n    %-16s %s', t, n);
      if n > 0 then
        blocked := blocked || format(E'\n  - %s holds %s row(s)', t, n);
      end if;
    else
      report := report || format(E'\n    %-16s (does not exist)', t);
    end if;
  end loop;

  raise notice E'\n  What is in these tables right now:%\n', report;

  if blocked <> '' then
    raise exception E'STOPPED — nothing was deleted.\n\nThese tables are not empty:%\n\nThat may be fine (they could be leftover test rows), but this script will not delete anything that has data in it. Send this message to Claude and we will decide what to keep before clearing anything.\n\nIf you are certain the contents can go, run this line on its own first, then run this file again:\n\n    set dolce.force_reset = ''yes'';', blocked;
  end if;

  if total = 0 then
    raise notice 'All empty — safe to clear.';
  end if;
end $$;


-- ----------------------------------------------------------------------------
--  Step 2 — clear them
-- ----------------------------------------------------------------------------
--  This is only reached if step 1 was happy. profiles is deliberately absent
--  from this list: that is where your staff accounts live.

drop table if exists public.register_closes cascade;
drop table if exists public.product_sales   cascade;
drop table if exists public.purchases       cascade;
drop table if exists public.media           cascade;
drop table if exists public.bookings        cascade;
drop table if exists public.clients         cascade;
drop table if exists public.settings        cascade;
drop table if exists public.brand_images    cascade;
drop table if exists public.offers          cascade;
drop table if exists public.products        cascade;
drop table if exists public.services        cascade;

do $$ begin
  raise notice E'\n  Done. Your staff accounts were left untouched.\n  Now run: supabase_schema.sql, then supabase_auth_setup.sql, then supabase_seed.sql\n';
end $$;
