-- Undo referral_card.sql: back to +40 points each, as set by mod_commission_waitlist.sql (8 Nov 2026)
begin;
CREATE OR REPLACE FUNCTION public._award_one(p_slug text, p_squad text, p_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player uuid;
  v_ref text := 'prize:' || p_slug || ':' || lower(trim(p_squad));
  v_bal int;
  v_cut int := 0;
  v_referrer uuid;
  v_note text := '';
begin
  if p_amount is null or p_amount < 1 then
    return jsonb_build_object('squad', p_squad, 'status', 'no_amount');
  end if;
  if exists(select 1 from public.wallet_ledger where reason = 'prize' and ref = v_ref) then
    return jsonb_build_object('squad', p_squad, 'status', 'already_paid');
  end if;
  select player_id into v_player from public.registrations
    where tournament_slug = p_slug and lower(trim(squad_name)) = lower(trim(p_squad))
      and status in ('confirmed','approved')
    order by created_at asc limit 1;
  if v_player is null then
    return jsonb_build_object('squad', p_squad, 'status', 'unmatched', 'amount', p_amount);
  end if;
  -- the admin's own squad is paid like any other (2026-10-30): when the admin says "not for me", the
  -- results board simply gives that prize_won to the next squad instead - no automatic block here
  v_bal := public._wallet_apply(v_player, p_amount, 'prize', v_ref, p_slug);
  -- referral: the invited player's first prize -> +40 for them and +40 for the friend who invited them
  update public.referrals rf set bonus_paid_at = now() where rf.referred_id = v_player and rf.bonus_paid_at is null
    and p_amount >= 30 and not public._referral_same_account(rf.referred_id, rf.referrer_id)
    returning referrer_id into v_referrer;
  if v_referrer is not null then
    v_bal := public._wallet_apply(v_player, 40, 'referral', 'ref:' || v_player::text, 'Invite bonus - first win');
    perform public._wallet_apply(v_referrer, 40, 'referral', 'ref:' || v_player::text || ':by', 'Your invited friend won');
    insert into public.notifications (player_id, title, body) values (v_referrer, '🤝 +40 points: your friend won',
      coalesce((select coalesce(username, player_tag) from public.players where id = v_player), 'Your invited friend') ||
      ' won their first prize, so you both got +40 points. Invite more friends from your profile.');
    v_note := v_note || ' +40 invite bonus for your first win.';
  end if;
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (v_player, p_slug, '🏆 Prize: +' || p_amount || ' JD points',
          'Congratulations! ' || p_squad || '''s prize for ' || p_slug || ' (' || p_amount || ' points) is in your wallet.' ||
          v_note || ' Balance: ' || v_bal || ' points. You can use it for entries or withdraw it to eSewa.');
  return jsonb_build_object('squad', p_squad, 'status', 'paid', 'amount', p_amount, 'player_id', v_player,
                            'pass_cut', v_cut, 'referral', v_referrer is not null);
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_referrer(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_code text := upper(regexp_replace(trim(coalesce(p_code, '')), '^@', ''));
  v_ref uuid;
  v_name text;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.referrals where referred_id = auth.uid()) then
    raise exception 'You already joined with a friend''s invite code.';
  end if;
  if (select created_at from public.players where id = auth.uid()) < now() - interval '14 days' then
    raise exception 'Invite codes work in your first 14 days on JD Arena.';
  end if;
  if exists(select 1 from public.wallet_ledger where player_id = auth.uid() and reason = 'prize') then
    raise exception 'Invite codes are for new players who haven''t won a prize yet.';
  end if;
  if v_code = '' then raise exception 'Enter your friend''s JD tag or username.'; end if;
  select id, coalesce(username, player_tag) into v_ref, v_name from public.players
    where upper(player_tag) = v_code or upper(player_tag) = 'JD-' || v_code or upper(username) = v_code limit 1;
  if v_ref is null then raise exception 'No player with that JD tag or username.'; end if;
  if v_ref = auth.uid() then raise exception 'You can''t use your own code.'; end if;
  if exists(select 1 from public.referrals where referred_id = v_ref and referrer_id = auth.uid()) then
    raise exception 'You invited this player - you can''t use their code too.';
  end if;
  if public._referral_same_account(auth.uid(), v_ref) then raise exception 'That code can''t be used.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_ref) then raise exception 'That code can''t be used.'; end if;
  insert into public.referrals (referred_id, referrer_id) values (auth.uid(), v_ref);
  insert into public.notifications (player_id, title, body) values (v_ref, '🤝 A friend joined with your code',
    coalesce((select coalesce(username, player_tag) from public.players where id = auth.uid()), 'A new player') ||
    ' signed up with your invite. When their squad wins its first prize, you both get +40 points.');
  return jsonb_build_object('inviter', v_name);
end;
$function$;

CREATE OR REPLACE FUNCTION public.my_referrals()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'code', (select player_tag from public.players where id = auth.uid()),
    'invited', (select count(*) from public.referrals where referrer_id = auth.uid()),
    'won', (select count(*) from public.referrals where referrer_id = auth.uid() and bonus_paid_at is not null),
    'earned', 40 * (select count(*) from public.referrals where referrer_id = auth.uid() and bonus_paid_at is not null),
    'inviter', (select coalesce(p.username, p.player_tag) from public.referrals r join public.players p on p.id = r.referrer_id
                where r.referred_id = auth.uid()),
    'inviter_bonus_paid', (select bonus_paid_at is not null from public.referrals where referred_id = auth.uid()),
    'can_enter', (select created_at > now() - interval '14 days' from public.players where id = auth.uid())
                 and not exists(select 1 from public.referrals where referred_id = auth.uid())
                 and not exists(select 1 from public.wallet_ledger where player_id = auth.uid() and reason = 'prize'));
$function$;
commit;
