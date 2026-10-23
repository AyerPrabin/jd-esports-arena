-- Daily check-in streak (2026-10-23). No points: a streak counter + badge only (the owner's choice).
-- Days are Nepal days. daily_checkin() records today once and returns the streak; my_streak() only reads it.
begin;
create table if not exists public.daily_checkins (
  player_id uuid not null references public.players(id) on delete cascade,
  day date not null,
  at timestamptz not null default now(),
  primary key (player_id, day)
);
alter table public.daily_checkins enable row level security;   -- only through the functions below

create or replace function public._streak_of(p uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with d as (select day from public.daily_checkins where player_id = p),
  today as (select (now() at time zone 'Asia/Kathmandu')::date t),
  g as (select day, day - (row_number() over (order by day))::int grp from d),
  runs as (select min(day) s, max(day) e, count(*) n from g group by grp)
  select jsonb_build_object(
    'checked_today', exists(select 1 from d, today where d.day = today.t),
    'streak', coalesce((select n from runs, today where runs.e >= today.t - 1 order by e desc limit 1), 0),
    'best', coalesce((select max(n) from runs), 0),
    'total', (select count(*) from d));
$$;
revoke all on function public._streak_of(uuid) from public, anon, authenticated;

create or replace function public.daily_checkin() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  insert into public.daily_checkins(player_id, day) values (auth.uid(), (now() at time zone 'Asia/Kathmandu')::date)
  on conflict do nothing;
  return public._streak_of(auth.uid());
end $$;
create or replace function public.my_streak() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then null else public._streak_of(auth.uid()) end;
$$;
revoke all on function public.daily_checkin() from public, anon;
revoke all on function public.my_streak() from public, anon;
grant execute on function public.daily_checkin() to authenticated;
grant execute on function public.my_streak() to authenticated;
commit;
