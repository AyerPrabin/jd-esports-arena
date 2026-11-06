-- 2026-11-06 owner's go: Og_Bloody (JD-FMGGW) is a JD staff mod.
begin;
insert into public.moderators (email, note, role)
  select lower(email), 'Og_Bloody', 'staff' from public.players where id = 'ec5ee85a-9fd6-42f8-8e04-7235e9a861d2'
  on conflict (email) do update set role = 'staff', note = excluded.note;
insert into public.notifications (player_id, title, body) values ('ec5ee85a-9fd6-42f8-8e04-7235e9a861d2', '🛡️ You are now a JD mod',
  'Welcome to the team! Open jdesport.co.uk/mod/ with this account. You can see all events, the JD Esports chat and the promo queue.');
commit;
