-- 2026-11-19 owner's go: ask every Open #29 squad (except owner's JD ESPORTS) for the Match 1 screenshot
-- on WhatsApp +977 980-5648981, or their M1 points become 0. JD chat + push. Safe to re-run.
begin;
insert into public.jd_messages (player_id, from_staff, staff_email, channel, body, push)
select distinct r.player_id, true, 'zulu', 'jd',
'📸 JD Free Fire Open #29: we are missing your MATCH 1 (M1) result screenshot. Please send it on WhatsApp to +977 980-5648981 as soon as possible. If we do not get it, your Match 1 points will be 0.
Namaste! Open #29 ko Match 1 (M1) ko result screenshot WhatsApp +977 980-5648981 ma pathaunu hola. Napathaye M1 ko point 0 hunchha.', true
from public.registrations r
where r.tournament_slug = 'JD Free Fire Open #29'
  and r.status in ('approved','confirmed')
  and r.player_id <> '1b1dd73e-0328-4bb4-a22b-87542d36da0d'
  and not exists (select 1 from public.jd_messages m
                  where m.player_id = r.player_id and m.channel = 'jd'
                    and m.body like '📸 JD Free Fire Open #29: we are missing your MATCH 1%');
select count(*) sent from public.jd_messages where channel = 'jd' and body like '📸 JD Free Fire Open #29: we are missing your MATCH 1%';
commit;
