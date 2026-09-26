-- Core: rename the category "Duet pilates" to "Duet Private Training".
-- Safe to run more than once. Only changes the category name on Core services.
update public.services
   set category = 'Duet Private Training'
 where brand = 'core' and category = 'Duet pilates';
