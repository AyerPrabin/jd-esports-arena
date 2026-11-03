-- 2026-11-03: rosters show each player's CURRENT team name in every event (past ones too), and the
-- reservation check also runs when an entry moves back to an active status (security review finding).
begin;
create or replace function public.get_public_roster()
 returns table(tournament_slug text, squad_name text, squad_logo text, registered_at timestamptz, effect text, pass_tier text)
 language sql stable security definer set search_path to 'public'
as $function$
  select r.tournament_slug, coalesce(p.squad_name, r.squad_name),
    case when exists (select 1 from public.mega_events m where m.slug = r.tournament_slug) then null else coalesce(r.squad_logo, p.squad_logo) end,
    r.slot_key,
    coalesce(r.effect, (select ep.effect from public.effect_passes ep where ep.player_id = r.player_id and ep.starts_at <= now() and ep.expires_at > now() order by ep.expires_at asc limit 1)),
    public.weekly_pass_tier(r.player_id)
  from public.registrations r left join public.players p on p.id = r.player_id
  where r.status in ('confirmed', 'approved')
  order by r.slot_key asc;
$function$;
create or replace function public._reg_unique_squad()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.squad_name is null or new.status in ('rejected', 'no_show') then return new; end if;
  if public._squad_key(new.squad_name) = '' then raise exception 'Enter a squad name with real letters.'; end if;
  if tg_op = 'INSERT' or new.squad_name is distinct from old.squad_name or new.status is distinct from old.status then
    if public._squad_name_reserved(new.squad_name, new.player_id) then
      raise exception '"%" is another team''s name on the JD leaderboard. Ask that team''s captain to register, or pick another name.', trim(new.squad_name);
    end if;
  end if;
  if exists(select 1 from public.registrations r
            where r.tournament_slug = new.tournament_slug and r.id <> new.id and r.player_id <> new.player_id
              and r.status not in ('rejected', 'no_show')
              and public._squad_key(r.squad_name) = public._squad_key(new.squad_name)) then
    raise exception 'A squad called "%" is already in this event. Pick another name, or ask your captain to register the squad.', trim(new.squad_name);
  end if;
  return new;
end $$;

commit;
