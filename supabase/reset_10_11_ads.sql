-- Owner request 2026-10-27: switch the ad gate on and reset JD Free Fire Open #10 and #11, so every squad
-- joins again under the new rule (3 short ads in the app, or a Weekly Pass). One transaction:
-- refund any points paid, tell each removed player how to rejoin (push), drop their room-ID alerts,
-- then remove waitlisted squads first (so no "you're off the waitlist" promotions fire) and then the rest.
begin;

update public.ad_config set enabled = true where id;

create temporary table _reset on commit drop as
  select id, player_id, tournament_slug, squad_name, status, coalesce(paid_points, 0) as paid
  from public.registrations
  where tournament_slug in ('JD Free Fire Open #10', 'JD Free Fire Open #11')
    and status in ('confirmed', 'approved', 'pending', 'waitlisted');

select public._wallet_apply(player_id, paid, 'refund', 'reset_ads:' || id::text,
                            tournament_slug || ' reset for the new ad rule - entry refunded')
  from _reset where paid > 0;

insert into public.notifications (player_id, tournament_slug, title, body, push)
select player_id, tournament_slug,
       '🔄 ' || tournament_slug || ': join again',
       'All squads in ' || tournament_slug || ' were reset for the new free-entry rule'
       || case when paid > 0 then ' (your ' || paid || ' points are back in your wallet)' else '' end
       || '. To get your slot back: update the JD Arena app (jdesport.co.uk/download), tap Join and watch 3 short ads '
       || '- or join straight away with a Weekly Pass. Slots go first come, first served.',
       true
  from _reset;

delete from public.notifications n using _reset r
  where n.player_id = r.player_id and n.tournament_slug = r.tournament_slug and n.room_id is not null;

delete from public.registrations where id in (select id from _reset where status = 'waitlisted');
delete from public.registrations where id in (select id from _reset where status <> 'waitlisted');

select (select count(*) from _reset) as removed, (select count(*) from _reset where paid > 0) as refunded,
       (select enabled from public.ad_config where id) as ads_on;
commit;
