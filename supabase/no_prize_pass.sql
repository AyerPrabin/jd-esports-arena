-- Prizes are always paid in full: _award_one no longer takes 50 points of a free-tournament prize
-- to buy a Weekly Pass for winners without one (28 Oct 2026). 'pass_cut' stays in the result, always 0.
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

  v_bal := public._wallet_apply(v_player, p_amount, 'prize', v_ref, p_slug);



  -- referral: the invited player's first prize -> +40 for them and +40 for the friend who invited them

  update public.referrals set bonus_paid_at = now() where referred_id = v_player and bonus_paid_at is null

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
commit;
