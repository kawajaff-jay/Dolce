-- Dolce+ — let staff edit service categories from the Admin App.
-- Run once in Supabase → SQL Editor → New query → Run. Safe to run again.
--
-- Categories are stored in the settings table, one row per brand
-- ('categories:dolce', 'categories:polished', 'categories:core').
-- Who may change them: the owner, or a member of staff who can edit that
-- brand's Services. Everyone else (and clients) can only read them.

drop policy if exists settings_write on public.settings;
create policy settings_write on public.settings for all to authenticated
  using (
       (key = 'image_focus' and public.is_staff())
    or (key like 'categories:%' and public.can_write('services', split_part(key, ':', 2)))
    or public.is_owner()
  )
  with check (
       (key = 'image_focus' and public.is_staff())
    or (key like 'categories:%' and public.can_write('services', split_part(key, ':', 2)))
    or public.is_owner()
  );

notify pgrst, 'reload schema';
