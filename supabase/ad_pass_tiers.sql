-- Ads by Weekly Pass tier from 1 Nov 2026 00:00 NPT (owner, 27 Oct): Weekly Pro (and Optimizer Max) = no ads at
-- all; Basic Weekly Pass = still no ads to join free events, but the app's short "hourly" ad at most 2 a day;
-- no pass = unchanged (3 ads to join a free event + up to 1 ad per hour). Before 1 Nov every pass is ad-free.
-- ad_status() gains hourly_ok (ads.js shows the hourly ad only when it is true). Safe to run again.
begin;

create or replace function public._ad_hourly_ok(p_player uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_tier text := public.weekly_pass_tier(p_player, now());
begin
  if v_tier = 'pro' or public._optimizer_is_max(p_player) then return false; end if;
  if v_tier = 'basic' then
    if now() < timestamptz '2026-11-01 00:00:00+05:45' then return false; end if;
    return (select count(*) from public.ad_views where player_id = p_player and kind = 'hourly'
            and viewed_at >= date_trunc('day', now() at time zone 'Asia/Kathmandu') at time zone 'Asia/Kathmandu') < 2;
  end if;
  return true;
end $$;
revoke all on function public._ad_hourly_ok(uuid) from public, anon, authenticated;

create or replace function public.ad_status()
returns json language plpgsql stable security definer set search_path = public as $$
declare c public.ad_config; v_have int; v_last timestamptz; v_due boolean; v_quiet boolean;
begin
  select * into c from public.ad_config where id;
  if auth.uid() is null or not c.enabled or c.ad_unit is null then   -- no ad unit = gate off
    return json_build_object('enabled', false);
  end if;
  select count(*) filter (where used_for is null), max(viewed_at) into v_have, v_last
    from public.ad_views where player_id = auth.uid();
  v_due := v_last is null or v_last + make_interval(mins => c.hourly_minutes) <= now();
  v_quiet := public._ad_quiet(auth.uid());
  return json_build_object('enabled', true, 'unit', c.ad_unit, 'needed', c.ads_needed, 'have', v_have,
    'exempt', public._ad_exempt(auth.uid()),
    'next_at', case when v_last is not null and v_last + make_interval(secs => c.gap_seconds) > now()
                    then v_last + make_interval(secs => c.gap_seconds) end,
    'hourly_due', v_due,
    'hourly_ok', v_due and not v_quiet and public._ad_hourly_ok(auth.uid()),
    'tier', public.weekly_pass_tier(auth.uid(), now()),
    'quiet', v_quiet);
end $$;

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
    raise exception 'AD_COOLDOWN: next ad at %', to_char((v_last + make_interval(secs => c.gap_seconds)) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;
  if p_kind = 'hourly' and (public._ad_quiet(auth.uid()) or not public._ad_hourly_ok(auth.uid())
     or (v_last is not null and v_last + make_interval(mins => c.hourly_minutes) > now())) then
    raise exception 'AD_NOT_DUE';
  end if;
  insert into public.ad_views (player_id, kind) values (auth.uid(), p_kind);
  return public.ad_status();
end $$;

grant execute on function public.ad_status() to authenticated;
grant execute on function public.ad_reward_claim(text) to authenticated;
commit;
