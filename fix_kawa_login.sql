-- Re-links your owner profile to the recreated login account.
-- Replace PASTE-NEW-USER-ID-HERE with the ID shown after creating the
-- emp-kawa@staff.dolce-app.internal user, then run this.
insert into profiles (id, name, brands, tabs, is_owner, login_slug) values
  ('PASTE-NEW-USER-ID-HERE', 'Kawa', array['dolce','polished','core'],
   array['overview','bookings','products','services','offers','gallery','employees','reports','purchases'],
   true, 'kawa')
on conflict (login_slug) do update set
  id=excluded.id, name=excluded.name, brands=excluded.brands, tabs=excluded.tabs, is_owner=excluded.is_owner;
