-- Undo roster_lite.sql: the old get_public_roster() with logos (from slot_swap.sql). The lite functions are left (harmless).
begin;
create or replace function public.get_public_roster()
returns table(tournament_slug text, squad_name text, squad_logo text, registered_at timestamptz, effect text, pass_tier text)
language sql stable security definer set search_path = public as $$
  select r.tournament_slug, r.squad_name,
    case when exists (select 1 from public.mega_events m where m.slug = r.tournament_slug) then null else coalesce(r.squad_logo, p.squad_logo) end,
    r.slot_key,
    coalesce(r.effect, (
      select ep.effect from public.effect_passes ep
      where ep.player_id = r.player_id and ep.starts_at <= now() and ep.expires_at > now()
      order by ep.expires_at asc limit 1
    )),
    public.weekly_pass_tier(r.player_id)
  from public.registrations r left join public.players p on p.id = r.player_id
  where r.status in ('confirmed', 'approved')
  order by r.slot_key asc;
$$;
commit;
