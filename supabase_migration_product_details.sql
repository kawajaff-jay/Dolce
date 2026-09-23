-- Products can now have a description and several photos, so a customer can
-- tap one in the Shop and see it properly. Two new columns, nothing removed.
-- Run this BEFORE saving a product in the new version of the app.

alter table public.products add column if not exists description text default '';
alter table public.products add column if not exists images jsonb default '[]'::jsonb;

-- Check:
select column_name, data_type from information_schema.columns
where table_schema = 'public' and table_name = 'products'
order by ordinal_position;
