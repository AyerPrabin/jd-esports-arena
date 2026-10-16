-- ── JD-Optimiers plans: Optimizer Pro / Optimizer Max (2026-10-16) ─────────────────────────────
-- The Windows app (JD-Optimiers.exe) only opens with an active plan. Plans are bought with JD points
-- (1 point = Rs 1): Optimizer Pro 100 points / 30 days, Optimizer Max 170 points / 30 days (Max adds the
-- Panel scan). Buying the same plan again adds 30 days; Pro -> Max converts the Pro days left into Max days
-- (days x 100/170) and adds 30.
-- A PC is linked to an account without the app ever seeing a password (works for Google sign-in too):
--   app: optimizer_link_start(device)  -> code "ABCD-2345" + a poll secret   (anon)
--   player opens jdesport.co.uk/optimizer/link/?c=ABCD-2345, signed in, checks the code matches the app,
--          optimizer_link_approve(code) -> a device token is minted          (authenticated)
--   app: optimizer_link_poll(code, poll) -> the token, exactly once           (anon)
--   app at every start: optimizer_check(token) -> {status: ok|no_plan|revoked, tier, expires_at, username}
-- Only token hashes are stored. 2 PCs per account: linking a third removes the oldest.
-- Admin (grant / revoke / devices) goes through the optimizer-admin Edge Function (service role).
-- Additive. Idempotent. Applied on its own with: supabase db query --linked -f supabase/optimizer.sql
begin;

alter table public.wallet_ledger drop constraint if exists wallet_ledger_reason_check;
alter table public.wallet_ledger add constraint wallet_ledger_reason_check
  check (reason in ('load','entry','effect','withdraw','withdraw_returned','refund','adjust','prize',
                    'challenge_stake','challenge_win','challenge_refund','optimizer'));

create table if not exists public.optimizer_plans (
  player_id uuid primary key references public.players(id) on delete cascade,
  tier text not null check (tier in ('pro','max')),
  expires_at timestamptz not null,
  updated_at timestamptz not null default now(),
  note text
);
alter table public.optimizer_plans enable row level security;
drop policy if exists "players read own optimizer plan" on public.optimizer_plans;
create policy "players read own optimizer plan" on public.optimizer_plans for select using (auth.uid() = player_id);

create table if not exists public.optimizer_devices (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  token_hash text not null unique,
  device_name text not null default 'PC',
  created_at timestamptz not null default now(),
  last_seen timestamptz,
  revoked_at timestamptz
);
create index if not exists optimizer_devices_player on public.optimizer_devices(player_id, created_at);
alter table public.optimizer_devices enable row level security;
-- no policies on purpose: players see their PCs through optimizer_my_status()

create table if not exists public.optimizer_links (
  code text primary key,
  poll_hash text not null,
  device_name text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  approved_by uuid references public.players(id) on delete cascade,
  approved_at timestamptz,
  device_token text            -- handed to the app once by optimizer_link_poll, then cleared
);
alter table public.optimizer_links enable row level security;
-- no policies on purpose

create or replace function public._optimizer_hash(p text)
returns text language sql immutable set search_path = public as $$
  select encode(sha256(convert_to(coalesce(p, ''), 'UTF8')), 'hex');
$$;

create or replace function public._optimizer_random_hex()
returns text language sql volatile set search_path = public as $$
  select encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex');
$$;

create or replace function public._optimizer_price(p_tier text)
returns int language sql immutable set search_path = public as $$
  select case p_tier when 'pro' then 100 when 'max' then 170 end;
$$;

-- Adds p_days of p_tier (see the header for the Pro -> Max rule). Internal: buy + admin grant.
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
      v_exp := now() + (v_cur.expires_at - now()) * (100.0 / 170.0)::float8 + make_interval(days => p_days);
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

-- Player buys 30 days with points.
create or replace function public.optimizer_buy(p_tier text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_price int := public._optimizer_price(p_tier);
  v_plan public.optimizer_plans;
  v_bal int;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if v_price is null then raise exception 'Unknown plan.'; end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then raise exception 'Your account is banned.'; end if;
  v_plan := public._optimizer_grant(auth.uid(), p_tier, 30, 'points');
  v_bal := public._wallet_apply(auth.uid(), -v_price, 'optimizer', 'opt:' || p_tier || ':' || gen_random_uuid()::text,
                                'Optimizer ' || initcap(p_tier) || ' - 30 days');
  return jsonb_build_object('tier', v_plan.tier, 'expires_at', v_plan.expires_at, 'paid', v_price, 'balance', v_bal);
end;
$$;

-- Plan, linked PCs and prices for the signed-in player (download page).
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
    'prices', jsonb_build_object('pro', 100, 'max', 170),
    'devices', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.device_name,
                                 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.created_at)
                         from public.optimizer_devices d where d.player_id = auth.uid() and d.revoked_at is null), '[]'::jsonb));
end;
$$;

