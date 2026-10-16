-- ── JD-Optimiers plans v2 (2026-10-17) ────────────────────────────────────────────────────────
-- * New prices: Optimizer Pro 49 points, Optimizer Max 99 points (30 days each). Pro -> Max upgrade
--   converts the Pro days left at 49/99.
-- * Optimizer Max perks, while the plan is active:
--     - a 30-day Pro squad effect with every Max purchase (player picks the effect; stacks after any
--       pass they already have, through the same _apply_effect_plan as the effect shop)
--     - early entry: joins "early_access" tournaments 24 h before reg_opens, like app users
--     - verified tag: _display_name shows " ✔" (lobby / room names)
-- * Sharing guard: at most 4 PC links per account per 30 days (the 2-PC cap alone could be rotated).
-- Additive. Idempotent. Applied on its own with: supabase db query --linked -f supabase/optimizer_v2.sql
begin;

create or replace function public._optimizer_price(p_tier text)
returns int language sql immutable set search_path = public as $$
  select case p_tier when 'pro' then 49 when 'max' then 99 end;
$$;
revoke all on function public._optimizer_price(text) from public, anon, authenticated;

create or replace function public._optimizer_is_max(p_player uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.optimizer_plans where player_id = p_player and tier = 'max' and expires_at > now());
$$;
revoke all on function public._optimizer_is_max(uuid) from public, anon, authenticated;

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
  insert into public.optimizer_plans (player_id, tier, expires_at, updated_at, note)
  values (p_player, p_tier, v_exp, now(), p_note)
  on conflict (player_id) do update set tier = excluded.tier, expires_at = excluded.expires_at,
                                        updated_at = now(), note = excluded.note
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function public._optimizer_grant(uuid, text, int, text) from public, anon, authenticated;
grant execute on function public._optimizer_grant(uuid, text, int, text) to service_role;

-- Max perk: one 30-day Pro squad effect. Internal (buy + admin grant).
create or replace function public._optimizer_max_effect(p_player uuid, p_effect text, p_ref text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if p_effect is null or not public.fx_tier_ok('pro', p_effect) then p_effect := 'gold'; end if;
  return public._apply_effect_plan(p_player, 'fx_month', p_effect, null, p_ref);
end;
$$;
revoke all on function public._optimizer_max_effect(uuid, text, text) from public, anon, authenticated;
grant execute on function public._optimizer_max_effect(uuid, text, text) to service_role;

drop function if exists public.optimizer_buy(text);
create or replace function public.optimizer_buy(p_tier text, p_effect text default 'gold')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_price int := public._optimizer_price(p_tier);
  v_plan public.optimizer_plans;
  v_bal int;
  v_ref text := 'opt:' || p_tier || ':' || gen_random_uuid()::text;
  v_fx jsonb;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if v_price is null then raise exception 'Unknown plan.'; end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then raise exception 'Your account is banned.'; end if;
  v_plan := public._optimizer_grant(auth.uid(), p_tier, 30, 'points');
  v_bal := public._wallet_apply(auth.uid(), -v_price, 'optimizer', v_ref, 'Optimizer ' || initcap(p_tier) || ' - 30 days');
  if p_tier = 'max' then v_fx := public._optimizer_max_effect(auth.uid(), p_effect, v_ref); end if;
  return jsonb_build_object('tier', v_plan.tier, 'expires_at', v_plan.expires_at, 'paid', v_price, 'balance', v_bal,
                            'effect', v_fx->>'effect', 'effect_expires_at', v_fx->>'expires_at');
end;
$$;
revoke all on function public.optimizer_buy(text, text) from public, anon;
grant execute on function public.optimizer_buy(text, text) to authenticated;

create or replace function public.optimizer_my_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_plan public.optimizer_plans;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  select * into v_plan from public.optimizer_plans where player_id = auth.uid();
  return jsonb_build_object(
    'tier', case when v_plan.expires_at > now() then v_plan.tier end,
    'expires_at', case when v_plan.expires_at > now() then v_plan.expires_at end,
    'last_tier', v_plan.tier, 'last_expires_at', v_plan.expires_at,
    'prices', jsonb_build_object('pro', 49, 'max', 99),
    'links_left', greatest(0, 4 - (select count(*) from public.optimizer_devices
                                    where player_id = auth.uid() and created_at > now() - interval '30 days')),
    'devices', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.device_name,
                                 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.created_at)
                         from public.optimizer_devices d where d.player_id = auth.uid() and d.revoked_at is null), '[]'::jsonb));
end;
$$;
revoke all on function public.optimizer_my_status() from public, anon;
grant execute on function public.optimizer_my_status() to authenticated;

-- Sharing guard: 4 links / 30 days.
create or replace function public.optimizer_link_approve(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v public.optimizer_links;
  v_token text := public._optimizer_random_hex();
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then raise exception 'Your account is banned.'; end if;
  select * into v from public.optimizer_links where code = upper(trim(p_code)) for update;
  if not found or v.expires_at < now() then raise exception 'This code has expired - press "Sign in" in the app again.'; end if;
  if v.approved_by is not null then raise exception 'This code was already used.'; end if;
  if (select count(*) from public.optimizer_devices where player_id = auth.uid() and created_at > now() - interval '30 days') >= 4 then
    raise exception 'You have linked 4 PCs in the last 30 days - that is the limit. Ask the JD admin if you changed PC.';
  end if;
  insert into public.optimizer_devices (player_id, token_hash, device_name) values (auth.uid(), public._optimizer_hash(v_token), v.device_name);
  update public.optimizer_devices set revoked_at = now()
   where id in (select id from public.optimizer_devices where player_id = auth.uid() and revoked_at is null
                order by created_at desc offset 2);
  update public.optimizer_links set approved_by = auth.uid(), approved_at = now(), device_token = v_token where code = v.code;
  return jsonb_build_object('status', 'approved', 'device', v.device_name);
end;
$$;
revoke all on function public.optimizer_link_approve(text) from public, anon;
grant execute on function public.optimizer_link_approve(text) to authenticated;

-- Verified tag for active Max (lobby / room names); app badge kept.
create or replace function public._display_name(p_player uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce('@' || username, player_tag, 'a player')
         || case when public._optimizer_is_max(id) then ' ✔' else '' end
         || case when app_installed_at is not null then ' 📱' else '' end
  from public.players where id = p_player
$$;

-- Public read of the tag for the site (only true/false, no plan details).
create or replace function public.optimizer_verified(p_players uuid[])
returns table(player_id uuid) language sql stable security definer set search_path = public as $$
  select o.player_id from public.optimizer_plans o
   where o.player_id = any(p_players[1:200]) and o.tier = 'max' and o.expires_at > now();
$$;
revoke all on function public.optimizer_verified(uuid[]) from public;
grant execute on function public.optimizer_verified(uuid[]) to anon, authenticated;

-- Early entry for Max in register_for_tournament(): same window as app users.
do $$
declare d text;
begin
  select pg_get_functiondef('public.register_for_tournament(text,text,text,text,text,text)'::regprocedure) into d;
  if position('_optimizer_is_max' in d) = 0 then
    d := replace(d, E'if (select app_installed_at from public.players where id = auth.uid()) is null then',
                    E'if (select app_installed_at from public.players where id = auth.uid()) is null and not public._optimizer_is_max(auth.uid()) then');
    if position('_optimizer_is_max' in d) = 0 then raise exception 'register_for_tournament early-entry patch did not apply'; end if;
    d := replace(d, E'only JD Arena app users can join before', E'only JD Arena app users and Optimizer Max members can join before');
    execute d;
  end if;
end $$;

commit;
