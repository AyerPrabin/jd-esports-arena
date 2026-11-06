-- Takes the wallet PIN off loads and withdrawals and deletes every saved PIN.
begin;
drop function public.request_withdrawal(integer, text, text, text);
CREATE OR REPLACE FUNCTION public.request_withdrawal(p_amount integer, p_esewa_id text, p_esewa_name text)
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
drop function public.request_wallet_load(integer, text, text);
CREATE OR REPLACE FUNCTION public.request_wallet_load(p_amount integer, p_screenshot text)
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
revoke all on function public.request_withdrawal(integer, text, text) from public, anon;
revoke all on function public.request_wallet_load(integer, text) from public, anon;
grant execute on function public.request_withdrawal(integer, text, text) to authenticated;
grant execute on function public.request_wallet_load(integer, text) to authenticated;
drop function public.admin_wallet_pin_reset(uuid);
drop function public._wallet_pin_consume(text);
drop function public.wallet_pin_change(text, text);
drop function public.wallet_pin_verify(text);
drop function public._wallet_pin_try(public.wallet_pins, text);
drop function public.wallet_pin_create(text);
drop function public.wallet_pin_status();
drop function public._wallet_pin_check_new(text);
drop table public.wallet_pins;
notify pgrst, 'reload schema';
commit;
