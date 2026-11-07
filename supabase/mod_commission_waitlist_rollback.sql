-- Undoes mod_commission_waitlist.sql: restores the six functions as they were on 2026-11-07. Deposits still held are refunded first.
begin;
delete from public.registrations where status = 'waitlisted' and coalesce(paid_points, 0) > 0;   -- the delete trigger pays each deposit back
select cron.unschedule('waitlist-deposit-sweep');
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
  if exists(select 1 from public.banned_players where player_id = v_ref) then raise exception 'That code can''t be used.'; end if;
  insert into public.referrals (referred_id, referrer_id) values (auth.uid(), v_ref);
  insert into public.notifications (player_id, title, body) values (v_ref, '🤝 A friend joined with your code',
    coalesce((select coalesce(username, player_tag) from public.players where id = auth.uid()), 'A new player') ||
    ' signed up with your invite. When their squad wins its first prize, you both get +40 points.');
  return jsonb_build_object('inviter', v_name);
end;
$function$;

CREATE OR REPLACE FUNCTION public.register_for_tournament(p_tournament_slug text, p_squad_name text, p_squad_logo text, p_status text, p_payment_screenshot text, p_device_type text, p_pay_points boolean DEFAULT false, p_price_seen integer DEFAULT 0)
 RETURNS registrations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

declare

  v_slots int;

  v_count int;

  v_already_registered boolean;

  v_effective_status text := p_status;

  v_platform_mode text;

  v_row public.registrations;

  v_name text;

  v_start timestamptz;
  v_card bigint;
  v_pts int := 0;

