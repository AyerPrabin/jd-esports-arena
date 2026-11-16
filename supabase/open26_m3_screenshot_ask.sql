-- 2026-11-15 owner's ask: the host's app crashed in JD Free Fire Open #26, so match 3 (M3) final positions are missing.
-- Ask every confirmed squad to send their M3 result screenshot to Manjoy on WhatsApp. Safe to re-run (skips if sent).
begin;
insert into public.notifications (player_id, tournament_slug, title, body, push)
select r.player_id, 'JD Free Fire Open #26', '📸 Send your Match 3 screenshot',
  'The host''s app crashed in JD Free Fire Open #26, so we don''t have the Match 3 positions. Please send a screenshot of your squad''s Match 3 result (position and kills) to Manjoy on WhatsApp: +977 9805648981. Results go up once we have them.' || chr(10) ||
  'Host ko app crash bhayo, Match 3 ko position chhaina. Tapaiko squad ko Match 3 result ko screenshot Manjoy lai WhatsApp ma pathaunus: +977 9805648981.', true
from public.registrations r
where r.tournament_slug = 'JD Free Fire Open #26' and r.status = 'confirmed'
  and not exists (select 1 from public.notifications n where n.player_id = r.player_id
                  and n.tournament_slug = 'JD Free Fire Open #26' and n.title = '📸 Send your Match 3 screenshot');
select count(*) as sent from public.notifications
 where tournament_slug = 'JD Free Fire Open #26' and title = '📸 Send your Match 3 screenshot';
commit;
