-- Squad names belong to the team that earned results with them (2026-11-03, follow-up to squad_identity.sql;
-- flagged by the automated security review):
--  * Logo hijack: logos are keyed by name, so another account taking a ranked team's name could show its
--    logo on that team's leaderboard row. Logos now come only from accounts that own season results.
--  * Name squatting: anyone registering first under a ranked team's name could lock the real team out of an
--    event. A name held by an account with season results is now reserved for that account (profile rename
--    and joining an event both check it). Brand-new names are still first come, first served per event.
-- Safe to run again.
begin;

-- accounts that own at least one archived result
create or replace function public._has_season_results(p_player uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.registrations r
                join public.tournament_results tr on tr.tournament_slug = r.tournament_slug
                 and lower(trim(tr.squad_name)) = lower(trim(r.squad_name))
                where r.player_id = p_player)
$$;
revoke all on function public._has_season_results(uuid) from public, anon, authenticated;

-- true when another account with season results currently uses this name
create or replace function public._squad_name_reserved(p_name text, p_me uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.players p
                where p.id <> p_me and lower(trim(p.squad_name)) = lower(trim(p_name))
                  and public._has_season_results(p.id))
$$;
revoke all on function public._squad_name_reserved(text, uuid) from public, anon, authenticated;

create or replace function public.get_season_logos()
returns table(squad_name text, logo text)
language sql stable security definer set search_path to 'public' as $$
  select distinct on (lower(trim(p.squad_name))) p.squad_name,
    coalesce(p.squad_logo, (select nullif(r.squad_logo, '') from public.registrations r
                            where r.player_id = p.id and nullif(r.squad_logo, '') is not null
                            order by r.created_at desc limit 1)) as logo
  from public.players p
  where p.squad_name is not null and public._has_season_results(p.id)
    and coalesce(p.squad_logo, (select nullif(r.squad_logo, '') from public.registrations r
                                where r.player_id = p.id and nullif(r.squad_logo, '') is not null limit 1)) is not null
  order by lower(trim(p.squad_name)), p.created_at asc;
$$;
grant execute on function public.get_season_logos() to anon, authenticated;

create or replace function public._reg_unique_squad()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.squad_name is null or new.status in ('rejected', 'no_show') then return new; end if;
  if tg_op = 'INSERT' or new.squad_name is distinct from old.squad_name then
    if public._squad_name_reserved(new.squad_name, new.player_id) then
      raise exception '"%" is another team''s name on the JD leaderboard. Ask that team''s captain to register, or pick another name.', trim(new.squad_name);
    end if;
  end if;
  if exists(select 1 from public.registrations r
            where r.tournament_slug = new.tournament_slug and r.id <> new.id and r.player_id <> new.player_id
              and r.status not in ('rejected', 'no_show')
              and lower(trim(r.squad_name)) = lower(trim(new.squad_name))) then
    raise exception 'A squad called "%" is already in this event. Pick another name, or ask your captain to register the squad.', trim(new.squad_name);
  end if;
  return new;
end $$;

-- profile rename: same reservation, then the name follows the player into unfinished events
create or replace function public._squad_rename()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.squad_name is not null and new.squad_name is distinct from old.squad_name then
    if public._squad_name_reserved(new.squad_name, new.id) then
      raise exception '"%" is another team''s name on the JD leaderboard. Pick another name.', trim(new.squad_name);
    end if;
    update public.registrations r set squad_name = new.squad_name
     where r.player_id = new.id and r.squad_name is distinct from new.squad_name
       and r.status not in ('rejected', 'no_show')
       and not exists(select 1 from public.tournament_results tr where tr.tournament_slug = r.tournament_slug);
  end if;
  return new;
end $$;

commit;
