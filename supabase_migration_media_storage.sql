-- Dolce+ media storage
-- Creates a "media" bucket for the pictures the Admin App publishes to the
-- Client App (products, services, home cards, offer banners). The database
-- keeps just the picture's address; the picture itself lives here as a file.
--
-- Anyone can VIEW these pictures (they are shown to customers).
-- Only signed-in staff can ADD, CHANGE or REMOVE them.
--
-- Client before/after photos are NOT stored here — they stay in the
-- protected database table as before.
--
-- Safe to run more than once.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', true, 8388608, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "media: staff upload"  on storage.objects;
drop policy if exists "media: staff update"  on storage.objects;
drop policy if exists "media: staff delete"  on storage.objects;
drop policy if exists "media: public read"   on storage.objects;

create policy "media: public read" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'media');

create policy "media: staff upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'media');

create policy "media: staff update" on storage.objects
  for update to authenticated
  using (bucket_id = 'media') with check (bucket_id = 'media');

create policy "media: staff delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'media');

-- Check:
select id, public, file_size_limit from storage.buckets where id = 'media';
