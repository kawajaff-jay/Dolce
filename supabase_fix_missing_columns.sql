-- Dolce+ : make sure every column the app saves into actually exists.
--
-- Why: saving an offer failed with
--   "Could not find the 'image' column of 'offers' in the schema cache".
-- The live database has drifted from the reference file before, so this adds
-- EVERY column the app writes to, in every table, but only where it is
-- missing ("if not exists"). Nothing that already exists is changed and no
-- data is touched. Safe to run more than once.

-- offers
alter table public.offers add column if not exists title      text;
alter table public.offers add column if not exists subtitle   text default '';
alter table public.offers add column if not exists image      text default '';

-- services
alter table public.services add column if not exists category         text;
alter table public.services add column if not exists duration         text;
alter table public.services add column if not exists price_usd        numeric(10,2) default 0;
alter table public.services add column if not exists discount_percent integer default 0;
alter table public.services add column if not exists description      text default '';
alter table public.services add column if not exists points           jsonb default '[]'::jsonb;
alter table public.services add column if not exists image            text default '';
alter table public.services add column if not exists aftercare        text default '';
alter table public.services add column if not exists sort_order       integer default 0;

-- products
alter table public.products add column if not exists price_usd        numeric(10,2) default 0;
alter table public.products add column if not exists discount_percent integer default 0;
alter table public.products add column if not exists stock            integer default 0;
alter table public.products add column if not exists image            text default '';
alter table public.products add column if not exists description      text default '';
alter table public.products add column if not exists images           jsonb default '[]'::jsonb;

-- bookings
alter table public.bookings add column if not exists service_id    text;
alter table public.bookings add column if not exists service_name  text;
alter table public.bookings add column if not exists date_label    text;
alter table public.bookings add column if not exists time_label    text;
alter table public.bookings add column if not exists date_iso      date;
alter table public.bookings add column if not exists client_name   text;
alter table public.bookings add column if not exists client_id     text;
alter table public.bookings add column if not exists client_phone  text default '';
alter table public.bookings add column if not exists aftercare_ok  boolean default false;

-- media (client before/after photos)
alter table public.media add column if not exists service_id  text default '';
alter table public.media add column if not exists type        text default 'photo';
alter table public.media add column if not exists kind        text default 'before-after';
alter table public.media add column if not exists visibility  text default 'private';
alter table public.media add column if not exists consent     boolean default false;
alter table public.media add column if not exists client_name text default '';
alter table public.media add column if not exists note        text default '';
alter table public.media add column if not exists data_url    text;
alter table public.media add column if not exists mime        text;

-- purchases (restocking)
alter table public.purchases add column if not exists product_id    text;
alter table public.purchases add column if not exists name          text;
alter table public.purchases add column if not exists qty           integer default 0;
alter table public.purchases add column if not exists unit_cost_usd numeric(10,2) default 0;
alter table public.purchases add column if not exists total_usd     numeric(12,2) default 0;
alter table public.purchases add column if not exists supplier      text default '';
alter table public.purchases add column if not exists date_label    text;
alter table public.purchases add column if not exists date_iso      date;

-- product_sales
alter table public.product_sales add column if not exists product_id     text;
alter table public.product_sales add column if not exists name           text;
alter table public.product_sales add column if not exists qty            integer default 0;
alter table public.product_sales add column if not exists unit_price_usd numeric(10,2) default 0;
alter table public.product_sales add column if not exists total_usd      numeric(12,2) default 0;
alter table public.product_sales add column if not exists client_name    text default '';
alter table public.product_sales add column if not exists date_label     text;
alter table public.product_sales add column if not exists date_iso       date;

-- register_closes
alter table public.register_closes add column if not exists date_label         text;
alter table public.register_closes add column if not exists date_iso           date;
alter table public.register_closes add column if not exists brands             text[] default '{}';
alter table public.register_closes add column if not exists expected_total_usd numeric(12,2) default 0;
alter table public.register_closes add column if not exists counted_cash_usd   numeric(12,2) default 0;
alter table public.register_closes add column if not exists counted_card_usd   numeric(12,2) default 0;
alter table public.register_closes add column if not exists counted_total_usd  numeric(12,2) default 0;
alter table public.register_closes add column if not exists notes              text default '';
alter table public.register_closes add column if not exists closed_by          text;
alter table public.register_closes add column if not exists closed_at          text;

-- brand_images
alter table public.brand_images add column if not exists image_url text default '';

-- Tell the database's API to pick up the new columns straight away
-- (the "schema cache" in the error message).
notify pgrst, 'reload schema';

-- Check: offers should now list id, brand, title, subtitle, image, ...
select column_name, data_type from information_schema.columns
where table_schema = 'public' and table_name = 'offers'
order by ordinal_position;