begin

  if auth.uid() is null then

    raise exception 'Not signed in';

  end if;

  if p_squad_logo is not null and (length(p_squad_logo) > 200000 or p_squad_logo !~ '^data:image/(png|jpe?g|webp|gif);base64,[A-Za-z0-9+/=]+$') then

    raise exception 'Squad logo must be a PNG, JPG, WEBP or GIF image under 200 KB.';

  end if;

  if p_squad_name is not null and length(trim(p_squad_name)) > 40 then

    raise exception 'Squad name must be 40 characters or fewer.';

  end if;

  v_name := coalesce(nullif(trim(p_squad_name), ''), (select squad_name from public.players where id = auth.uid()));

  if v_name is null or length(trim(v_name)) < 2 then

    raise exception 'Enter your squad name (at least 2 characters).';

  end if;

  update public.players set squad_name = trim(v_name),

    squad_logo = coalesce(p_squad_logo, squad_logo)

    where id = auth.uid();

  if p_status not in ('pending','confirmed') then

    raise exception 'Invalid registration status';

  end if;

  if coalesce(public.tournament_entry_npr(p_tournament_slug), 0) > 0 then

    p_status := 'pending';

    v_effective_status := 'pending';

    -- 2026-10-22: no points, no registration (no "hold a place" entries for the admin and mods to chase)

    if not exists (select 1 from public.wallets w where w.player_id = auth.uid()

                   and (w.unlimited or w.balance >= public.tournament_entry_npr(p_tournament_slug)))

       and public._vouchers_fit(auth.uid(), public.tournament_entry_npr(p_tournament_slug)) = 0 then   -- a free-entry card that covers this fee also lets them join

      raise exception 'Not enough points: this event costs % points. Load points first (Wallet > Load points), then join.',

        public.tournament_entry_npr(p_tournament_slug);

    end if;

  end if;

  if exists(select 1 from public.banned_players where player_id = auth.uid()) then

    raise exception 'Your account is banned from registering for tournaments.';

  end if;

  v_start := public.tournament_start_at(p_tournament_slug);   -- for the early-access window below

  declare v_open timestamptz;

  begin

    if lower(coalesce(public.tournament_field(p_tournament_slug, 'early_access'), '')) in ('yes','true')

       and not exists(select 1 from public.registrations where tournament_slug = p_tournament_slug and player_id = auth.uid()) then

      begin v_open := nullif(public.tournament_field(p_tournament_slug, 'reg_opens'), '')::timestamptz;

      exception when others then v_open := null; end;

      if v_open is not null and now() < v_open then

        if now() < v_open - interval '24 hours' then

          raise exception 'Registration opens at % (app users 24 hours earlier).', to_char(v_open at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM') || ' NPT';

        end if;

        if (select app_installed_at from public.players where id = auth.uid()) is null and not public._optimizer_is_max(auth.uid())

           and public.weekly_pass_tier(auth.uid(), greatest(now(), coalesce(v_start, now()))) is distinct from 'pro' then

          raise exception 'Early access: only JD Arena app users, Weekly Pro and Optimizer Max members can join before %. Open the app to join now.', to_char(v_open at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM') || ' NPT';

        end if;

      end if;

    end if;

  end;

  if p_device_type not in ('mobile','emulator') then

    raise exception 'Pick a device type: mobile or emulator.';

  end if;

  select platform_mode into v_platform_mode from public.tournament_capacity where tournament_slug = p_tournament_slug;

  v_platform_mode := coalesce(v_platform_mode, 'mixed');

  if v_platform_mode <> 'mixed' and v_platform_mode <> p_device_type then

    raise exception 'This tournament is % only -- you declared %.', v_platform_mode, p_device_type;

  end if;

  perform pg_advisory_xact_lock(hashtext(p_tournament_slug));

  select exists(

    select 1 from public.registrations

    where tournament_slug = p_tournament_slug and player_id = auth.uid()

  ) into v_already_registered;

  -- 2026-11-05 owner's rule: a free event needs a free-entry card (repost + comment + post, promo_submit_repost)
  if not v_already_registered and coalesce(public.tournament_entry_npr(p_tournament_slug), 0) = 0
     -- full: the waitlist costs nothing and keeps the card; the place itself costs 20 points (waitlist_buy_slot)
     and coalesce((select count(*) from public.registrations x where x.tournament_slug = p_tournament_slug and x.status in ('confirmed','approved'))
                  < (select c.slots from public.tournament_capacity c where c.tournament_slug = p_tournament_slug), true)
     and not public._free_event_exempt(auth.uid(), greatest(now(), coalesce(v_start, now()))) then
    if p_pay_points then   -- only when the player chose it: an old cached page can never charge anyone
      if p_price_seen is distinct from 15 then   -- an old cached page said 5: never charge more than the player saw
        raise exception 'Free tournaments now cost 15 points. Close and reopen the page, then join again.';
      end if;
      v_pts := 15;
    else
      select id into v_card from public.entry_vouchers
        where player_id = auth.uid() and used_reg is null and expires_at > now()
        order by (tier = 'free') desc nulls last, max_npr asc nulls last, expires_at limit 1 for update skip locked;
      if v_card is null then
        raise exception 'FREE_CARD_NEEDED: Free tournaments need a free card or 15 points. For your first card: follow @ayer_fire, then comment on and repost 3 of our videos with your JD username in each comment (one time only). After that, make a video about JD Arena. Send it in Wallet > Free entry.';
      end if;
    end if;
  end if;
  if not v_already_registered then

    if exists(select 1 from public.registrations r

              where r.tournament_slug = p_tournament_slug

                and r.player_id <> auth.uid()

                and r.status in ('confirmed','approved','waitlisted','pending')

                and lower(trim(r.squad_name)) = lower(trim(v_name))) then

      raise exception 'That squad name is already taken for this event - please pick a different name.';

    end if;

    select slots into v_slots from public.tournament_capacity where tournament_slug = p_tournament_slug;

    if v_slots is not null then

      select count(*) into v_count from public.registrations

        where tournament_slug = p_tournament_slug and status in ('confirmed', 'approved');

      if v_count >= v_slots then

        if p_status = 'confirmed' then

          v_effective_status := 'waitlisted';

        else

          raise exception 'Tournament full';

        end if;

      end if;

    end if;

  end if;

  if v_pts > 0 and v_effective_status <> 'confirmed' then
    raise exception 'This event is full, so your 15 points were not taken.';
  end if;
  insert into public.registrations (tournament_slug, player_id, squad_name, squad_logo, status, payment_screenshot, device_type)

  values (p_tournament_slug, auth.uid(), trim(v_name), null, v_effective_status, p_payment_screenshot, p_device_type)

  returning * into v_row;
  if v_pts > 0 then   -- paid_points: withdrawing, the confirm sweep and no-show refunds all pay back from this
    perform public._wallet_apply(auth.uid(), -v_pts, 'entry', v_row.id::text, p_tournament_slug);
    update public.registrations set paid_points = v_pts where id = v_row.id returning * into v_row;
  end if;
  if v_card is not null then
    update public.entry_vouchers set used_reg = v_row.id, used_slug = p_tournament_slug, used_at = now() where id = v_card;
  end if;

  insert into public.notifications (player_id, tournament_slug, title, body)

  values (

    auth.uid(),

    p_tournament_slug,

    'Registered: ' || p_tournament_slug,

    'TICKET::' || ('JD-' || upper(substr(replace(v_row.id::text, '-', ''), 1, 8))) || '::' || v_effective_status

  );

  return v_row;

end;

$function$;

CREATE OR REPLACE FUNCTION public.promote_from_waitlist()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tournament text := coalesce(new.tournament_slug, old.tournament_slug);
  v_slots int; v_count int; v_next public.registrations; v_start timestamptz;
begin
  select slots into v_slots from public.tournament_capacity where tournament_slug = v_tournament;
  if v_slots is null then return coalesce(new, old); end if;
  select count(*) into v_count from public.registrations
    where tournament_slug = v_tournament and status in ('confirmed', 'approved');
  if v_count >= v_slots then return coalesce(new, old); end if;
  -- 2026-11-06 owner's rule: a free event never moves anyone up for free. The first in line is told a slot is open.
  if public.tournament_entry_npr(v_tournament) = 0 then
    if tg_op = 'DELETE' or (old.status in ('confirmed','approved') and new.status not in ('confirmed','approved')) then
      insert into public.notifications (player_id, tournament_slug, title, body)
      select w.player_id, v_tournament, '🎟 A slot opened: ' || v_tournament,
        'A slot is open. Pay 20 points on your ticket to take it before someone else does.'
      from public.registrations w
      where w.tournament_slug = v_tournament and w.status = 'waitlisted'
        and not exists(select 1 from public.notifications n where n.player_id = w.player_id and n.tournament_slug = v_tournament
                       and n.title like '🎟 A slot opened%' and n.created_at > now() - interval '1 hour')
      order by w.created_at limit 1;
    end if;
    return coalesce(new, old);
  end if;
  select * into v_next from public.registrations
    where tournament_slug = v_tournament and status = 'waitlisted'
    order by (public.weekly_pass_tier(player_id) = 'pro') desc nulls last, created_at asc
    limit 1;
  if not found then return coalesce(new, old); end if;
  update public.registrations set status = 'confirmed', promoted_at = now() where id = v_next.id;
  v_start := public.tournament_start_at(v_tournament);
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (
    v_next.player_id, v_tournament,
    '🎟 Off the waitlist: ' || v_tournament,
    'A slot opened up and your squad "' || coalesce(v_next.squad_name, 'your squad') || '" is in! ' ||
    case when v_start is not null and now() >= v_start - interval '48 hours'
      then 'Open your ticket now and tap "Confirm you''re playing" so the slot stays yours.'
      else 'Open your ticket - you can confirm from 48 hours before the start.' end
  );
  return coalesce(new, old);
end;
$function$;

CREATE OR REPLACE FUNCTION public.withdraw_registration(p_tournament_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_reg public.registrations;
  v_start timestamptz;
  v_late boolean := false;
  v_refund int := 0;
  v_deleted uuid;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  select * into v_reg from public.registrations
    where tournament_slug = p_tournament_slug and player_id = auth.uid()
    for update;
  if v_reg.id is null then
    raise exception 'You are not registered for this tournament.';
  end if;
  v_start := public.tournament_start_at(p_tournament_slug);
  if v_start is not null and v_start <= now() then
    raise exception 'This match has already started, so squads can no longer withdraw.';
  end if;
  if exists(select 1 from public.tournament_room_codes where tournament_slug = p_tournament_slug and sent_at is not null) then
    raise exception 'The room details have been released, so squads can no longer withdraw.';
  end if;
  v_late := v_start is not null and v_start - now() < interval '24 hours';
  if v_reg.paid_points > 0 then
    v_refund := case when v_late then floor(v_reg.paid_points * 0.1)::int else v_reg.paid_points end;
  end if;
  delete from public.registrations where id = v_reg.id returning id into v_deleted;
  if v_deleted is null then
    raise exception 'You are not registered for this tournament.';
  end if;
  if v_refund > 0 then
    perform public._wallet_apply(auth.uid(), v_refund, 'refund', v_reg.id::text, p_tournament_slug);
  end if;
  return jsonb_build_object('refund', v_refund, 'late', v_late, 'paid_points', v_reg.paid_points);
end;
$function$;

CREATE OR REPLACE FUNCTION public.waitlist_buy_slot(p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_me uuid := auth.uid(); v_reg public.registrations; v_vic public.registrations; v_slots int; v_count int; v_start timestamptz; v_unl boolean; v_paid int := 20;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  perform public._assert_open();
  if public.tournament_entry_npr(p_slug) is distinct from 0 then raise exception 'This is only for free tournaments.'; end if;
  perform pg_advisory_xact_lock(hashtext(p_slug));
  select * into v_reg from public.registrations where tournament_slug = p_slug and player_id = v_me for update;
  if v_reg.id is null or v_reg.status <> 'waitlisted' then raise exception 'You are not on this waitlist.'; end if;
  v_start := public.tournament_start_at(p_slug);
  if v_start is null or v_start - now() < interval '30 minutes'
     or exists(select 1 from public.tournament_room_codes c where c.tournament_slug = p_slug and c.sent_at is not null) then
    raise exception 'Places can''t be bought in the last 30 minutes before the start.';
  end if;
  select coalesce(unlimited, false) into v_unl from public.wallets where player_id = v_me;
  if not coalesce(v_unl, false) and coalesce((select balance from public.wallets where player_id = v_me), 0) < 20 then
    raise exception 'You need 20 points for a place. Load points first in your wallet.';
  end if;
  select slots into v_slots from public.tournament_capacity where tournament_slug = p_slug;
  select count(*) into v_count from public.registrations where tournament_slug = p_slug and status in ('confirmed','approved');
  if v_slots is not null and v_count >= v_slots then
    select r.* into v_vic from public.registrations r
      where r.tournament_slug = p_slug and r.status in ('confirmed','approved') and coalesce(r.paid_points, 0) < 20
        and not public._reg_has_effect(r)
        and not exists(select 1 from auth.users u where u.id = r.player_id and lower(u.email) = 'ayerprabin95@gmail.com')
      order by (r.checked_in_at is null) desc, r.created_at desc limit 1 for update;
    if v_vic.id is null then raise exception 'No place can be opened in this event right now.'; end if;
    delete from public.registrations where id = v_vic.id;
    if coalesce(v_vic.paid_points, 0) > 0 and not exists(select 1 from public.wallets w where w.player_id = v_vic.player_id and w.unlimited) then
      perform public._wallet_apply(v_vic.player_id, v_vic.paid_points, 'refund', v_vic.id::text, p_slug);
    end if;
    insert into public.notifications (player_id, tournament_slug, title, body)
    values (v_vic.player_id, p_slug, '❌ Removed from ' || p_slug,
      'Your squad "' || coalesce(v_vic.squad_name, 'your squad') || '" lost its place to a waitlist squad that paid for it. ' ||
      case when coalesce(v_vic.paid_points, 0) > 0 then 'Your ' || v_vic.paid_points || ' points are back in your wallet. ' else 'If you used a free card, it is back in your wallet. ' end ||
      'Confirm early next time to be safer.');
  end if;
  if v_unl then v_paid := 0; else perform public._wallet_apply(v_me, -20, 'entry', v_reg.id::text, p_slug); end if;
  update public.registrations set status = 'confirmed', promoted_at = now(), paid_points = v_paid where id = v_reg.id;
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (v_me, p_slug, '🎟 You have a place: ' || p_slug, 'Your squad "' || coalesce(v_reg.squad_name, 'your squad') || '" is in. Open your ticket and tap "Confirm you''re playing" when it opens.');
  return jsonb_build_object('ok', true, 'paid', v_paid);
end $function$;
drop trigger waitlist_refund_on_delete on public.registrations;
drop function public.host_event_invite(text,text,text,text);
drop function public.commission_settle(text,text);
drop function public.commission_report(text);
drop function public.commission_claim(text,text);
drop function public.referrals_report();
drop function public._referral_same_account(uuid,uuid);
drop function public.staff_remove_reg(uuid);
drop function public.waitlist_deposit_sweep();
drop function public._waitlist_refund_on_delete();
drop function public.waitlist_give_slot(uuid);
drop function public._waitlist_fill(text);
drop function public._waitlist_take(public.registrations);
drop function public._waitlist_closed(text);
drop function public._waitlist_entry(text,uuid);
drop function public._waitlist_deposit_event(text);
drop table public.event_invites;
drop table public.commission_settled;
drop table public.event_runs;
alter table public.moderators drop column agreed_at;
alter table public.moderators drop column commission_pct;
notify pgrst, 'reload schema';
commit;
