-- 8 Nov 2026 (owner): inviting a friend no longer pays 40 points each. When the invited friend wins their first prize,
-- the friend who invited them gets ONE free entry card (the free-event card: joins one free event, lasts 30 days).
-- Each player can invite at most 3 friends (so at most 3 cards). At most one card per invited friend; the invited player gets nothing extra (they just won a prize). Same guards as
-- mod_commission_waitlist.sql (run that first): the prize must be 30+ points and the two accounts must not be the same person.
-- Points already paid stay. Undo: referral_card_rollback.sql
begin;

CREATE OR REPLACE FUNCTION public._award_one(p_slug text, p_squad text, p_amount integer)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare
  v_player uuid;
  v_ref text := 'prize:' || p_slug || ':' || lower(trim(p_squad));
  v_bal int;
  v_cut int := 0;
  v_referrer uuid;
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
  v_bal := public._wallet_apply(v_player, p_amount, 'prize', v_ref, p_slug);
  -- referral: the invited player's first prize -> one free entry card for the friend who invited them (once per invited player)
  update public.referrals rf set bonus_paid_at = now() where rf.referred_id = v_player and rf.bonus_paid_at is null
    and p_amount >= 30 and not public._referral_same_account(rf.referred_id, rf.referrer_id)
    returning referrer_id into v_referrer;
  if v_referrer is not null then
    insert into public.entry_vouchers (player_id, expires_at, tier, max_npr) values (v_referrer, now() + interval '30 days', 'free', 1);
    insert into public.notifications (player_id, title, body) values (v_referrer, 'Free entry card: your friend won',
      coalesce((select coalesce(username, player_tag) from public.players where id = v_player), 'Your invited friend') ||
      ' won their first prize, so you got a free entry card. It joins one free event and lasts 30 days.');
  end if;
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (v_player, p_slug, 'Prize: +' || p_amount || ' JD points',
          'Congratulations! ' || p_squad || '''s prize for ' || p_slug || ' (' || p_amount || ' points) is in your wallet.' ||
          ' Balance: ' || v_bal || ' points. You can use it for entries or withdraw it to eSewa.');
  return jsonb_build_object('squad', p_squad, 'status', 'paid', 'amount', p_amount, 'player_id', v_player,
                            'pass_cut', v_cut, 'referral', v_referrer is not null);
end;
$function$;

CREATE OR REPLACE FUNCTION public.my_referrals()
 RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'code', (select player_tag from public.players where id = auth.uid()),
    'invited', (select count(*) from public.referrals where referrer_id = auth.uid()),
    'won', (select count(*) from public.referrals where referrer_id = auth.uid() and bonus_paid_at is not null),
    'cards', (select count(*) from public.referrals where referrer_id = auth.uid() and bonus_paid_at is not null),
    'inviter', (select coalesce(p.username, p.player_tag) from public.referrals r join public.players p on p.id = r.referrer_id
                where r.referred_id = auth.uid()),
    'inviter_bonus_paid', (select bonus_paid_at is not null from public.referrals where referred_id = auth.uid()),
    'can_enter', (select created_at > now() - interval '14 days' from public.players where id = auth.uid())
                 and not exists(select 1 from public.referrals where referred_id = auth.uid())
                 and not exists(select 1 from public.wallet_ledger where player_id = auth.uid() and reason = 'prize'));
$function$;

CREATE OR REPLACE FUNCTION public.set_referrer(p_code text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
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
  perform pg_advisory_xact_lock(hashtext('ref:' || v_ref::text));
  if (select count(*) from public.referrals where referrer_id = v_ref) >= 3 then
    raise exception '% already invited 3 friends, the most allowed. Ask another friend for their code.', v_name;
  end if;
  insert into public.referrals (referred_id, referrer_id) values (auth.uid(), v_ref);
  insert into public.notifications (player_id, title, body) values (v_ref, 'A friend joined with your code',
    coalesce((select coalesce(username, player_tag) from public.players where id = auth.uid()), 'A new player') ||
    ' signed up with your invite. When their squad wins its first prize, you get a free entry card.');
  return jsonb_build_object('inviter', v_name);
end;
$function$;

commit;
