-- audit_money_fixes.sql (21 Nov 2026, from the code audit; each function rebuilt from its LIVE definition)
-- 1) _waitlist_take: claims the waitlisted row before charging, so two triggers at once can't charge a squad twice.
-- 2) promote_from_waitlist: one fill at a time per event (advisory lock), so slots can't overfill.
-- 3) staff_restore_removed: refuses a squad already refunded for that event, and refuses when the event is full
--    (2 squads were put back for free after a refund, 1 point each).
-- 4) lfg_pay_player: lock per payer, so a double tap can't pay the same teammate fee twice.
-- 5) admin_wallet_credit: max 100000 at once (a typo can't add millions). Also covers load approvals.
-- 6) _refunded_for: Admin > Refund now counts refunds already given by other paths, so a charge can't be refunded twice.
-- Run: npx supabase db query --remote --yes -f supabase/audit_money_fixes.sql
-- Undo: the previous definitions are in git history (mod_commission_waitlist.sql, schema.sql, teammate_pay_lock_order.sql, admin_refund.sql)
begin;
CREATE OR REPLACE FUNCTION public._waitlist_take(p_reg registrations)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rest int := greatest(public._waitlist_entry(p_reg.tournament_slug, p_reg.player_id) - coalesce(p_reg.paid_points, 0), 0);
begin
  -- claim the slot first: a second caller for the same squad finds no waitlisted row and charges nothing
  update public.registrations set status = 'confirmed', promoted_at = now(), paid_points = coalesce(paid_points, 0) + v_rest
    where id = p_reg.id and status = 'waitlisted';
  if not found then return false; end if;
  if v_rest > 0 then   -- not enough points: the exception below undoes the claim too
    perform public._wallet_apply(p_reg.player_id, -v_rest, 'entry', p_reg.id::text, p_reg.tournament_slug);
  end if;
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (p_reg.player_id, p_reg.tournament_slug, '🎟 Off the waitlist: ' || p_reg.tournament_slug,
    'A slot opened and your squad "' || coalesce(p_reg.squad_name, 'your squad') || '" is in.' ||
    case when v_rest > 0 then ' The other ' || v_rest || ' points of your entry were taken from your wallet.' else '' end ||
    ' Open your ticket and tap "Confirm you''re playing".');
  return true;
exception when others then
  if not exists(select 1 from public.notifications n where n.player_id = p_reg.player_id and n.tournament_slug = p_reg.tournament_slug
                and n.title like '🪙 A slot opened%' and n.created_at > now() - interval '1 hour') then
    insert into public.notifications (player_id, tournament_slug, title, body)
    values (p_reg.player_id, p_reg.tournament_slug, '🪙 A slot opened: ' || p_reg.tournament_slug,
      'You needed ' || v_rest || ' more points for the slot, so it went to the next squad. You are still on the waitlist. Load points to be ready for the next one.');
  end if;
  return false;
end $function$;

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
  perform pg_advisory_xact_lock(hashtext('waitlist:' || v_tournament));   -- two squads leaving at once: one fill at a time
  select slots into v_slots from public.tournament_capacity where tournament_slug = v_tournament;
  if v_slots is null then return coalesce(new, old); end if;
  select count(*) into v_count from public.registrations
    where tournament_slug = v_tournament and status in ('confirmed', 'approved');
  if v_count >= v_slots then return coalesce(new, old); end if;
  if public._waitlist_deposit_event(v_tournament) then
    perform public._waitlist_fill(v_tournament);
    return coalesce(new, old);
  end if;
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

