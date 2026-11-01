-- ── Daily "Verify your squad" reminder (owner, 1 Nov 2026) ──
-- Once a day (12:00 UTC = 5:45 pm Nepal) every player with a ticket for an event that hasn't started and no line-up yet
-- gets one alert (push + Notification History), naming the soonest such event. Never more than one a day; stops by
-- itself once they verify (squad_verify.sql), and squads verified before get their line-up copied in automatically
-- (squad_verify_saved.sql), so they are never asked again. Safe to run again.
begin;

create or replace function public.verify_squad_reminder()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with ev as (   -- events that haven't started yet, from the live schedule
    select x->>'name' slug, (x->>'start')::timestamptz st
    from public.site_content, jsonb_array_elements(content->'tournaments') x
    where key = 'tournaments' and (x->>'start') ~ '^\d{4}-' and (x->>'start')::timestamptz > now()
      and coalesce(lower(x->>'status'), 'upcoming') not in ('cancelled', 'completed')
  ), todo as (
    select distinct on (r.player_id) r.player_id, r.tournament_slug, r.squad_name
    from public.registrations r join ev on ev.slug = r.tournament_slug
    where r.lineup is null and r.status in ('confirmed', 'approved', 'pending', 'waitlisted')
      and not exists(select 1 from public.notifications q where q.player_id = r.player_id
                       and q.title like '🛡️ Verify your squad%' and q.created_at > now() - interval '20 hours')
    order by r.player_id, ev.st
  ), ins as (
    insert into public.notifications (player_id, tournament_slug, title, body)
    select player_id, tournament_slug, '🛡️ Verify your squad for ' || tournament_slug,
      coalesce(nullif(squad_name, ''), 'Your squad') || ': open your ticket and tap "Verify your squad" - add your 4 players'' Free Fire names and UIDs. You only do it once; next time it''s filled in for you.'
    from todo returning 1
  ) select count(*) into n from ins;
  return n;
end $$;
revoke all on function public.verify_squad_reminder() from public, anon, authenticated;

select cron.unschedule('verify-squad-reminder') where exists (select 1 from cron.job where jobname = 'verify-squad-reminder');
select cron.schedule('verify-squad-reminder', '0 12 * * *', $$ select public.verify_squad_reminder(); $$);

commit;
