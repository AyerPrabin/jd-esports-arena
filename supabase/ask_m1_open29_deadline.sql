-- 2026-11-19 owner's go: follow-up to ask_m1_open29.sql with a deadline of today 10 PM NPT. Safe to re-run.
begin;
insert into public.jd_messages (player_id, from_staff, staff_email, channel, body, push)
select distinct r.player_id, true, 'zulu', 'jd',
'⏰ Reminder, JD Free Fire Open #29: send your MATCH 1 (M1) result screenshot on WhatsApp to +977 980-5648981 by 10 PM today (19 Nov, Nepal time). After 10 PM, your Match 1 points will be 0.
Aaja raati 10 baje samma M1 ko screenshot WhatsApp +977 980-5648981 ma pathaunu hola, natra M1 ko point 0 hunchha.', true
from public.registrations r
where r.tournament_slug = 'JD Free Fire Open #29'
  and r.status in ('approved','confirmed')
  and r.player_id <> '1b1dd73e-0328-4bb4-a22b-87542d36da0d'
  and not exists (select 1 from public.jd_messages m
                  where m.player_id = r.player_id and m.channel = 'jd'
                    and m.body like '⏰ Reminder, JD Free Fire Open #29: send your MATCH 1%');
select count(*) sent from public.jd_messages where channel = 'jd' and body like '⏰ Reminder, JD Free Fire Open #29: send your MATCH 1%';
commit;
