-- One-off (2026-10-20): squads that registered for JD Free Fire Open #6 and didn't show up
-- lose their place in every upcoming tournament. They can register again; the join form
-- then shows them a final warning (my_no_show_count()). Any entry points paid are refunded.
-- Run: supabase db query --linked -f supabase/remove_no_shows_open6.sql
begin;
create temp table rm on commit drop as
  select r.id, r.player_id, r.squad_name, r.tournament_slug, coalesce(r.paid_points,0) paid_points
  from public.registrations r
  -- match the squad, not just the account: a teammate may have registered the same squad
  join (select distinct squad_name from public.jd_no_show_log
        where tournament_slug = 'JD Free Fire Open #6' and reason = 'did_not_show') l
       on lower(trim(l.squad_name)) = lower(trim(r.squad_name))
  join public.site_content sc on sc.key = 'tournaments'
  join jsonb_array_elements(sc.content->'tournaments') t on t->>'name' = r.tournament_slug
  where r.tournament_slug <> 'JD Free Fire Open #6'
    and lower(coalesce(t->>'status','upcoming')) not in ('completed','cancelled')
    and (t->>'start')::timestamptz > now();
select public._wallet_apply(player_id, paid_points, 'refund', 'noshow_refund:'||id::text,
       'Refund: removed from '||tournament_slug||' after no-show in JD Free Fire Open #6')
  from rm where paid_points > 0;
insert into public.jd_no_show_log(tournament_slug, player_id, squad_name, reason)
  select tournament_slug, player_id, squad_name, 'removed_after_no_show' from rm;
insert into public.notifications(player_id, tournament_slug, title, body, push)
  select player_id, tournament_slug, '❌ Removed from ' || tournament_slug,
    'Because your squad (' || squad_name || ') registered for JD Free Fire Open #6 and did not show up, your place in ' ||
    tournament_slug || ' has been removed. You can register again if slots are open, but this is your final warning: ' ||
    'another no-show will get your squad banned from JD tournaments.', true
  from rm;
delete from public.registrations where id in (select id from rm);
select tournament_slug, squad_name from rm order by 1;
commit;
