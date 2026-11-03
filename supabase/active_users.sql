-- 2026-11-03 Active users for the admin page (owner + staff mods only).
-- DAU / WAU / MAU = players seen in the last 24 h / 7 days / 30 days (players.last_seen_at, the in-app heartbeat,
-- updated at most once a minute). player_days keeps one row per player per Nepal day, so the admin also gets a
-- 30-day trend. Counts only, no names. Safe to run again.
begin;
create table if not exists public.player_days (
  day date not null,
  player_id uuid not null references public.players(id) on delete cascade,
  primary key (day, player_id)
);
alter table public.player_days enable row level security;   -- no policies: the RPC below only

create or replace function public._log_player_day()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.last_seen_at is not null then
    insert into public.player_days (day, player_id) values ((new.last_seen_at at time zone 'Asia/Kathmandu')::date, new.id)
    on conflict do nothing;
  end if;
  return new;
end $$;
revoke all on function public._log_player_day() from public, anon, authenticated;
drop trigger if exists players_log_day on public.players;
create trigger players_log_day after update of last_seen_at on public.players
  for each row when (new.last_seen_at is distinct from old.last_seen_at) execute function public._log_player_day();

-- start the history from what last_seen_at already knows
insert into public.player_days (day, player_id)
  select (last_seen_at at time zone 'Asia/Kathmandu')::date, id from public.players where last_seen_at is not null
on conflict do nothing;

create or replace function public.admin_active_users()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._promo_reviewer() then raise exception 'Only the JD admin and staff mods can see this.'; end if;
  return jsonb_build_object(
    'dau', (select count(*) from public.players where last_seen_at > now() - interval '24 hours'),
    'wau', (select count(*) from public.players where last_seen_at > now() - interval '7 days'),
    'mau', (select count(*) from public.players where last_seen_at > now() - interval '30 days'),
    'online', (select count(*) from public.players where last_seen_at > now() - interval '3 minutes'),
    'total', (select count(*) from public.players),
    'app', (select count(*) from public.players where app_installed_at is not null),
    'new_1', (select count(*) from public.players where created_at > now() - interval '24 hours'),
    'new_7', (select count(*) from public.players where created_at > now() - interval '7 days'),
    'new_30', (select count(*) from public.players where created_at > now() - interval '30 days'),
    'days', coalesce((select jsonb_agg(jsonb_build_object('d', d::date, 'n', coalesce(c.n, 0)) order by d)
      from generate_series((now() at time zone 'Asia/Kathmandu')::date - 29, (now() at time zone 'Asia/Kathmandu')::date, interval '1 day') d
      left join (select day, count(*) n from public.player_days group by day) c on c.day = d::date), '[]'::jsonb));
end $$;
revoke all on function public.admin_active_users() from public, anon;
grant execute on function public.admin_active_users() to authenticated;
commit;

-- 2026-11-03 fix: jd_sync was STABLE, so the heartbeat UPDATE in dm_poll (players.last_seen_at) never stuck once the
-- app moved to jd_sync (last_seen stopped on 2026-10-25). VOLATILE lets the heartbeat write again.
alter function public.jd_sync(timestamptz) volatile;
