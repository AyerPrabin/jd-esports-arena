-- Hardens the self-service PIN reset (security review, 2026-11-06): no withdrawals for 24 hours after a reset, an alert when
-- a reset starts, and no reset if the account has a linked identity with a different email (a thief who linked their own Google).
begin;
alter table public.wallet_pins add column reset_at timestamptz;
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
  if exists(select 1 from public.wallet_pins where player_id = auth.uid() and reset_at > now() - interval '24 hours') then
    raise exception 'For your safety, withdrawals are paused for 24 hours after a PIN reset. Your points are safe.';
  end if;
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
create or replace function public.wallet_pin_reset_start() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  update public.wallet_pins set reset_started = now() where player_id = auth.uid()
    and (reset_started is null or reset_started < now() - interval '2 minutes');
  if found then
    insert into public.notifications (player_id, title, body) values (auth.uid(), '🔒 Wallet PIN reset started',
      'Someone started a wallet PIN reset on your account. If this was not you, change your Google password and contact JD support now: +977 986-8813682.');
  end if;
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.wallet_pin_reset_finish(p_new text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.wallet_pins;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform public._wallet_pin_check_new(p_new);
  select * into v_row from public.wallet_pins where player_id = auth.uid() for update;
  if v_row.player_id is null or not public._wallet_pin_fresh_proof(v_row.reset_started) then
    raise exception 'Please verify with Google again, then pick your new PIN within 15 minutes.';
  end if;
  if exists(select 1 from auth.identities i join auth.users u on u.id = i.user_id where i.user_id = auth.uid()
            and lower(coalesce(i.identity_data->>'email', u.email)) <> lower(u.email)) then
    raise exception 'This account can''t reset its PIN here. Please contact JD support: +977 986-8813682.';
  end if;
  update public.wallet_pins set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)), failed = 0, locked_until = null,
    token_hash = null, token_expires = null, reset_started = null, reset_at = now(), updated_at = now() where player_id = auth.uid();
  insert into public.notifications (player_id, title, body) values (auth.uid(), '🔒 Wallet PIN reset',
    'Your wallet PIN was reset after verifying your account. Withdrawals are paused for 24 hours for your safety. If this was not you, contact JD support now: +977 986-8813682.');
  return jsonb_build_object('ok', true);
end $$;
notify pgrst, 'reload schema';
commit;