CREATE OR REPLACE FUNCTION public.staff_restore_removed(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l public.jd_no_show_log; v_slots int; v_taken int;
begin
  select * into l from public.jd_no_show_log where jd_no_show_log.id = p_id;
  if not found then raise exception 'Not found.'; end if;
  if not public._staff_can_event(l.tournament_slug) then raise exception 'Moderators only.'; end if;
  if exists (select 1 from public.registrations r where r.tournament_slug = l.tournament_slug and r.player_id = l.player_id) then
    raise exception '% is already registered for this event.', l.squad_name;
  end if;
  if exists (select 1 from public.wallet_ledger w where w.player_id = l.player_id and w.reason = 'refund'
               and w.note = l.tournament_slug and w.created_at >= l.removed_at - interval '5 minutes') then
    raise exception '% already got their entry back for this event. They must register and pay again.', l.squad_name;
  end if;
  select slots into v_slots from public.tournament_capacity where tournament_slug = l.tournament_slug;
  select count(*) into v_taken from public.registrations where tournament_slug = l.tournament_slug and status in ('confirmed','approved');
  if v_slots is not null and v_taken >= v_slots then raise exception 'The event is full (% of % slots).', v_taken, v_slots; end if;
  insert into public.registrations (tournament_slug, player_id, squad_name, squad_logo, status, verified_at)
  select l.tournament_slug, l.player_id, l.squad_name, p.squad_logo, 'confirmed', now()
  from public.players p where p.id = l.player_id;
  update public.jd_no_show_log set restored_at = now() where jd_no_show_log.id = p_id;
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (l.player_id, l.tournament_slug, '✅ You''re back in ' || l.tournament_slug,
    'A JD moderator put "' || l.squad_name || '" back in ' || l.tournament_slug || '. Open your ticket and tap "Confirm you''re playing".');
  select slots into v_slots from public.tournament_capacity where tournament_slug = l.tournament_slug;
  select count(*) into v_taken from public.registrations where tournament_slug = l.tournament_slug and status in ('confirmed','approved');
  return jsonb_build_object('squad', l.squad_name, 'slots', v_slots, 'taken', v_taken);
end $function$;

CREATE OR REPLACE FUNCTION public.lfg_pay_player(p_id bigint, p_to text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_me uuid := auth.uid(); p public.teammate_posts; v_to uuid; v_bal int; v_ref text;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  perform pg_advisory_xact_lock(hashtext('tm:' || v_me::text));
  select * into p from public.teammate_posts where id = p_id and player_id = v_me and expires_at > now() for update;
  if p.id is null then raise exception 'Post not found.'; end if;
  if p.kind <> 'squad' or p.pay <> 'paid' or p.amount is null then raise exception 'This post has no fee to pay.'; end if;
  select id into v_to from public.players where lower(username) = lower(regexp_replace(trim(coalesce(p_to, '')), '^@', ''));
  if v_to is null then raise exception 'No player called %.', p_to; end if;
  if v_to = v_me then raise exception 'You can''t pay yourself.'; end if;
  if exists(select 1 from public.banned_players where player_id in (v_me, v_to)) then raise exception 'This payment is not allowed.'; end if;
  if not public._are_friends(v_me, v_to) or public._blocked_either(v_me, v_to) then
    raise exception 'Add them as a friend first: they must accept before you pay.';
  end if;
  if coalesce((select unlimited from public.wallets where player_id = v_me), false) then raise exception 'Staff wallets can''t pay teammates.'; end if;
  v_ref := 'tm:' || p.id || ':' || v_to;
  if exists(select 1 from public.wallet_ledger where player_id = v_me and reason = 'teammate_pay' and ref = v_ref
            and created_at > now() - interval '7 days') then
    raise exception 'You already paid this player for this post.';
  end if;
  if coalesce((select -sum(delta) from public.wallet_ledger where player_id = v_me and reason = 'teammate_pay'
               and created_at > now() - interval '1 day'), 0) + p.amount > 10000 then
    raise exception 'Daily limit: 10000 points to teammates.';
  end if;
  -- lock both wallets in a fixed order (player_id) before moving points, so A->B and B->A at once can't deadlock
  insert into public.wallets (player_id) values (least(v_me, v_to)), (greatest(v_me, v_to)) on conflict do nothing;
  perform 1 from public.wallets where player_id in (v_me, v_to) order by player_id for update;
  v_bal := public._wallet_apply(v_me, -p.amount, 'teammate_pay', v_ref, 'Paid ' || public._chat_name(v_to));
  perform public._wallet_apply(v_to, p.amount, 'teammate_paid', v_ref, 'From ' || public._chat_name(v_me));
  insert into public.notifications (player_id, title, body) values (v_to, '🪙 +' || p.amount || ' JD points from your squad',
    public._chat_name(v_me) || ' paid you the teammate fee (' || p.amount || ' points). Good luck in the match!');
  return v_bal;
end $function$;

CREATE OR REPLACE FUNCTION public.admin_wallet_credit(p_player uuid, p_amount integer, p_ref text, p_note text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_bal int;
begin
  if p_amount is null or p_amount < 1 then
    raise exception 'Enter how many points to add.';
  end if;
  if p_amount > 100000 then raise exception 'At most 100000 points at once: check the amount.'; end if;
  p_ref := upper(trim(coalesce(p_ref, '')));
  if p_ref = '' then
    p_ref := 'MANUAL-' || replace(gen_random_uuid()::text, '-', '');
  end if;
  begin
    v_bal := public._wallet_apply(p_player, p_amount, 'load', p_ref, p_note);
  exception when unique_violation then
    raise exception 'This eSewa transaction (%) has already been credited.', p_ref;
  end;
  insert into public.notifications (player_id, title, body)
  values (p_player, '+' || p_amount || ' JD points added',
          'Your payment was verified and ' || p_amount || ' points were added to your wallet. Balance: ' || v_bal || ' points.');
  return v_bal;
end;
$function$;

CREATE OR REPLACE FUNCTION public._refunded_for(l wallet_ledger)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select sum(delta) from public.wallet_ledger where player_id = l.player_id and reason = 'refund'
                    and ref like 'adminrefund:' || l.id::text || '%'), 0)
       + case when l.reason = 'pass' then
           coalesce((select sum(r.delta) from public.wallet_ledger r join public.weekly_passes wp
                       on r.ref = 'passrefund:' || wp.id
                     where wp.player_id = l.player_id and (l.ref = wp.ref or l.ref like wp.ref || ':%')
                       and r.ref not like 'adminrefund:%'), 0)
         + coalesce((select sum(r.delta) from public.wallet_ledger r
                     where r.player_id = l.player_id and r.reason = 'refund' and l.ref like 'passprize:%'
                       and r.ref = 'passprizefix:' || substr(l.ref, 11)), 0)
         else 0 end
       -- entry / stake / effect already returned by withdraw, waitlist, no-show, mod removal, host, mega or challenge refunds
       + case when l.reason in ('entry','challenge_stake','effect') and l.ref is not null then
           coalesce((select sum(r.delta) from public.wallet_ledger r
                     where r.player_id = l.player_id and r.reason in ('refund','challenge_refund') and r.delta > 0
                       and r.ref not like 'adminrefund:%' and (r.ref = l.ref or r.ref like '%:' || l.ref || '%')), 0)
         else 0 end
$function$;
commit;
