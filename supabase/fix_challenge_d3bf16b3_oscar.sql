-- 12 Nov 2026, owner decision: challenge d3bf16b3 (jilani01 vs Kanxa661, 38 each, note "Oscar not use").
-- Kanxa661 used Oscar against the note. The game is voided: the 74-point win is taken back and both players get
-- their 38 stake back. Kanxa661 gets a warning message (no challenge ban). Runs once only.
-- Net: Kanxa661 -36, jilani01 +38.
-- Run: npx supabase db query --remote --yes -f supabase/fix_challenge_d3bf16b3_oscar.sql
do $$
declare
  v_id uuid := 'd3bf16b3-3206-4c4e-8ddd-a16de00b5483';
  v_kanxa uuid := '872b9c11-a917-400b-b24d-a6a85c6598a5';
  v_jilani uuid := 'c561de11-c935-4142-b3f0-3200e909bcfb';
  c public.challenges;
begin
  select * into c from public.challenges where id = v_id for update;
  if c.status <> 'completed' or c.winner is distinct from v_kanxa then
    raise exception 'Challenge is not in the expected state (already fixed?): % / %', c.status, c.winner;
  end if;
  if exists(select 1 from public.wallet_ledger where ref = v_id::text and reason in ('challenge_refund','adjust')) then
    raise exception 'Already refunded.';
  end if;

  perform public._wallet_apply(v_kanxa, -74, 'adjust', v_id::text, '2v2 challenge voided: Oscar used, note said no Oscar');
  perform public._wallet_apply(v_kanxa, 38, 'challenge_refund', v_id::text, '2v2 challenge voided: stake back');
  perform public._wallet_apply(v_jilani, 38, 'challenge_refund', v_id::text, '2v2 challenge voided: stake back');

  update public.challenges
     set status = 'cancelled', winner = null,
         resolution = 'voided by JD: the note said no Oscar and Oscar was used - both stakes refunded', resolved_at = now()
   where id = v_id;

  insert into public.notifications (player_id, title, body) values
    (v_jilani, '↩️ Challenge refunded: +38 JD points',
     'Your 2v2 challenge against @Kanxa661 is cancelled because the note said no Oscar and Oscar was used. Your 38 points are back in your wallet.'),
    (v_kanxa, '⚠️ Warning: challenge note broken',
     'Your 2v2 challenge against @jilani01 is cancelled: the note said no Oscar and you used Oscar. The 74-point win was taken back and your 38-point stake refunded (net -36). Always follow the challenge note. Breaking it again can get you banned from challenges.');
end $$;

select (select username from public.players where id = l.player_id) who, l.delta, l.balance_after, l.reason
from public.wallet_ledger l where l.ref = 'd3bf16b3-3206-4c4e-8ddd-a16de00b5483' order by l.created_at;
