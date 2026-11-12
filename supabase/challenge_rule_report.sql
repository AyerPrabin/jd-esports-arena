-- challenge_rule_report.sql (12 Nov 2026). The owner asked for a "broke the note rule" button and a report after the
-- game, so a player who breaks the challenge note (e.g. "no Oscar") is not paid. Case that started it: d3bf16b3.
--
--   * Before the payout (the other side said "won", 10-minute window): the loser taps "They broke the rule" with a
--     reason instead of "We lost". The challenge goes to a mod (status disputed), so the 10-minute auto-win stops.
--   * After the payout: the losing side can still report, for 2 hours after the result. The winnings are taken
--     back from the winner's wallet and held while a mod checks. If the winner has already spent them, nothing is
--     held and the mod is told.
--   * Mod decides (mod panel / admin): "Rule broken" = both stakes back + a warning to the rule breaker (no ban);
--     "Result stands" = the held winnings go back to the winner; or pick a winner / refund as before.
--   * No mod decision within 24 hours: the reported winner is paid (a report alone never wins money).
--   * One report per challenge. False reports: the 2nd rejected one in 30 days = 2-day challenge lock (a strike).
--   * Also: the lobby shows each creator's profile picture (get_open_challenges returns creator; can_see_avatar).
-- Run: npx supabase db query --remote --yes -f supabase/challenge_rule_report.sql
-- Undo: drop function public.report_rule_break(uuid, text); re-run admin_resolve_challenge and challenge_sweep from
--       the definitions saved before this file (scratchpad livefns.sql / challenge_result_shots.sql); the columns can stay.
begin;

