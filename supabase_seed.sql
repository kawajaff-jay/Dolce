-- ============================================================================
--  Dolce / Polished / Core  —  STARTING DATA
--  Run this AFTER supabase_schema.sql and supabase_auth_setup.sql.
-- ============================================================================
--
--  This is the catalog the app has always shipped with, moved into the
--  database so every device reads the same list.
--
--  SAFE TO RE-RUN. Every statement ends in "on conflict do nothing", which
--  means: if a row with that ID is already there, leave it exactly as it is.
--  So if you have already edited a price, added a service or deleted one you
--  did not want, running this file again will NOT undo your work and will NOT
--  bring deleted rows back to life.
--
--  All prices are US dollars.
-- ============================================================================


-- ---- Dolce — Aesthetic Clinic ----------------------------------------------
insert into public.services (id, brand, name, category, duration, price_usd, discount_percent, description, points, sort_order) values
 ('hydra','dolce','Hydrafacial','Skincare','60 min',120,20,'Deep cleansing, exfoliation and hydration to reveal smooth, glowing skin.','["Cleanses & detoxifies","Improves hydration","Brightens complexion","Suitable for all skin types"]',1),
 ('fillers','dolce','Dermal Fillers','Injectables','45 min',250,0,'Restores volume and softens fine lines for a natural, refreshed look.','["Performed by licensed provider","Results visible immediately","Minimal downtime"]',2),
 ('laser','dolce','Laser Hair Removal','Body','30 min',90,0,'Long-term hair reduction using medical-grade laser technology.','["Suitable for most skin tones","Series recommended for best results"]',3),
 ('peel','dolce','Chemical Peel','Skincare','45 min',110,0,'Resurfaces skin to reduce texture, tone and pigmentation concerns.','["Improves skin texture","Reduces pigmentation","Customized strength"]',4),
 ('led','dolce','LED Therapy','Skincare','30 min',70,0,'Light-based therapy to calm inflammation and boost collagen.','["Calms acne-prone skin","Boosts collagen","No downtime"]',5),
 ('botox','dolce','Botox','Injectables','30 min',220,0,'Smooths expression lines for a refreshed, natural appearance.','["Quick in-clinic treatment","Results within 3-7 days"]',6)
on conflict (id) do nothing;

-- ---- Polished by Dolce — Hair & Nail Salon ---------------------------------
insert into public.services (id, brand, name, category, duration, price_usd, discount_percent, description, points, sort_order) values
 ('cut','polished','Haircut & Style','Hair','45 min',35,0,'Precision cut and blow-dry styled to suit your face and lifestyle.','["Consultation included","Finished with styling"]',1),
 ('balayage','polished','Balayage Color','Hair','120 min',150,15,'Hand-painted, low-maintenance color for natural dimension.','["Custom color mapping","Includes toning & gloss"]',2),
 ('gelmani','polished','Gel Manicure','Nails','40 min',30,0,'Long-lasting gel polish with full nail prep and shaping.','["Chip-resistant finish","Lasts up to 3 weeks"]',3),
 ('pedi','polished','Deluxe Pedicure','Nails','50 min',40,0,'Soak, exfoliation, massage and polish for complete foot care.','["Includes callus treatment","Relaxing massage"]',4),
 ('keratin','polished','Keratin Treatment','Hair','90 min',130,0,'Smoothing treatment that reduces frizz for up to 3 months.','["Reduces frizz","Cuts blow-dry time"]',5),
 ('nailart','polished','Nail Art Add-on','Nails','20 min',15,0,'Custom nail art added to any manicure or pedicure.','["Fully customizable","Add to any service"]',6)
on conflict (id) do nothing;

-- ---- Core — Yoga & Pilates Studio ------------------------------------------
insert into public.services (id, brand, name, category, duration, price_usd, discount_percent, description, points, sort_order) values
 ('vinyasa','core','Vinyasa Flow Class','Yoga','60 min',20,0,'A dynamic, breath-linked flow suitable for most levels.','["All levels welcome","Mats provided"]',1),
 ('reformer','core','Reformer Pilates','Pilates','50 min',35,0,'Full-body strength and control training on the reformer machine.','["Small class sizes","Great for posture & core"]',2),
 ('prenatal','core','Prenatal Yoga','Yoga','60 min',25,0,'Gentle, supportive practice designed for expecting mothers.','["Certified prenatal instructor","Focus on breath & comfort"]',3),
 ('matpil','core','Mat Pilates','Pilates','45 min',22,0,'Bodyweight Pilates focused on core strength and alignment.','["No equipment needed","Beginner friendly"]',4),
 ('private','core','Private Session','Recovery','60 min',60,0,'One-on-one coaching tailored to your goals and recovery needs.','["Fully personalized","Choice of yoga or pilates focus"]',5),
 ('sound','core','Sound Bath Recovery','Recovery','45 min',30,0,'Guided relaxation using resonant sound for deep recovery.','["Deep relaxation","Great after intense training"]',6)
on conflict (id) do nothing;

-- ---- Retail products -------------------------------------------------------
insert into public.products (id, brand, name, price_usd, discount_percent, stock) values
 ('p1','dolce','Skin Hydrating Serum',65,0,24),
 ('p2','polished','Hair Repair Mask',45,0,18),
 ('p3','core','Wellness Yoga Mat',55,10,12),
 ('p4','dolce','Vitamin C Booster',40,0,4),
 ('p5','polished','Nail Strengthener Kit',25,0,30),
 ('p6','core','Pilates Resistance Band',28,0,0)
on conflict (id) do nothing;

-- ---- Welcome-screen offers -------------------------------------------------
insert into public.offers (id, brand, title, subtitle) values
 ('o1','dolce','Glow Season','20% off all facials'),
 ('o2','polished','Bridal Package','Complete beauty for your big day'),
 ('o3','core','Pilates Workshop','Core strength, better you')
on conflict (id) do nothing;

-- ---- One hero photo slot per brand (filled in from the Overview tab) --------
insert into public.brand_images (brand, image_url) values
 ('dolce',''), ('polished',''), ('core','')
on conflict (brand) do nothing;

-- ---- Settings --------------------------------------------------------------
--  The USD -> IQD rate used only for showing prices in dinar. Edit it from the
--  Overview tab in the app whenever the market rate moves.
insert into public.settings (key, value) values ('usd_to_iqd','1450')
on conflict (key) do nothing;


-- ============================================================================
--  Did it work? Run this to see what is now in the database:
--
--    select brand, count(*) from public.services group by brand order by brand;
--    select count(*) as products from public.products;
--    select count(*) as offers   from public.offers;
--    select * from public.settings;
-- ============================================================================
