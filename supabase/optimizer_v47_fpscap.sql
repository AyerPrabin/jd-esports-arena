-- v4.7 (2026-10-20): Pro FPS cap for new/renewed Pro plans; optimizer_check returns fps_cap.
begin;
alter table public.optimizer_plans add column if not exists fps_cap int check (fps_cap is null or fps_cap between 30 and 1000);
create or replace function public._optimizer_grant(p_player uuid, p_tier text, p_days int, p_note text)
returns public.optimizer_plans language plpgsql security definer set search_path = public as $$
declare
  v_cur public.optimizer_plans;
  v_exp timestamptz;
  v_row public.optimizer_plans;
begin
  if p_tier not in ('pro','max') then raise exception 'Unknown plan.'; end if;
  if p_days is null or p_days < 1 or p_days > 3660 then raise exception 'Days must be 1-3660.'; end if;
  select * into v_cur from public.optimizer_plans where player_id = p_player for update;
  if found and v_cur.expires_at > now() then
    if v_cur.tier = p_tier then
      v_exp := v_cur.expires_at + make_interval(days => p_days);
    elsif v_cur.tier = 'pro' and p_tier = 'max' then
      v_exp := now() + (v_cur.expires_at - now()) * (49.0 / 99.0)::float8 + make_interval(days => p_days);
    else
      raise exception 'You have Optimizer Max until % - renew Max instead.', to_char(v_cur.expires_at, 'DD Mon YYYY');
    end if;
  else
    v_exp := now() + make_interval(days => p_days);
  end if;
  -- v4.7: Pro bought or renewed from now on is capped at 120 FPS in the app; Max is uncapped. Plans bought
  -- before this change keep fps_cap null (no cap) until they are renewed.
  insert into public.optimizer_plans (player_id, tier, expires_at, updated_at, note, fps_cap)
  values (p_player, p_tier, v_exp, now(), p_note, case when p_tier = 'pro' then 120 end)
  on conflict (player_id) do update set tier = excluded.tier, expires_at = excluded.expires_at,
                                        updated_at = now(), note = excluded.note, fps_cap = excluded.fps_cap
  returning * into v_row;
  return v_row;
end;
$$;
create or replace function public.optimizer_check(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d public.optimizer_devices;
  p public.optimizer_plans;
  v_user text;
begin
  select * into d from public.optimizer_devices where token_hash = public._optimizer_hash(p_token) and revoked_at is null;
  if not found then return jsonb_build_object('status', 'revoked'); end if;
  update public.optimizer_devices set last_seen = now() where id = d.id;
  select coalesce(username, player_tag) into v_user from public.players where id = d.player_id;
  if exists(select 1 from public.banned_players where player_id = d.player_id) then
    return jsonb_build_object('status', 'no_plan', 'username', v_user, 'reason', 'banned');
  end if;
  select * into p from public.optimizer_plans where player_id = d.player_id and expires_at > now();
  if not found then return jsonb_build_object('status', 'no_plan', 'username', v_user); end if;
  return jsonb_build_object('status', 'ok', 'tier', p.tier, 'expires_at', p.expires_at, 'username', v_user,
                            'server_time', now(), 'fps_cap', p.fps_cap);
end;
$$;
commit;
