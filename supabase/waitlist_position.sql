-- ── "You're #2 in line" for waitlisted squads (2026-10-25) ──
-- my_waitlist_positions(): for each event where the signed-in player is waitlisted, their place in the queue and how
-- many are waiting. Same order as promote_from_waitlist(): Pro pass holders first, then sign-up time.
begin;
create or replace function public.my_waitlist_positions()
returns table(tournament_slug text, pos int, total int, pro boolean)
language sql stable security definer set search_path = public as $$
  with w as (
    select r.tournament_slug, r.player_id,
           row_number() over (partition by r.tournament_slug
             order by (public.weekly_pass_tier(r.player_id) = 'pro') desc nulls last, r.created_at asc)::int as pos,
           count(*) over (partition by r.tournament_slug)::int as total,
           coalesce(public.weekly_pass_tier(r.player_id) = 'pro', false) as pro
    from public.registrations r
    where r.status = 'waitlisted'
      and r.tournament_slug in (select x.tournament_slug from public.registrations x where x.player_id = auth.uid() and x.status = 'waitlisted')
  )
  select tournament_slug, pos, total, pro from w where player_id = auth.uid();
$$;
revoke all on function public.my_waitlist_positions() from public, anon;
grant execute on function public.my_waitlist_positions() to authenticated;
commit;
notify pgrst, 'reload schema';
