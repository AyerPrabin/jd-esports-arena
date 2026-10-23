-- ── JD-Optimiers needs a Weekly Pass too + 3-day grace before the app removes itself (2026-10-23, v5.6) ──
-- Owner decision: download AND running the app need an active Optimizer plan AND a Weekly Pass (basic or pro).
-- A pass bought before 27 Oct counts already (passes start 27 Oct 00:00 NPT, same rule as my_weekly_pass()).
-- When access is missing, optimizer_check adds:
--   reason      'no_plan' | 'no_pass' | 'banned'
--   ended_at    when access ended (the plan's last expiry, or the pass's last expiry / 27 Oct for "never had one")
--   grace_ends  greatest(ended_at, 24 Oct 2026 = the v5.6 release) + 3 days. JD-Optimiers v5.6 restores everything and removes itself after this.
--               null = never remove (banned, or no plan was ever bought on this account).
-- status stays 'no_plan' for every "no access" case, so v5.5 and older still block (and then update).
begin;

create or replace function public._optimizer_pass_ok(p_player uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.weekly_pass_tier(p_player, greatest(now(), timestamptz '2026-10-27 00:00:00+05:45')) is not null
$$;
revoke all on function public._optimizer_pass_ok(uuid) from public, anon, authenticated;

create or replace function public.optimizer_check(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d public.optimizer_devices;
  p public.optimizer_plans;
  v_user text;
  v_plan_end timestamptz;
  v_pass_end timestamptz;
  v_end timestamptz;
  v_reason text;
begin
  select * into d from public.optimizer_devices where token_hash = public._optimizer_hash(p_token) and revoked_at is null;
  if not found then return jsonb_build_object('status', 'revoked'); end if;
  update public.optimizer_devices set last_seen = now() where id = d.id;
  select coalesce(username, player_tag) into v_user from public.players where id = d.player_id;
  if exists(select 1 from public.banned_players where player_id = d.player_id) then
    return jsonb_build_object('status', 'no_plan', 'username', v_user, 'reason', 'banned', 'server_time', now());
  end if;
  select * into p from public.optimizer_plans where player_id = d.player_id and expires_at > now();
  if found and public._optimizer_pass_ok(d.player_id) then
    return jsonb_build_object('status', 'ok', 'tier', p.tier, 'expires_at', p.expires_at, 'username', v_user,
                              'server_time', now(), 'fps_cap', p.fps_cap);
  end if;

  select max(expires_at) into v_plan_end from public.optimizer_plans where player_id = d.player_id;
  if p.player_id is null then
    v_reason := 'no_plan';
    v_end := v_plan_end;                                  -- null: never had a plan -> nothing to remove
  else
    v_reason := 'no_pass';
    select greatest(max(expires_at), timestamptz '2026-10-27 00:00:00+05:45') into v_pass_end
      from public.weekly_passes where player_id = d.player_id and expires_at <= now();
    v_end := coalesce(v_pass_end, timestamptz '2026-10-27 00:00:00+05:45');
  end if;
  return jsonb_build_object('status', 'no_plan', 'reason', v_reason, 'username', v_user, 'server_time', now(),
                            'ended_at', v_end,
                            -- never earlier than 3 days after v5.6 went out, so every player sees the warning first
                            'grace_ends', case when v_end is null then null   -- greatest() would skip the null
                                         else greatest(v_end, timestamptz '2026-10-24 00:00:00+00') + interval '3 days' end);
end;
$$;

-- for the download page: may this player download (active plan not needed to download, a pass is)
create or replace function public.optimizer_can_download()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('pass', public._optimizer_pass_ok(auth.uid()),
                            'pass_tier', public.weekly_pass_tier(auth.uid(), greatest(now(), timestamptz '2026-10-27 00:00:00+05:45')))
$$;
revoke all on function public.optimizer_can_download() from public, anon;
grant execute on function public.optimizer_can_download() to authenticated;

commit;
