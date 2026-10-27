-- Player's approximate area (2026-10-27, app 2.0.3): only when the player allows location in the Android app.
-- City / district / province / country plus a position rounded to 0.1 degree (~10 km), never the exact spot.
-- Location turned off later = cleared on the next app open. Players read their own row; admins see it in the
-- player list (list-players). Safe to run again.
begin;

alter table public.players add column if not exists area_city text;
alter table public.players add column if not exists area_district text;
alter table public.players add column if not exists area_region text;
alter table public.players add column if not exists area_country text;
alter table public.players add column if not exists area_lat numeric(4,1);
alter table public.players add column if not exists area_lon numeric(4,1);
alter table public.players add column if not exists area_at timestamptz;

create or replace function public.save_my_area(p_city text, p_district text, p_region text, p_country text,
                                               p_lat double precision, p_lon double precision)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  if p_lat is null and p_city is null and p_country is null then   -- location not allowed (any more): forget it
    update public.players set area_city = null, area_district = null, area_region = null, area_country = null,
      area_lat = null, area_lon = null, area_at = null where id = auth.uid() and area_at is not null;
    return;
  end if;
  update public.players set
    area_city = nullif(left(btrim(p_city), 60), ''),
    area_district = nullif(left(btrim(p_district), 60), ''),
    area_region = nullif(left(btrim(p_region), 60), ''),
    area_country = nullif(upper(left(btrim(p_country), 2)), ''),
    area_lat = case when p_lat between -90 and 90 then round(p_lat::numeric, 1) end,
    area_lon = case when p_lon between -180 and 180 then round(p_lon::numeric, 1) end,
    area_at = now()
  where id = auth.uid();
end $$;

revoke all on function public.save_my_area(text, text, text, text, double precision, double precision) from public, anon;
grant execute on function public.save_my_area(text, text, text, text, double precision, double precision) to authenticated;
commit;
