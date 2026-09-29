-- Dolce+  —  extra photos for services
-- Lets each service keep several photos (clients swipe through them and can
-- open them full screen), the same way products already do.
-- Safe to run more than once. Changes no existing data.

alter table public.services add column if not exists images jsonb not null default '[]'::jsonb;

notify pgrst, 'reload schema';

-- Check: should show one row, "images | jsonb".
select column_name, data_type from information_schema.columns
 where table_schema = 'public' and table_name = 'services' and column_name = 'images';
