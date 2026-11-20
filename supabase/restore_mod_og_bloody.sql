-- 2026-11-20 owner's go: give Og_Bloody (Mahesh) his mod back. His mod row was missing (removed outside git).
-- Admin access is separate and still on (admin-google-login allows his verified Google email). Safe to re-run.
begin;
insert into public.moderators (email, note, role)
  select lower(email), 'Og_Bloody', 'staff' from public.players where id = 'ec5ee85a-9fd6-42f8-8e04-7235e9a861d2'
  on conflict (email) do update set role = 'staff', note = excluded.note;
insert into public.notifications (player_id, title, body)
  select 'ec5ee85a-9fd6-42f8-8e04-7235e9a861d2', '🛡️ Your JD mod + admin access is back',
  'Welcome back! Mod: jdesport.co.uk/mod/ . Admin: jdesport.co.uk/admin/ (sign in with Google).'
  where not exists (select 1 from public.notifications n where n.player_id = 'ec5ee85a-9fd6-42f8-8e04-7235e9a861d2'
                    and n.title = '🛡️ Your JD mod + admin access is back');
select m.note, m.role from public.moderators m join public.players p on lower(p.email) = m.email
where p.id = 'ec5ee85a-9fd6-42f8-8e04-7235e9a861d2';
commit;
