-- 2026-11-03, owner's rule: "same team name can be there, different account holder is no problem".
--  * A name already on the leaderboard is no longer reserved for the account that earned it: any account can
--    register or rename to it. (Turns off the check from squad_names_reserved.sql / squad_names_v3.sql.)
--  * Still one name per event: results are saved per event by team name (unique), so two accounts can't
--    enter the SAME event under the same name.
--  * Season standings stay grouped per account; each row now carries the account's @username so two teams
--    with the same name can be told apart on the board.
-- Safe to run again.
begin;

create or replace function public._squad_name_reserved(p_name text, p_me uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select false
$$;
revoke all on function public._squad_name_reserved(text, uuid) from public, anon, authenticated;

drop function if exists public.get_season_standings();
create function public.get_season_standings()
returns table(squad_name text, events int, points bigint, kills bigint, wins int, best_place int, prize numeric, owner text)
language sql stable security definer set search_path = public as $$
  with res as (
    select tr.*, public._result_owner(tr.tournament_slug, tr.squad_name) as pid from public.tournament_results tr
  )
  select coalesce(max(p.squad_name), max(res.squad_name)) as squad_name,
         count(distinct res.tournament_slug)::int as events,
         sum(res.points)::bigint as points,
         sum(res.kills)::bigint as kills,
         sum(case when res.placement = 1 then 1 else 0 end)::int as wins,
         min(res.placement)::int as best_place,
         sum(res.prize_won) as prize,
         max(p.username) as owner
  from res left join public.players p on p.id = res.pid
  group by coalesce(res.pid::text, lower(trim(res.squad_name)))
  order by sum(res.points) desc, sum(res.kills) desc, 1 asc;
$$;
revoke all on function public.get_season_standings() from public;
grant execute on function public.get_season_standings() to anon, authenticated;

commit;
