-- The old Core categories (Pilates, Recovery) no longer exist, so these
-- demo services are moved to the closest new one. Polished's existing
-- services are already under Hair / Nails, which both still exist.

update public.services set category = 'Reformer pilates' where id = 'reformer';
update public.services set category = 'Mat pilates'      where id = 'matpil';
update public.services set category = 'Private Training' where id = 'private';
update public.services set category = 'Yoga'             where id = 'sound';

select brand, name, category from public.services
where brand in ('core','polished') order by brand, category, name;