-- challenge number for reference (#C-1043): numbered in creation order, unique, never reused
alter table public.challenges add column if not exists ref_no bigint;
create sequence if not exists public.challenges_ref_no_seq;
update public.challenges c set ref_no = x.n + 1000
  from (select id, row_number() over (order by created_at, id) n from public.challenges) x
 where x.id = c.id and c.ref_no is null;
select setval('public.challenges_ref_no_seq', greatest(1000, (select coalesce(max(ref_no), 1000) from public.challenges)));
alter table public.challenges alter column ref_no set default nextval('public.challenges_ref_no_seq');
alter sequence public.challenges_ref_no_seq owned by public.challenges.ref_no;
create unique index if not exists challenges_ref_no on public.challenges(ref_no);

alter table public.challenges
  add column if not exists rule_by uuid references public.players(id),
  add column if not exists rule_reason text,
  add column if not exists rule_at timestamptz,
  add column if not exists rule_winner uuid,        -- who had won (or said "won") when the report came in
  add column if not exists rule_held int,           -- winnings taken back while a mod checks (0 = none held)
  add column if not exists rule_done_at timestamptz,
  add column if not exists rule_rejected boolean not null default false;   -- a mod found no proof

create or replace function public.report_rule_break(p_id uuid, p_reason text)
returns text language plpgsql security definer set search_path = public as $$
declare c public.challenges; v_mine text; v_theirs text; v_win uuid; v_pot int; v_held int := 0;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  p_reason := btrim(regexp_replace(coalesce(p_reason, ''), '\s+', ' ', 'g'));
  if length(p_reason) < 5 or length(p_reason) > 300 then
    raise exception 'Write which rule was broken (for example: used Oscar, the note said no Oscar).';
  end if;
  select * into c from public.challenges where id = p_id for update;
  if c.id is null or c.opponent is null or auth.uid() not in (c.creator, c.opponent) then
    raise exception 'Challenge not found.';
  end if;
  if c.rule_at is not null then raise exception 'A rule report was already sent for this challenge.'; end if;
  v_mine := case when auth.uid() = c.creator then c.creator_claim else c.opponent_claim end;
  v_theirs := case when auth.uid() = c.creator then c.opponent_claim else c.creator_claim end;

  if c.status = 'accepted' then
    if v_mine is not null then raise exception 'You already reported this result.'; end if;
    v_win := case when v_theirs = 'won' then (case when auth.uid() = c.creator then c.opponent else c.creator end) end;
    update public.challenges set status = 'disputed', rule_by = auth.uid(), rule_reason = p_reason, rule_at = now(),
      rule_winner = v_win, rule_held = 0, resolution = 'rule report - a JD mod checks'
     where id = p_id;
  elsif c.status = 'completed' then
    if c.winner = auth.uid() then raise exception 'Only the side that lost can report a rule break.'; end if;
    if c.resolved_at < now() - interval '2 hours' then
      raise exception 'Rule reports close 2 hours after the result. Message JD support with your proof.';
    end if;
    select delta into v_pot from public.wallet_ledger
     where reason = 'challenge_win' and ref = c.id::text and player_id = c.winner order by created_at desc limit 1;
    if coalesce(v_pot, 0) > 0 then
      begin
        perform public._wallet_apply(c.winner, -v_pot, 'adjust', c.id::text, c.mode || ' challenge winnings held: rule report');
        v_held := v_pot;
      exception when others then v_held := 0;   -- already spent: nothing held, the mod is told
      end;
    end if;
    if v_held > 0 then
      update public.challenges set status = 'disputed', winner = null, rule_by = auth.uid(), rule_reason = p_reason,
        rule_at = now(), rule_winner = c.winner, rule_held = v_held, resolution = 'rule report - winnings held while a JD mod checks'
       where id = p_id;
      insert into public.notifications (player_id, title, body) values (c.winner, '⚠️ Challenge winnings on hold',
        public._challenge_name(auth.uid()) || ' reports that a challenge rule was broken: "' || p_reason || '". Your ' || v_held
        || ' points are on hold while a JD mod checks. Send your proof in the challenge chat.');
    else
      update public.challenges set rule_by = auth.uid(), rule_reason = p_reason, rule_at = now(), rule_winner = c.winner, rule_held = 0
       where id = p_id;
    end if;
  else
    raise exception 'This challenge can''t be reported now.';
  end if;

  perform public._challenge_tell_staff('🚩 Challenge rule report',
    public._challenge_name(auth.uid()) || ' says ' || public._challenge_name(case when auth.uid() = c.creator then c.opponent else c.creator end)
    || ' broke a rule in ' || c.mode || ' challenge #C-' || c.ref_no || ' (' || c.stake * 2 || ' pts): "' || p_reason || '"'
    || case when c.note is not null then ' Note: "' || c.note || '".' else '' end
    || case when c.status = 'completed' and v_held = 0 then ' Winnings already spent, nothing held.' else '' end
    || ' Decide in Mod panel → Challenges.');
  if c.status = 'accepted' then
    insert into public.notifications (player_id, title, body)
    select x, 'Challenge under review', 'A rule break was reported ("' || p_reason || '"), so a JD mod decides. Send your proof in the challenge chat.'
      from unnest(array[c.creator, c.opponent]) x;
  end if;
  return case when c.status = 'accepted' then 'review' when v_held > 0 then 'held' else 'reported' end;
end;
$$;
revoke all on function public.report_rule_break(uuid, text) from public, anon;
grant execute on function public.report_rule_break(uuid, text) to authenticated;

create or replace function public.admin_resolve_challenge(p_id uuid, p_outcome text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.challenges; v_accused uuid; v_pot int; v_n int; v_strikes int;
begin
  select * into c from public.challenges where id = p_id for update;
  if c.id is null then raise exception 'Challenge not found.'; end if;
  if p_outcome in ('rule_void', 'rule_reject') and (c.rule_at is null or c.rule_done_at is not null) then
    raise exception 'This challenge has no open rule report.';
  end if;
  if p_outcome in ('creator', 'opponent', 'refund') and c.status <> 'disputed' then
    raise exception 'This challenge is not waiting for a decision.';
  end if;
  if p_outcome = 'creator' then perform public._challenge_payout(p_id, c.creator, 'decided by admin');
  elsif p_outcome = 'opponent' then perform public._challenge_payout(p_id, c.opponent, 'decided by admin');
  elsif p_outcome = 'refund' then perform public._challenge_refund(p_id, 'refunded', 'refunded by admin');
  elsif p_outcome = 'rule_void' then
    v_accused := case when c.rule_by = c.creator then c.opponent else c.creator end;
    if c.status = 'completed' then   -- winnings were not held: take them back now
      select delta into v_pot from public.wallet_ledger
       where reason = 'challenge_win' and ref = c.id::text and player_id = c.winner order by created_at desc limit 1;
      begin
        perform public._wallet_apply(c.winner, -v_pot, 'adjust', c.id::text, c.mode || ' challenge voided: rule broken');
      exception when others then
        raise exception 'The winner no longer has the % points, so they can''t be taken back automatically. Ask the owner.', v_pot;
      end;
      update public.challenges set status = 'disputed', winner = null where id = p_id;
    end if;
    perform public._challenge_refund(p_id, 'refunded', 'voided by JD: a challenge rule was broken - both stakes refunded');
    insert into public.notifications (player_id, title, body) values (v_accused, '⚠️ Warning: challenge rule broken',
      'A JD mod checked your ' || c.mode || ' challenge #C-' || c.ref_no || ' against ' || public._challenge_name(c.rule_by) || ': the rule was broken ("'
      || c.rule_reason || '"). The win is cancelled and both stakes are refunded. Always follow the challenge note. Breaking it again can get you banned from challenges.');
  elsif p_outcome = 'rule_reject' then
    if c.status = 'disputed' then
      if c.rule_winner is null then raise exception 'Nobody had reported a win yet: pick who won, or refund both.'; end if;
      perform public._challenge_payout(p_id, c.rule_winner, 'rule report checked by JD - the result stands');
    end if;
    update public.challenges set rule_rejected = true where id = p_id;
    -- false or pointless rule reports: the 2nd rejected one in 30 days locks challenges for 2 days (like a false result)
    select count(*) into v_n from public.challenges
     where rule_by = c.rule_by and rule_rejected and rule_at > now() - interval '30 days';
    if v_n >= 2 then
      insert into public.challenge_bans (player_id, until, strikes, last_challenge)
      values (c.rule_by, now() + interval '2 days', 1, c.id)
      on conflict (player_id) do update set until = greatest(challenge_bans.until, now() + interval '2 days'),
        strikes = challenge_bans.strikes + 1, last_challenge = c.id, updated_at = now()
      returning strikes into v_strikes;
      insert into public.notifications (player_id, title, body) values (c.rule_by, '⚠️ Challenges locked: false reports',
        'A JD mod found no proof in your rule report ("' || c.rule_reason || '"), and it is your ' || v_n
        || ' rejected report in 30 days. Challenges are locked for 2 days. More false reports can get you blacklisted and banned from challenges.');
      if v_strikes >= 3 then
        perform public._challenge_tell_staff('🚩 Repeat false challenge reports',
          public._challenge_name(c.rule_by) || ' has ' || v_strikes || ' challenge strikes (false results / false reports). Consider a ban.');
      end if;
    else
      insert into public.notifications (player_id, title, body) values (c.rule_by, '⚠️ Rule report: no proof found',
        'A JD mod checked your report ("' || c.rule_reason || '") and found no proof of a broken rule, so the result stands. '
        || 'Report only real rule breaks with proof: false or pointless reports can get you blacklisted and banned from challenges.');
    end if;
  else raise exception 'Outcome must be creator, opponent, refund, rule_void or rule_reject.';
  end if;
  update public.challenges set rule_done_at = now() where id = p_id and rule_at is not null and rule_done_at is null;
end;
$$;
revoke all on function public.admin_resolve_challenge(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_resolve_challenge(uuid, text) to service_role;

-- challenge_sweep: same as live, except the 12-hour nudge and the 24-hour limit count from a rule report, and an
-- undecided rule report pays the reported winner (a report alone never wins money); one with no winner refunds both.
create or replace function public.challenge_sweep()
returns jsonb language plpgsql security definer set search_path = public as $function$
declare r record; n_exp int := 0; n_review int := 0; n_ref int := 0; n_stuck int := 0; n_auto int := 0;
begin
  if exists(select 1 from public.system_state where id = 1 and locked) then
    return jsonb_build_object('skipped', 'locked');
  end if;
  for r in select id from public.challenges where status = 'open' and created_at < now() - interval '2 hours' loop
    perform public._challenge_refund(r.id, 'expired', 'nobody accepted within 2 hours'); n_exp := n_exp + 1;
  end loop;
  for r in select id, case when creator_claim = 'won' then creator else opponent end as winner from public.challenges
           where status = 'accepted' and claim_at < now() - interval '10 minutes'
             and claim_at >= accepted_at + interval '10 minutes'
             and ((creator_claim = 'won' and creator_shot is not null and opponent_claim is null)
               or (opponent_claim = 'won' and opponent_shot is not null and creator_claim is null))
           for update loop
    perform public._challenge_payout(r.id, r.winner, 'no answer within 10 minutes - the reported win with its screenshot stands');
    n_auto := n_auto + 1;
  end loop;
  for r in select id, creator, opponent, mode, stake from public.challenges
           where status = 'accepted' and claim_at < now() - interval '2 hours'
             and ((creator_claim = 'won' and opponent_claim is null) or (opponent_claim = 'won' and creator_claim is null))
           for update loop
    update public.challenges set status = 'disputed', resolution = 'no answer within 2 hours - a mod decides'
     where id = r.id;
    perform public._challenge_tell_staff('⚖️ Challenge needs a decision',
      'A ' || r.mode || ' challenge (' || r.stake * 2 || ' pts): one side says they won, the other never answered. '
      || 'Check the chat and screenshots in Mod panel → Challenges.');
    insert into public.notifications (player_id, title, body) values
      (r.creator, 'Challenge under review', 'No answer to the result within 2 hours, so a JD mod will decide. Share your result screenshot in the challenge chat.'),
      (r.opponent, 'Challenge under review', 'No answer to the result within 2 hours, so a JD mod will decide. Share your result screenshot in the challenge chat.');
    n_review := n_review + 1;
  end loop;
  for r in select id, mode, stake from public.challenges
           where status = 'disputed' and review_nudged_at is null and coalesce(rule_at, claim_at, accepted_at) < now() - interval '12 hours' loop
    update public.challenges set review_nudged_at = now() where id = r.id;
    perform public._challenge_tell_staff('⏰ Challenge still waiting for a mod',
      'A ' || r.mode || ' challenge (' || r.stake * 2 || ' pts) has waited 12 hours. Decide it in Mod panel → Challenges, or it is settled automatically at 24 hours.');
  end loop;
  for r in select id, rule_at, rule_winner from public.challenges
           where status = 'disputed' and coalesce(rule_at, claim_at, accepted_at) < now() - interval '24 hours' loop
    if r.rule_at is not null and r.rule_winner is not null then
      perform public._challenge_payout(r.id, r.rule_winner, 'rule report not decided within 24 hours - the result stands');
      update public.challenges set rule_done_at = now() where id = r.id;
    else
      perform public._challenge_refund(r.id, 'refunded', 'no mod decision within 24 hours - both stakes refunded');
      update public.challenges set rule_done_at = now() where id = r.id and rule_at is not null;
    end if;
    n_stuck := n_stuck + 1;
  end loop;
  for r in select id from public.challenges where status = 'accepted' and claim_at is null and accepted_at < now() - interval '3 hours' loop
    perform public._challenge_refund(r.id, 'refunded', 'no result reported within 3 hours'); n_ref := n_ref + 1;
  end loop;
  return jsonb_build_object('auto_won', n_auto, 'expired', n_exp, 'to_review', n_review, 'refunded', n_ref, 'undecided_refunded', n_stuck);
end;
$function$;
-- lobby: the creator's id (for their profile picture on the card) ...
drop function if exists public.get_open_challenges();
create function public.get_open_challenges()
returns table(id uuid, mode text, stake integer, note text, creator_name text, created_at timestamptz, for_me boolean, mine boolean,
              creator_effect text, char_skill boolean, gun_attr boolean, ammo text, rounds integer, map text, gloo_wall text, creator uuid, ref_no bigint)
language sql stable security definer set search_path = public as $$
  select c.id, c.mode, c.stake, c.note, public._display_name(c.creator), c.created_at,
         c.invited is not null and c.invited = auth.uid(), c.creator = auth.uid(), public._active_effect(c.creator),
         c.char_skill, c.gun_attr, c.ammo, c.rounds, c.map, c.gloo_wall, c.creator, c.ref_no
  from public.challenges c
  where c.status = 'open' and (c.invited is null or c.invited = auth.uid() or c.creator = auth.uid())
  order by (c.invited = auth.uid()) desc nulls last, c.created_at desc
  limit 60
$$;
revoke all on function public.get_open_challenges() from public, anon;
grant execute on function public.get_open_challenges() to authenticated;

-- ... and the picture itself: signed-in players may see the profile picture of someone with an open challenge they
-- can accept (same rule as the lobby). Everything else in can_see_avatar is unchanged.
create or replace function public.can_see_avatar(p_folder text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v uuid; v_me uuid := auth.uid();
begin
  if v_me is null then return false; end if;
  begin v := p_folder::uuid; exception when others then return false; end;
  if v = v_me then return true; end if;
  if public._blocked_either(v_me, v) then return false; end if;
  return exists(select 1 from public.friendships f
                 where least(f.requester, f.addressee) = least(v_me, v) and greatest(f.requester, f.addressee) = greatest(v_me, v))
      or exists(select 1 from public.chat_group_members a join public.chat_group_members b on b.group_id = a.group_id
                 where a.player_id = v_me and b.player_id = v)
      or exists(select 1 from public.challenges c
                 where (c.creator = v_me and c.opponent = v) or (c.creator = v and c.opponent = v_me))
      or exists(select 1 from public.challenges c
                 where c.creator = v and c.status = 'open' and (c.invited is null or c.invited = v_me));
end;
$$;
revoke all on function public.can_see_avatar(text) from public, anon;
grant execute on function public.can_see_avatar(text) to authenticated;
commit;
