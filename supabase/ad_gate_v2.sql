-- Ad gate v2 (owner rule 2026-10-27): the 3 ads to join a free tournament play back to back (only a short
-- gap so a claim can't be faked faster than an ad plays). After that the app shows at most 1 ad per hour
-- (kind 'hourly'), and never around match time: no hourly ad from 30 minutes before one of the player's
-- events starts until 90 minutes after (Room ID / password time). Every finished ad is 1 credit toward the
-- next free entry. Still off until ad_config.enabled = true.

alter table public.ad_config add column if not exists gap_seconds int not null default 15 check (gap_seconds >= 0);
alter table public.ad_config add column if not exists hourly_minutes int not null default 60 check (hourly_minutes >= 1);
update public.ad_config set cooldown_minutes = 0 where id;   -- unused since v2 (gap_seconds / hourly_minutes)
alter table public.ad_views add column if not exists kind text not null default 'gate' check (kind in ('gate', 'hourly'));

-- one of the player's events is about to start or running: Room ID / password time, no hourly ads
create or replace function public._ad_quiet(p_player uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.registrations r
    where r.player_id = p_player and r.status in ('confirmed', 'approved')
      and public.tournament_start_at(r.tournament_slug) between now() - interval '90 minutes' and now() + interval '30 minutes');
$$;
revoke all on function public._ad_quiet(uuid) from public, anon, authenticated;

create or replace function public.ad_status()
returns json language plpgsql stable security definer set search_path = public as $$
declare c public.ad_config; v_have int; v_last timestamptz;
begin
  select * into c from public.ad_config where id;
  if auth.uid() is null or not c.enabled or c.ad_unit is null then   -- no ad unit = gate off
    return json_build_object('enabled', false);
  end if;
  select count(*) filter (where used_for is null), max(viewed_at) into v_have, v_last
    from public.ad_views where player_id = auth.uid();
  return json_build_object('enabled', true, 'unit', c.ad_unit, 'needed', c.ads_needed, 'have', v_have,
    'exempt', public._ad_exempt(auth.uid()),
    'next_at', case when v_last is not null and v_last + make_interval(secs => c.gap_seconds) > now()
                    then v_last + make_interval(secs => c.gap_seconds) end,
    'hourly_due', v_last is null or v_last + make_interval(mins => c.hourly_minutes) <= now(),
    'quiet', public._ad_quiet(auth.uid()));
end $$;
grant execute on function public.ad_status() to authenticated;

drop function if exists public.ad_reward_claim();
create or replace function public.ad_reward_claim(p_kind text default 'gate')
returns json language plpgsql security definer set search_path = public as $$
declare c public.ad_config; v_last timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_kind not in ('gate', 'hourly') then raise exception 'Bad ad kind'; end if;
  select * into c from public.ad_config where id;
  if not c.enabled or c.ad_unit is null then raise exception 'Ads are switched off.'; end if;
  perform pg_advisory_xact_lock(hashtext('ad:' || auth.uid()::text));
  select max(viewed_at) into v_last from public.ad_views where player_id = auth.uid();
  if v_last is not null and v_last + make_interval(secs => c.gap_seconds) > now() then
    raise exception 'AD_COOLDOWN: next ad at %', to_char(v_last + make_interval(secs => c.gap_seconds) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;
  if p_kind = 'hourly' and (public._ad_quiet(auth.uid())
     or (v_last is not null and v_last + make_interval(mins => c.hourly_minutes) > now())) then
    raise exception 'AD_NOT_DUE';
  end if;
  insert into public.ad_views (player_id, kind) values (auth.uid(), p_kind);
  return public.ad_status();
end $$;
grant execute on function public.ad_reward_claim(text) to authenticated;
