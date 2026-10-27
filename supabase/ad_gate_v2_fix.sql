-- Fix (2026-10-27, found by a rolled-back end-to-end test): `at time zone` binds tighter than `+`, so the
-- AD_COOLDOWN message crashed (timezone(unknown, interval) does not exist) instead of saying when the next ad
-- may play. The claim was still refused; only the message was broken.
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
  if p_kind = 'hourly' and (public._ad_quiet(auth.uid())
     or (v_last is not null and v_last + make_interval(mins => c.hourly_minutes) > now())) then
    raise exception 'AD_NOT_DUE';
  end if;
  insert into public.ad_views (player_id, kind) values (auth.uid(), p_kind);
  return public.ad_status();
end $$;
