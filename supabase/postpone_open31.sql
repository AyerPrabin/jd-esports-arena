-- 2026-11-20 owner: Open #31 postponed (host power/wifi down) from Fri 20 Nov 8:00 PM to Sat 21 Nov 5:30 PM NPT.
-- Same squads keep their slots. Moves the event in site_content and tells every registered player (JD chat + push).
-- Safe to re-run.
begin;
update public.site_content sc
set content = jsonb_set(
      jsonb_set(sc.content, '{tournaments}',
        (select jsonb_agg(case when e->>'name' = 'JD Free Fire Open #31'
                   then e || '{"date":"Sat, Nov 21","time":"5:30 PM NPT","start":"2026-11-21T17:30:00+05:45","status":"upcoming"}'::jsonb
                   else e end order by i)
         from jsonb_array_elements(sc.content->'tournaments') with ordinality t(e, i))),
      '{_published_at}', to_jsonb(to_char(now() at time zone 'utc','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')))
where sc.key = 'tournaments'
  and jsonb_array_length(sc.content->'tournaments') > 0;

insert into public.jd_messages (player_id, from_staff, staff_email, channel, body, push)
select distinct r.player_id, true, 'zulu', 'jd',
'⏰ JD Free Fire Open #31 is POSTPONED to TOMORROW, Sat 21 Nov, 5:30 PM NPT. The host lost power/wifi tonight, sorry! Your squad keeps its slot, no need to register again. Room ID + password come about 5 min before the start.
Namaste! Open #31 aaja hudaina, bholi Sat 21 Nov beluka 5:30 baje (NPT) huncha. Host ko bijuli/wifi gayo, maaf garnuhola. Tapai ko slot same rahancha.', true
from public.registrations r
where r.tournament_slug = 'JD Free Fire Open #31'
  and r.status in ('approved','confirmed')
  and not exists (select 1 from public.jd_messages m
                  where m.player_id = r.player_id and m.channel = 'jd'
                    and m.body like '⏰ JD Free Fire Open #31 is POSTPONED%');

select e->>'name' name, e->>'date' date, e->>'time' time, e->>'start' start, e->>'status' status
from public.site_content sc, jsonb_array_elements(sc.content->'tournaments') e
where sc.key='tournaments' and e->>'name' ~ 'Open #3[1-2]$';
select count(*) told from public.jd_messages where channel = 'jd' and body like '⏰ JD Free Fire Open #31 is POSTPONED%';
select jsonb_array_length(content->'tournaments') events_total from public.site_content where key='tournaments';
commit;
