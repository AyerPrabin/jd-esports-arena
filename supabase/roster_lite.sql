-- Roster without pictures (8 Nov 2026). get_public_roster() sent every squad's base64 logo (937 KB) on each
-- home/events open and each roster change, to every open phone - the main cause of the 402 exceed_egress_quota.
-- Now: get_public_roster_lite() sends an md5 key per logo, get_logos(keys) sends only the logos a phone lacks
-- (roster.js keeps them on the device), and the old get_public_roster() no longer sends logos.
-- Only logos the old function already made public are exposed. Undo: supabase/roster_lite_rollback.sql
begin;

create or replace function public.get_public_roster_lite()
returns table(tournament_slug text, squad_name text, logo_key text, registered_at timestamptz, effect text, pass_tier text)
language sql stable security definer set search_path = public as $$
  select r.tournament_slug, r.squad_name,
    case when exists (select 1 from public.mega_events m where m.slug = r.tournament_slug) then null
      else md5(nullif(coalesce(r.squad_logo, p.squad_logo), '')) end,
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

create or replace function public.get_logos(p_keys text[])
returns table(k text, logo text)
language sql stable security definer set search_path = public as $$
  select distinct on (md5(l)) md5(l), l
  from (
    select coalesce(r.squad_logo, p.squad_logo) l
    from public.registrations r left join public.players p on p.id = r.player_id
    where r.status in ('confirmed', 'approved')
      and not exists (select 1 from public.mega_events m where m.slug = r.tournament_slug)
  ) x
  where l <> '' and md5(l) = any (p_keys[1:60]);
$$;

-- old clients and callers: same rows, no pictures
create or replace function public.get_public_roster()
returns table(tournament_slug text, squad_name text, squad_logo text, registered_at timestamptz, effect text, pass_tier text)
language sql stable security definer set search_path = public as $$
  select tournament_slug, squad_name, null::text, registered_at, effect, pass_tier from public.get_public_roster_lite();
$$;

revoke all on function public.get_public_roster_lite() from public;
revoke all on function public.get_logos(text[]) from public;
grant execute on function public.get_public_roster_lite() to anon, authenticated, service_role;
grant execute on function public.get_logos(text[]) to anon, authenticated, service_role;

commit;
