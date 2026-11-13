-- challenge_mod_bans.sql (12 Nov 2026, owner: "not only ban, temporary ban, many options").
-- When a mod rules a challenge "Rule broken" they pick the punishment for the rule breaker: a warning, a 1 / 3 / 7 / 30
-- day challenge lock, or a permanent challenge ban (challenges only; the account still works). A mod lock can't be
-- lifted with the 5-point unlock; automatic locks (false results / false reports) still can.
-- 13 Nov: the mod also picks a fine of 0-20 points (10 by default) that moves from the rule breaker to the reporter
-- (if the rule breaker has less, what they have is taken).
-- Run: npx supabase db query --remote --yes -f supabase/challenge_mod_bans.sql
-- Undo: drop function public.admin_resolve_challenge(uuid, text, int, int); re-run admin_resolve_challenge from
--       challenge_rule_report.sql, and challenge_unlock_pay / _challenge_player_ok from their earlier definitions.
begin;
alter table public.challenge_bans add column if not exists mod_until timestamptz, add column if not exists mod_reason text;

drop function if exists public.admin_resolve_challenge(uuid, text);
drop function if exists public.admin_resolve_challenge(uuid, text, int);
create or replace function public.admin_resolve_challenge(p_id uuid, p_outcome text, p_lock_days int default 0, p_fine int default 0)
returns void language plpgsql security definer set search_path = public as $$
declare c public.challenges; v_accused uuid; v_pot int; v_n int; v_strikes int; v_until timestamptz; v_pun text; v_fine int := 0;
begin
  if p_lock_days is null or p_lock_days not in (-1, 0, 1, 3, 7, 30) then
    raise exception 'Punishment must be a warning, 1, 3, 7 or 30 days, or a permanent challenge ban.';
  end if;
  if p_fine is null or p_fine not between 0 and 20 then raise exception 'The fine must be 0 to 20 points.'; end if;
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
    -- the mod's punishment: 0 = warning, 1/3/7/30 = challenge lock in days, -1 = permanent challenge ban.
    -- A mod lock can't be lifted with the 5-point unlock.
    if p_lock_days <> 0 then
      v_until := case when p_lock_days = -1 then 'infinity'::timestamptz else now() + make_interval(days => p_lock_days) end;
      insert into public.challenge_bans (player_id, until, strikes, last_challenge, mod_until, mod_reason)
      values (v_accused, v_until, 1, c.id, v_until, c.rule_reason)
      on conflict (player_id) do update set until = greatest(challenge_bans.until, v_until),
        mod_until = greatest(coalesce(challenge_bans.mod_until, '-infinity'), v_until), mod_reason = c.rule_reason,
        strikes = challenge_bans.strikes + 1, last_challenge = c.id, updated_at = now();
    end if;
    -- the mod's fine (0-20 points) goes from the rule breaker to the reporter; less if the rule breaker has less
    if p_fine > 0 then
      select least(p_fine, greatest(balance, 0)) into v_fine from public.wallets where player_id = v_accused;
      v_fine := coalesce(v_fine, 0);
      if v_fine > 0 then
        perform public._wallet_apply(v_accused, -v_fine, 'adjust', c.id::text, 'Fine: broke the rule in ' || c.mode || ' challenge #C-' || c.ref_no);
        perform public._wallet_apply(c.rule_by, v_fine, 'adjust', c.id::text, 'Fine paid to you: rule broken in ' || c.mode || ' challenge #C-' || c.ref_no);
        insert into public.notifications (player_id, title, body) values (c.rule_by, '✅ Rule report upheld',
          'A JD mod agreed the rule was broken in ' || c.mode || ' challenge #C-' || c.ref_no || '. Your stake is refunded and '
          || public._challenge_name(v_accused) || ' paid you a ' || v_fine || '-point fine.');
      end if;
    end if;
    v_pun := case p_lock_days when 0 then 'This is a warning. Breaking a rule again can get you banned from challenges.'
      when -1 then 'You are banned from challenges.'
      else 'Your challenges are locked for ' || p_lock_days || ' day' || case when p_lock_days = 1 then '' else 's' end || '.' end;
    insert into public.notifications (player_id, title, body) values (v_accused,
      case p_lock_days when 0 then '⚠️ Warning: challenge rule broken' when -1 then '⛔ Banned from challenges' else '⛔ Challenges locked: rule broken' end,
      'A JD mod checked your ' || c.mode || ' challenge #C-' || c.ref_no || ' against ' || public._challenge_name(c.rule_by) || ': the rule was broken ("'
      || c.rule_reason || '"). The win is cancelled and both stakes are refunded. '
      || case when v_fine > 0 then 'You are fined ' || v_fine || ' points, paid to ' || public._challenge_name(c.rule_by) || '. ' else '' end || v_pun);
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
revoke all on function public.admin_resolve_challenge(uuid, text, int, int) from public, anon, authenticated;
grant execute on function public.admin_resolve_challenge(uuid, text, int, int) to service_role;

create or replace function public.challenge_unlock_pay()
returns integer language plpgsql security definer set search_path = public as $$
declare v_bal int;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform 1 from public.challenge_bans where player_id = auth.uid() and until > now() for update;
  if not found then raise exception 'Your challenges are not locked.'; end if;
  if exists(select 1 from public.challenge_bans where player_id = auth.uid() and mod_until > now()) then
    raise exception 'A JD mod locked your challenges for breaking a rule, so this lock can''t be lifted with points.';
  end if;
  v_bal := public._wallet_apply(auth.uid(), -5, 'adjust', 'challenge_unlock', 'Challenge lock lifted early (5 points)');
  update public.challenge_bans set until = now(), updated_at = now() where player_id = auth.uid();
  return v_bal;
end;
$$;
revoke all on function public.challenge_unlock_pay() from public, anon;
grant execute on function public.challenge_unlock_pay() to authenticated;

create or replace function public._challenge_player_ok(p_player uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_until timestamptz; v_mod timestamptz;
begin
  if (select adult_confirmed_at from public.players where id = p_player) is null then
    raise exception 'Challenges are 18+. Please confirm your age first.';
  end if;
  if exists(select 1 from public.banned_players where player_id = p_player) then
    raise exception 'Your account is banned.';
  end if;
  if exists(select 1 from public.players where id = p_player and (coalesce(trim(ff_uid), '') = '' or coalesce(trim(ff_name), '') = '')) then
    raise exception 'Save your Free Fire UID and in-game name first (Profile > Free Fire ID card at the top). Challenges need them so results can be checked.';
  end if;
  select until, mod_until into v_until, v_mod from public.challenge_bans where player_id = p_player and until > now();
  if v_mod = 'infinity' then
    raise exception 'You are banned from challenges for breaking a challenge rule. Contact JD support if you think this is wrong.';
  elsif v_mod > now() then
    raise exception 'A JD mod locked your challenges until % (Nepal time) for breaking a challenge rule.',
      to_char(v_mod at time zone 'Asia/Kathmandu', 'DD Mon HH24:MI');
  elsif v_until is not null then
    raise exception 'Challenges are locked until % (Nepal time) after a false result. Pay 5 points on the Challenges page to play now.',
      to_char(v_until at time zone 'Asia/Kathmandu', 'DD Mon HH24:MI');
  end if;
  if exists(select 1 from public.wallets where player_id = p_player and unlimited) then
    raise exception 'The admin wallet can''t be used for challenges.';
  end if;
  if exists(select 1 from public.wallets where player_id = p_player and staff) then
    raise exception 'Staff wallets can''t be used for challenges: their points are for JD Arena spending only.';
  end if;
end;
$$;
commit;
