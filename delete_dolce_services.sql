-- Clears out the old demo Dolce services so the clinic can start clean with
-- the new category list. Polished and Core are untouched.
-- Past bookings keep the service name they were made with, so the diary and
-- reports still read correctly.

delete from public.services where brand = 'dolce';

-- Check what is left (should be Polished and Core only):
select brand, count(*) from public.services group by brand order by brand;
