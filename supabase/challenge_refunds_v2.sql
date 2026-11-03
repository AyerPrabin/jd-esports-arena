-- 2026-11-03: shorter challenge timers + players can get their stake back without waiting.
--   open, nobody accepts        24 h -> 2 h   (refund creator)
--   accepted, no result         12 h -> 3 h   (refund both)
--   invited player can Decline an open challenge -> creator refunded at once
--   accepted, before any result: either side asks to cancel; when the other side agrees both stakes come back
alter table public.challenges add column if not exists cancel_by uuid references public.players(id) on delete set null;

create or replace function public.decline_challenge(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if not exists(select 1 from public.challenges where id = p_id and invited = auth.uid() and status = 'open') then
    raise exception 'Only a challenge sent to you can be declined.';
  end if;
  perform public._challenge_refund(p_id, 'cancelled', 'declined by ' || public._challenge_name(auth.uid()));
end;
$$;

create or replace function public.request_challenge_cancel(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare c public.challenges; v_other uuid;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  select * into c from public.challenges where id = p_id for update;
  if c.id is null or auth.uid() not in (c.creator, c.opponent) then raise exception 'Challenge not found.'; end if;
  if c.status <> 'accepted' or c.creator_claim is not null or c.opponent_claim is not null then
    raise exception 'A result was already reported, so this challenge can''t be cancelled. Ask the admin in the chat.';
  end if;
  v_other := case when auth.uid() = c.creator then c.opponent else c.creator end;
  if c.cancel_by = v_other then
    perform public._challenge_refund(p_id, 'cancelled', 'both players agreed to cancel');
    return 'cancelled';
  end if;
  if c.cancel_by = auth.uid() then raise exception 'You already asked. Waiting for your opponent to agree.'; end if;
  update public.challenges set cancel_by = auth.uid() where id = p_id;
  insert into public.notifications (player_id, title, body) values (v_other, '⚔️ Cancel request',
    public._challenge_name(auth.uid()) || ' wants to cancel your ' || c.mode || ' challenge. Agree in Challenges and both stakes (' || c.stake || ' points each) come back.');
  return 'requested';
end;
$$;

create or replace function public.challenge_sweep()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n_exp int := 0; n_claim int := 0; n_ref int := 0;
begin
  if exists(select 1 from public.system_state where id = 1 and locked) then
    return jsonb_build_object('skipped', 'locked');
  end if;
  for r in select id from public.challenges where status = 'open' and created_at < now() - interval '2 hours' loop
    perform public._challenge_refund(r.id, 'expired', 'nobody accepted within 2 hours'); n_exp := n_exp + 1;
  end loop;
  for r in select id, creator, opponent, creator_claim, opponent_claim from public.challenges
           where status = 'accepted' and claim_at < now() - interval '2 hours'
             and ((creator_claim = 'won' and opponent_claim is null) or (opponent_claim = 'won' and creator_claim is null)) loop
    perform public._challenge_payout(r.id, case when r.creator_claim = 'won' then r.creator else r.opponent end, 'no response within 2 hours'); n_claim := n_claim + 1;
  end loop;
  for r in select id from public.challenges where status = 'accepted' and claim_at is null and accepted_at < now() - interval '3 hours' loop
    perform public._challenge_refund(r.id, 'refunded', 'no result reported within 3 hours'); n_ref := n_ref + 1;
  end loop;
  return jsonb_build_object('expired', n_exp, 'claims_paid', n_claim, 'refunded', n_ref);
end;
$$;

revoke all on function public.decline_challenge(uuid) from public, anon;
revoke all on function public.request_challenge_cancel(uuid) from public, anon;
grant execute on function public.decline_challenge(uuid) to authenticated;
grant execute on function public.request_challenge_cancel(uuid) to authenticated;