create or replace function public.optimizer_revoke_device(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  update public.optimizer_devices set revoked_at = now() where id = p_id and player_id = auth.uid() and revoked_at is null;
end;
$$;

-- App: start linking this PC.
create or replace function public.optimizer_link_start(p_device text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_raw bytea;
  v_code text;
  v_poll text := public._optimizer_random_hex();
  i int;
begin
  delete from public.optimizer_links where expires_at < now() - interval '1 day';
  if (select count(*) from public.optimizer_links where created_at > now() - interval '1 minute') >= 60 then
    raise exception 'Too many sign-in requests right now - try again in a minute.';
  end if;
  loop
    v_raw := sha256(convert_to(gen_random_uuid()::text, 'UTF8'));
    v_code := '';
    for i in 0..7 loop
      v_code := v_code || substr(v_chars, (get_byte(v_raw, i) % 32) + 1, 1);
      if i = 3 then v_code := v_code || '-'; end if;
    end loop;
    exit when not exists(select 1 from public.optimizer_links where code = v_code);
  end loop;
  insert into public.optimizer_links (code, poll_hash, device_name, expires_at)
  values (v_code, public._optimizer_hash(v_poll),
          left(coalesce(nullif(regexp_replace(coalesce(p_device, ''), '[^A-Za-z0-9 ._()-]', '', 'g'), ''), 'PC'), 60),
          now() + interval '10 minutes');
  return jsonb_build_object('code', v_code, 'poll', v_poll, 'expires_in', 600);
end;
$$;

-- Approve page: what is being linked (shown next to the code so the player can compare).
create or replace function public.optimizer_link_info(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v public.optimizer_links;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  select * into v from public.optimizer_links where code = upper(trim(p_code));
  if not found or v.expires_at < now() then return jsonb_build_object('status', 'expired'); end if;
  if v.approved_by is not null then return jsonb_build_object('status', 'used'); end if;
  return jsonb_build_object('status', 'pending', 'device', v.device_name, 'expires_at', v.expires_at);
end;
$$;

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
  insert into public.optimizer_devices (player_id, token_hash, device_name) values (auth.uid(), public._optimizer_hash(v_token), v.device_name);
  -- 2 PCs per account: unlink the oldest beyond that
  update public.optimizer_devices set revoked_at = now()
   where id in (select id from public.optimizer_devices where player_id = auth.uid() and revoked_at is null
                order by created_at desc offset 2);
  update public.optimizer_links set approved_by = auth.uid(), approved_at = now(), device_token = v_token where code = v.code;
  return jsonb_build_object('status', 'approved', 'device', v.device_name);
end;
$$;

-- App: waits for the approval; returns the device token exactly once.
create or replace function public.optimizer_link_poll(p_code text, p_poll text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.optimizer_links;
begin
  select * into v from public.optimizer_links where code = upper(trim(p_code)) for update;
  if not found or v.poll_hash <> public._optimizer_hash(p_poll) then return jsonb_build_object('status', 'unknown'); end if;
  if v.device_token is not null then
    update public.optimizer_links set device_token = null where code = v.code;
    return jsonb_build_object('status', 'approved', 'token', v.device_token);
  end if;
  if v.approved_by is not null then return jsonb_build_object('status', 'used'); end if;
  if v.expires_at < now() then return jsonb_build_object('status', 'expired'); end if;
  return jsonb_build_object('status', 'pending');
end;
$$;

-- App at every start. Always answers (never raises) so the app can tell "no" from "offline".
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
                            'server_time', now());
end;
$$;

-- App: "Sign out" (tray menu) unlinks this PC.
create or replace function public.optimizer_unlink(p_token text)
returns void language sql security definer set search_path = public as $$
  update public.optimizer_devices set revoked_at = now() where token_hash = public._optimizer_hash(p_token) and revoked_at is null;
$$;

-- Who may call what. Internal helpers: nobody but the service role.
revoke all on function public._optimizer_hash(text) from public, anon, authenticated;
revoke all on function public._optimizer_random_hex() from public, anon, authenticated;
revoke all on function public._optimizer_price(text) from public, anon, authenticated;
revoke all on function public._optimizer_grant(uuid, text, int, text) from public, anon, authenticated;
revoke all on function public.optimizer_buy(text) from public, anon;
revoke all on function public.optimizer_my_status() from public, anon;
revoke all on function public.optimizer_revoke_device(uuid) from public, anon;
revoke all on function public.optimizer_link_info(text) from public, anon;
revoke all on function public.optimizer_link_approve(text) from public, anon;
grant execute on function public.optimizer_buy(text) to authenticated;
grant execute on function public.optimizer_my_status() to authenticated;
grant execute on function public.optimizer_revoke_device(uuid) to authenticated;
grant execute on function public.optimizer_link_info(text) to authenticated;
grant execute on function public.optimizer_link_approve(text) to authenticated;
revoke all on function public.optimizer_link_start(text) from public;
revoke all on function public.optimizer_link_poll(text, text) from public;
revoke all on function public.optimizer_check(text) from public;
revoke all on function public.optimizer_unlink(text) from public;
grant execute on function public.optimizer_link_start(text) to anon, authenticated;
grant execute on function public.optimizer_link_poll(text, text) to anon, authenticated;
grant execute on function public.optimizer_check(text) to anon, authenticated;
grant execute on function public.optimizer_unlink(text) to anon, authenticated;
grant execute on function public._optimizer_grant(uuid, text, int, text) to service_role;

commit;
