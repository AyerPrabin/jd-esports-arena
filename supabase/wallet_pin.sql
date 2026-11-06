-- 2026-11-06 owner's rule: loading points and withdrawing need a 6-digit wallet PIN, checked here on the server.
-- The PIN is stored only as a bcrypt hash. A right PIN gives a one-use token for 5 minutes. A wrong PIN must count even
-- though the action stops, so wallet_pin_verify returns the result and never raises for it (a raise would undo the count).
-- A forgotten PIN is reset by the admin only: self-service would let a stolen login replace it.
-- Rollback: wallet_pin_rollback.sql
begin;
create table public.wallet_pins (
  player_id uuid primary key references public.players(id) on delete cascade,
  pin_hash text not null,
  failed int not null default 0,
  locked_until timestamptz,
  token_hash text,
  token_expires timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.wallet_pins enable row level security;
revoke all on public.wallet_pins from public, anon, authenticated;

create function public._wallet_pin_check_new(p_pin text) returns void
language plpgsql immutable set search_path = public as $$
begin
  if coalesce(p_pin, '') !~ '^[0-9]{6}$' then raise exception 'Your PIN must be exactly 6 numbers.'; end if;
  if p_pin ~ '^(.)\1{5}$' or position(p_pin in '0123456789') > 0 or position(p_pin in '9876543210') > 0 then
    raise exception 'That PIN is too easy to guess. Pick 6 numbers that are not all the same or in a row.';
  end if;
end $$;

create function public.wallet_pin_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('has_pin', exists(select 1 from public.wallet_pins where player_id = auth.uid()));
$$;

create function public.wallet_pin_create(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_n int;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  perform public._wallet_pin_check_new(p_pin);
  insert into public.wallet_pins (player_id, pin_hash) values (v_me, extensions.crypt(p_pin, extensions.gen_salt('bf', 10)))
    on conflict (player_id) do nothing;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'You already have a wallet PIN.'; end if;
  insert into public.notifications (player_id, title, body) values (v_me, '🔒 Wallet PIN created',
    'Your wallet PIN is on. Never share it, not even with JD staff. If this was not you, contact JD support: +977 986-8813682.');
  return jsonb_build_object('ok', true);
end $$;

-- the shared check: counts wrong tries and locks for 30 minutes after 5. Caller must hold the row lock.
create function public._wallet_pin_try(p_row public.wallet_pins, p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_failed int;
begin
  if p_row.locked_until is not null and p_row.locked_until > now() then
    return jsonb_build_object('ok', false, 'locked_until', p_row.locked_until);
  end if;
  if p_row.pin_hash = extensions.crypt(coalesce(p_pin, ''), p_row.pin_hash) then
    update public.wallet_pins set failed = 0, locked_until = null where player_id = p_row.player_id;
    return jsonb_build_object('ok', true);
  end if;
  v_failed := p_row.failed + 1;
  if v_failed >= 5 then
    update public.wallet_pins set failed = 0, locked_until = now() + interval '30 minutes', token_hash = null, token_expires = null where player_id = p_row.player_id;
    insert into public.notifications (player_id, title, body) values (p_row.player_id, '⚠️ Wallet PIN locked',
      'Someone entered a wrong wallet PIN 5 times, so it is locked for 30 minutes. If this was not you, change your password and contact JD support: +977 986-8813682.');
    return jsonb_build_object('ok', false, 'locked_until', now() + interval '30 minutes');
  end if;
  update public.wallet_pins set failed = v_failed where player_id = p_row.player_id;
  return jsonb_build_object('ok', false, 'left', 5 - v_failed);
end $$;

create function public.wallet_pin_verify(p_pin text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.wallet_pins; v_res jsonb; v_token text;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  select * into v_row from public.wallet_pins where player_id = auth.uid() for update;
  if v_row.player_id is null then return jsonb_build_object('ok', false, 'no_pin', true); end if;
  v_res := public._wallet_pin_try(v_row, p_pin);
  if not (v_res->>'ok')::boolean then return v_res; end if;
  v_token := encode(extensions.gen_random_bytes(24), 'hex');
  update public.wallet_pins set token_hash = encode(extensions.digest(v_token, 'sha256'), 'hex'), token_expires = now() + interval '5 minutes'
    where player_id = auth.uid();
  return jsonb_build_object('ok', true, 'token', v_token);
end $$;

create function public.wallet_pin_change(p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.wallet_pins; v_res jsonb;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform public._wallet_pin_check_new(p_new);
  select * into v_row from public.wallet_pins where player_id = auth.uid() for update;
  if v_row.player_id is null then return jsonb_build_object('ok', false, 'no_pin', true); end if;
  v_res := public._wallet_pin_try(v_row, p_old);
  if not (v_res->>'ok')::boolean then return v_res; end if;
  update public.wallet_pins set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)), token_hash = null, token_expires = null, updated_at = now()
    where player_id = auth.uid();
  insert into public.notifications (player_id, title, body) values (auth.uid(), '🔒 Wallet PIN changed',
    'Your wallet PIN was changed. If this was not you, contact JD support now: +977 986-8813682.');
  return jsonb_build_object('ok', true);
end $$;

create function public._wallet_pin_consume(p_token text) returns void
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  update public.wallet_pins set token_hash = null, token_expires = null
    where player_id = auth.uid() and token_expires > now()
      and token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'PIN_REQUIRED: Enter your wallet PIN first. If this page is old, close it, reopen your wallet and try again.'; end if;
end $$;

create function public.admin_wallet_pin_reset(p_player uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  delete from public.wallet_pins where player_id = p_player;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('ok', false); end if;
  insert into public.notifications (player_id, title, body) values (p_player, '🔒 Wallet PIN reset',
    'JD support reset your wallet PIN. Create a new one in your wallet. If you did not ask for this, contact support now: +977 986-8813682.');
  return jsonb_build_object('ok', true);
end $$;

drop function public.request_withdrawal(integer, text, text);
CREATE OR REPLACE FUNCTION public.request_withdrawal(p_amount integer, p_esewa_id text, p_esewa_name text, p_pin_token text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_req public.withdraw_requests;
  v_bal int;
  v_fee int;
  v_payout int;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform public._assert_open();
  perform public._wallet_pin_consume(p_pin_token);
  if exists(select 1 from public.wallets where player_id = auth.uid() and unlimited) then
    raise exception 'The admin wallet has unlimited points, so it can''t be withdrawn.';
  end if;
  if exists(select 1 from public.wallets where player_id = auth.uid() and staff) then
    raise exception 'This is a staff wallet: its points are for spending on JD Arena, not for withdrawing. Ask the owner.';
  end if;
  if (select count(*) from public.withdraw_requests where player_id = auth.uid() and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Too many withdrawal requests — please wait an hour and try again.';
  end if;
  if p_amount is null or p_amount < 1 then raise exception 'Enter how many points to withdraw.'; end if;
  if p_amount < 100 then raise exception 'The minimum withdrawal is 100 points.'; end if;
  -- 1% platform fee, at least 1 point.
  v_fee := greatest(1, ceil(p_amount::numeric / 100))::int;
  v_payout := p_amount - v_fee;
  p_esewa_id := trim(coalesce(p_esewa_id, ''));
  p_esewa_name := trim(coalesce(p_esewa_name, ''));
  if length(p_esewa_id) < 5 or length(p_esewa_id) > 40 then
    raise exception 'Enter your eSewa ID (the phone number or email on your eSewa account).';
  end if;
  if length(p_esewa_name) < 2 or length(p_esewa_name) > 60 then
    raise exception 'Enter the name on your eSewa account.';
  end if;
  insert into public.withdraw_requests (player_id, amount, esewa_id, esewa_name, fee, payout)
  values (auth.uid(), p_amount, p_esewa_id, p_esewa_name, v_fee, v_payout) returning * into v_req;
  v_bal := public._wallet_apply(auth.uid(), -p_amount, 'withdraw', v_req.id::text, null);
  return jsonb_build_object('id', v_req.id, 'amount', p_amount, 'fee', v_fee, 'payout', v_payout, 'balance', v_bal);
end; $function$;
drop function public.request_wallet_load(integer, text);
CREATE OR REPLACE FUNCTION public.request_wallet_load(p_amount integer, p_screenshot text, p_pin_token text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_admin uuid; v_who text;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  perform public._assert_open();
  perform public._wallet_pin_consume(p_pin_token);
  if p_amount is null or p_amount < 1 or p_amount > 100000 then
    raise exception 'Enter the amount you paid (1 to 100000).';
  end if;
  if p_screenshot is null or p_screenshot !~ '^data:image/(png|jpe?g|webp);base64,[A-Za-z0-9+/=]+$' then
    raise exception 'Please attach your eSewa payment screenshot.';
  end if;
  if length(p_screenshot) > 600000 then
    raise exception 'The screenshot is too large. Please upload a smaller image.';
  end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then
    raise exception 'Your account is banned.';
  end if;
  if (select count(*) from public.wallet_load_requests where player_id = auth.uid() and status = 'pending') >= 3 then
    raise exception 'You already have 3 payments waiting to be checked. Please wait for them first.';
  end if;
  insert into public.wallet_load_requests (player_id, amount, screenshot)
  values (auth.uid(), p_amount, p_screenshot)
  returning id into v_id;

  select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com';
  if v_admin is not null then
    select coalesce('@' || username, player_tag, 'A player') into v_who from public.players where id = auth.uid();
    insert into public.notifications (player_id, title, body)
    values (v_admin, '🧾 Payment screenshot to check',
            coalesce(v_who, 'A player') || ' sent a Rs ' || p_amount || ' eSewa screenshot. Open Admin → Points to approve or reject it.');
  end if;
  return jsonb_build_object('id', v_id, 'status', 'pending');
end;
$function$;

revoke all on function public._wallet_pin_check_new(text) from public, anon, authenticated;
revoke all on function public._wallet_pin_try(public.wallet_pins, text) from public, anon, authenticated;
revoke all on function public._wallet_pin_consume(text) from public, anon, authenticated;
revoke all on function public.admin_wallet_pin_reset(uuid) from public, anon, authenticated;
grant execute on function public.admin_wallet_pin_reset(uuid) to service_role;
revoke all on function public.wallet_pin_status() from public, anon;
revoke all on function public.wallet_pin_create(text) from public, anon;
revoke all on function public.wallet_pin_verify(text) from public, anon;
revoke all on function public.wallet_pin_change(text, text) from public, anon;
revoke all on function public.request_withdrawal(integer, text, text, text) from public, anon;
revoke all on function public.request_wallet_load(integer, text, text) from public, anon;
grant execute on function public.wallet_pin_status() to authenticated;
grant execute on function public.wallet_pin_create(text) to authenticated;
grant execute on function public.wallet_pin_verify(text) to authenticated;
grant execute on function public.wallet_pin_change(text, text) to authenticated;
grant execute on function public.request_withdrawal(integer, text, text, text) to authenticated;
grant execute on function public.request_wallet_load(integer, text, text) to authenticated;
notify pgrst, 'reload schema';
commit;
