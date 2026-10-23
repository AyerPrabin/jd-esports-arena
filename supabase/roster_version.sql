-- The homepage polls every 5 s. get_public_roster() carries every squad logo (~370 KB), so it now polls this
-- fingerprint (a few bytes) and only re-downloads the roster when something in it changed (2026-10-23).
create or replace function public.public_roster_version() returns text
language sql stable security definer set search_path = public as $$
  select md5(coalesce(string_agg(concat_ws('|', tournament_slug, squad_name, md5(coalesce(squad_logo, '')), registered_at, effect, pass_tier), '#'
                                 order by registered_at, tournament_slug, squad_name), ''))
  from public.get_public_roster();
$$;
grant execute on function public.public_roster_version() to anon, authenticated;
