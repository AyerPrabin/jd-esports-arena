-- 2026-11-19 owner's go: short push so the WhatsApp number shows at the start of the notification. Safe to re-run.
begin;
insert into public.jd_messages (player_id, from_staff, staff_email, channel, body, push)
select distinct r.player_id, true, 'zulu', 'jd',
'📲 WhatsApp 9805648981: send Open #29 M1 result screenshot by 10 PM today, or M1 = 0 points.', true
from public.registrations r
where r.tournament_slug = 'JD Free Fire Open #29'
  and r.status in ('approved','confirmed')
  and r.player_id <> '1b1dd73e-0328-4bb4-a22b-87542d36da0d'
  and not exists (select 1 from public.jd_messages m
                  where m.player_id = r.player_id and m.channel = 'jd'
                    and m.body like '📲 WhatsApp 9805648981: send Open #29 M1%');
select count(*) sent from public.jd_messages where channel = 'jd' and body like '📲 WhatsApp 9805648981: send Open #29 M1%';
commit;
