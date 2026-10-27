-- ── Admin refund button (owner, 28 Oct 2026) ──
-- One place to refund any charge a player paid with points: event entry, squad effect, Weekly Pass / Pro (bought or
-- taken from a prize), Optimizer plan, challenge stake, or a manual deduction. Rules:
--   * a charge can never be refunded for more than was taken (partial refunds add up to at most the full amount);
--     refunds already made for it - by this button or earlier fixes (passrefund / passprizefix) - count;
--   * refunding a Weekly Pass ends that pass and its effect; refunding an effect ends that effect;
--     entries / Optimizer plans / challenges keep their registration / plan / result (change those in their own panel);
--   * "custom" refunds (no charge picked) need a reason;
--   * every refund goes through _wallet_apply (security lock + sweep), notifies the player, ref adminrefund:...
begin;

create or replace function public._refunded_for(l public.wallet_ledger)
returns int language sql stable security definer set search_path = public as $$
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
$$;
revoke all on function public._refunded_for(public.wallet_ledger) from public, anon, authenticated;

-- the player's recent charges and how much of each can still be refunded
create or replace function public.admin_refundables(p_player uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('id', l.id, 'reason', l.reason, 'charged', -l.delta, 'ref', l.ref, 'note', l.note,
             'created_at', l.created_at,
             'refunded', public._refunded_for(l),
             'left', greatest(-l.delta - public._refunded_for(l), 0)) x
    from public.wallet_ledger l
    where l.player_id = p_player and l.delta < 0
      and l.reason in ('entry','effect','pass','optimizer','challenge_stake','adjust')
    order by l.created_at desc limit 60) s
$$;
revoke all on function public.admin_refundables(uuid) from public, anon, authenticated;
grant execute on function public.admin_refundables(uuid) to service_role;

create or replace function public.admin_refund(p_player uuid, p_ledger uuid, p_amount int, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l public.wallet_ledger;
  v_left int;
  v_amt int;
  v_bal int;
  v_n int;
  v_what text;
  v_ended text := '';
  v_ref text;
begin
  p_reason := nullif(trim(coalesce(p_reason, '')), '');
  if p_player is null or not exists (select 1 from public.players where id = p_player) then
    raise exception 'Player not found.';
  end if;
  perform pg_advisory_xact_lock(hashtext('refund:' || p_player::text));
  if p_ledger is null then   -- custom refund (e.g. paid by eSewa for something that never happened)
    if p_amount is null or p_amount < 1 then raise exception 'Enter how many points to refund.'; end if;
    if p_amount > 5000 then raise exception 'Custom refunds are capped at 5000 points - use several or check the amount.'; end if;
    if p_reason is null then raise exception 'Write why you are refunding (the player sees it).'; end if;
    v_ref := 'adminrefund:custom:' || gen_random_uuid()::text;
    v_amt := p_amount;
    v_what := 'Refund';
  else
    select * into l from public.wallet_ledger where id = p_ledger and player_id = p_player;
    if not found or l.delta >= 0 then raise exception 'That charge was not found for this player.'; end if;
    if l.reason not in ('entry','effect','pass','optimizer','challenge_stake','adjust') then
      raise exception 'This kind of transaction cannot be refunded here.';
    end if;
    v_left := -l.delta - public._refunded_for(l);
    if v_left <= 0 then raise exception 'This charge has already been fully refunded.'; end if;
    v_amt := coalesce(p_amount, v_left);
    if v_amt < 1 then raise exception 'Enter how many points to refund.'; end if;
    if v_amt > v_left then raise exception 'Only % points of this charge are left to refund.', v_left; end if;
    select count(*) into v_n from public.wallet_ledger where ref like 'adminrefund:' || l.id::text || '%';
    v_ref := 'adminrefund:' || l.id::text || ':' || (v_n + 1);
    v_what := case l.reason when 'entry' then 'Event entry' when 'effect' then 'Squad effect'
      when 'pass' then 'Weekly Pass' when 'optimizer' then 'Optimizer plan' when 'challenge_stake' then 'Challenge stake'
      else 'Deduction' end || ' refund';
    if l.reason = 'pass' and v_amt = v_left then
      update public.weekly_passes wp set starts_at = least(wp.starts_at, now()), expires_at = least(wp.starts_at, now())
        where wp.player_id = p_player and (l.ref = wp.ref or l.ref like wp.ref || ':%') and wp.expires_at > now();
      get diagnostics v_n = row_count;
      update public.effect_passes e set starts_at = least(e.starts_at, now()), expires_at = least(e.starts_at, now())
        where e.player_id = p_player and e.expires_at > now()
          and e.code in (select wp.ref from public.weekly_passes wp where wp.player_id = p_player
                          and (l.ref = wp.ref or l.ref like wp.ref || ':%'));
      if v_n > 0 then v_ended := ' The pass has ended.'; end if;
    elsif l.reason = 'effect' and v_amt = v_left and l.ref is not null then
      update public.effect_passes set expires_at = least(expires_at, greatest(starts_at, now()))
        where player_id = p_player and code = l.ref and expires_at > now();
      get diagnostics v_n = row_count;
      if v_n > 0 then v_ended := ' The effect has ended.'; end if;
    end if;
  end if;
  v_bal := public._wallet_apply(p_player, v_amt, 'refund', v_ref, left(v_what || coalesce(' - ' || p_reason, ''), 200));
  insert into public.notifications (player_id, title, body) values (p_player, '💸 ' || v_amt || ' points refunded',
    v_what || coalesce(': ' || p_reason, '') || '. Balance: ' || v_bal || ' points.' || v_ended);
  return jsonb_build_object('refunded', v_amt, 'balance', v_bal, 'ref', v_ref, 'what', v_what, 'ended', v_ended <> '');
end;
$$;
revoke all on function public.admin_refund(uuid, uuid, int, text) from public, anon, authenticated;
grant execute on function public.admin_refund(uuid, uuid, int, text) to service_role;
commit;
