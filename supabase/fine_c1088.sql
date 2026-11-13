-- fine_c1088.sql (13 Nov 2026, owner: "charge the rule breaker"). Challenge #C-1088 (2v2, note "Desert eagle m1887 only,
-- no Oscar") was ruled "Rule broken" by a mod at 13:53 UTC. Kanxa661 pays a 10-point fine to the reporter player_c923656c.
-- Safe to run twice: it does nothing if the fine is already in the ledger.
-- Run: npx supabase db query --remote --yes -f supabase/fine_c1088.sql
-- Undo: the same two _wallet_apply calls with the signs swapped.
do $$
declare c public.challenges; v_acc uuid;
begin
  select * into c from public.challenges where ref_no = 1088 and rule_done_at is not null and status = 'refunded';
  if c.id is null then raise exception '#C-1088 is not a decided rule report.'; end if;
  if exists (select 1 from public.wallet_ledger where ref = c.id::text and note like 'Fine:%') then
    raise notice 'Fine already taken, nothing done.'; return;
  end if;
  v_acc := case when c.rule_by = c.creator then c.opponent else c.creator end;
  perform public._wallet_apply(v_acc, -10, 'adjust', c.id::text, 'Fine: broke the rule in ' || c.mode || ' challenge #C-' || c.ref_no);
  perform public._wallet_apply(c.rule_by, 10, 'adjust', c.id::text, 'Fine paid to you: rule broken in ' || c.mode || ' challenge #C-' || c.ref_no);
  insert into public.notifications (player_id, title, body) values
    (v_acc, '⚠️ Fined 10 points: challenge rule broken', 'A JD mod found you broke the rule in ' || c.mode || ' challenge #C-' || c.ref_no
      || ' ("' || c.rule_reason || '"). You are fined 10 points, paid to ' || public._challenge_name(c.rule_by) || '. Always follow the challenge note.'),
    (c.rule_by, '✅ Rule report upheld', 'You got a 10-point fine from ' || public._challenge_name(v_acc) || ' for the broken rule in challenge #C-' || c.ref_no || '.');
end $$;
select p.username, w.balance from public.players p join public.wallets w on w.player_id = p.id where p.username in ('Kanxa661', 'player_c923656c');
