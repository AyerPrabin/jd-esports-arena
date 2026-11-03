-- One team per player (2026-11-03, owner's rule: "if a player changes their team name, change it everywhere;
-- no double team from the same person").
--  * Season standings and logos group results by the account that registered the team (not by the name),
--    shown under the player's CURRENT squad name and logo. 7 players had played under 2-3 names, which split
--    their points into separate rows. Past results are not rewritten, so this is a view change only.
--  * A rename (profile, or a new name typed when joining) is copied onto that player's entries for every event
--    that has no archived results yet: rosters, tickets and slot lists show the new name. Finished events keep
--    the name the team actually played under.
--  * One event can't hold two teams with the same name from different accounts (teammates taking turns on
--    different accounts in DIFFERENT events stay allowed).
-- Safe to run again.
begin;

-- the account behind an archived result: the registration with that name in that event
create or replace function public._result_owner(p_slug text, p_name text)
returns uuid language sql stable security definer set search_path = public as $$
  select r.player_id from public.registrations r
  where r.tournament_slug = p_slug and lower(trim(r.squad_name)) = lower(trim(p_name))
  order by (r.status in ('confirmed', 'approved')) desc, r.created_at
  limit 1
$$;
revoke all on function public._result_owner(text, text) from public, anon, authenticated;

create or replace function public.get_season_standings()
returns table(squad_name text, events int, points bigint, kills bigint, wins int, best_place int, prize numeric)
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
         sum(res.prize_won) as prize
  from res left join public.players p on p.id = res.pid
  group by coalesce(res.pid::text, lower(trim(res.squad_name)))
  order by sum(res.points) desc, sum(res.kills) desc, 1 asc;
$$;
revoke all on function public.get_season_standings() from public;
grant execute on function public.get_season_standings() to anon, authenticated;

-- logo per CURRENT squad name: the player's saved logo, else the latest logo on one of their entries
create or replace function public.get_season_logos()
returns table(squad_name text, logo text)
language sql stable security definer set search_path to 'public' as $$
  select distinct on (lower(trim(p.squad_name))) p.squad_name,
    coalesce(p.squad_logo, (select nullif(r.squad_logo, '') from public.registrations r
                            where r.player_id = p.id and nullif(r.squad_logo, '') is not null
                            order by r.created_at desc limit 1)) as logo
  from public.players p
  where p.squad_name is not null
    and exists(select 1 from public.registrations r where r.player_id = p.id and r.status in ('confirmed', 'approved'))
    and coalesce(p.squad_logo, (select nullif(r.squad_logo, '') from public.registrations r
                                where r.player_id = p.id and nullif(r.squad_logo, '') is not null limit 1)) is not null
  order by lower(trim(p.squad_name)), p.created_at desc;
$$;
grant execute on function public.get_season_logos() to anon, authenticated;

-- no two teams with one name in the same event
create or replace function public._reg_unique_squad()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.squad_name is not null and new.status not in ('rejected', 'no_show') and exists(
       select 1 from public.registrations r
       where r.tournament_slug = new.tournament_slug and r.id <> new.id and r.player_id <> new.player_id
         and r.status not in ('rejected', 'no_show')
         and lower(trim(r.squad_name)) = lower(trim(new.squad_name))) then
    raise exception 'A squad called "%" is already in this event. Pick another name, or ask your captain to register the squad.', trim(new.squad_name);
  end if;
  return new;
end $$;
drop trigger if exists registrations_unique_squad on public.registrations;
create trigger registrations_unique_squad before insert or update of squad_name, status on public.registrations
  for each row execute function public._reg_unique_squad();

-- a rename follows the player into every event that isn't finished yet
create or replace function public._squad_rename()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.squad_name is not null and new.squad_name is distinct from old.squad_name then
    update public.registrations r set squad_name = new.squad_name
     where r.player_id = new.id and r.squad_name is distinct from new.squad_name
       and r.status not in ('rejected', 'no_show')
       and not exists(select 1 from public.tournament_results tr where tr.tournament_slug = r.tournament_slug);
  end if;
  return new;
end $$;
drop trigger if exists players_squad_rename on public.players;
create trigger players_squad_rename after update of squad_name on public.players
  for each row execute function public._squad_rename();

commit;
