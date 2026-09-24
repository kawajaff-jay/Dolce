-- Dolce+ luxury Home & Shop — new fields the Admin App can now edit.
--
-- Safe to run more than once ("if not exists"). It only ADDS columns with
-- sensible defaults; no existing data is changed or removed, and no security
-- rules change (the existing policies on these tables already cover new
-- columns).
--
-- Until this has been run, the app keeps working: it notices a missing column,
-- saves everything else, and leaves that one field on the device only.

-- ---- Offers table: now holds offers, events and "Curated for you" features ----
alter table public.offers add column if not exists kind        text    not null default 'offer';   -- 'offer' | 'event' | 'curated'
alter table public.offers add column if not exists starts_on   date;
alter table public.offers add column if not exists ends_on     date;                               -- hidden from the app after this day
alter table public.offers add column if not exists badge       text    not null default '';        -- e.g. "−20%", "New"
alter table public.offers add column if not exists sort_order  integer not null default 0;         -- lower shows first
alter table public.offers add column if not exists active      boolean not null default true;      -- untick to hide without deleting
alter table public.offers add column if not exists link        text    not null default '';        -- what a tap opens, e.g. brand:dolce, product:p3

-- ---- Products: collection, sizes/colours, order, on/off ----
alter table public.products add column if not exists category   text    not null default '';
alter table public.products add column if not exists options    jsonb   not null default '[]'::jsonb;  -- [{"name":"Size","values":["30 ml","50 ml"]}]
alter table public.products add column if not exists sort_order integer not null default 0;
alter table public.products add column if not exists active     boolean not null default true;

-- Destinations (home-screen brand cards: name, subtitle, logo, order, shown)
-- need no new table: they are stored in the existing settings table under
-- the key 'destinations', which only the owner can write.

-- Make the API see the new columns straight away.
notify pgrst, 'reload schema';
