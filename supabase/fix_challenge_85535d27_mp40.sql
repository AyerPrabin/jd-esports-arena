-- 12 Nov 2026, owner decision: challenge 85535d27 (player_c923656c vs Kanxa661, 95 each, note "Desert m1887 ump only")
-- is voided: player_c923656c reported (WhatsApp) that Kanxa661 used an MP40. The 188-point win is taken back and both
-- get their 95 stake back; Kanxa661 gets a warning (no ban). Runs once only.
-- Net: Kanxa661 -93, player_c923656c +95.
-- Run: npx supabase db query --remote --yes -f supabase/fix_challenge_85535d27_mp40.sql
do $$
declare
  v_id uuid := '85535d27-e7a7-431e-9588-334524cf7c94';
  v_kanxa uuid := '872b9c11-a917-400b-b24d-a6a85c6598a5';
  c public.challenges;
begin
  select * into c from public.challenges where id = v_id for update;
  if c.status <> 'completed' or c.winner is distinct from v_kanxa then
    raise exception 'Challenge is not in the expected state (already fixed?): % / %', c.status, c.winner;
  end if;
  if exists(select 1 from public.wallet_ledger where ref = v_id::text and reason in ('challenge_refund','adjust')) then
    raise exception 'Already refunded.';
  end if;

  perform public._wallet_apply(v_kanxa, -188, 'adjust', v_id::text, '2v2 challenge #C-' || c.ref_no || ' voided: MP40 used, note said Desert/M1887/UMP only');
  perform public._wallet_apply(v_kanxa, 95, 'challenge_refund', v_id::text, '2v2 challenge voided: stake back');
  perform public._wallet_apply(c.creator, 95, 'challenge_refund', v_id::text, '2v2 challenge voided: stake back');

  update public.challenges
     set status = 'refunded', winner = null, resolved_at = now(),
         resolution = 'voided by JD: the note said Desert Eagle, M1887 and UMP only and an MP40 was used - both stakes refunded'
   where id = v_id;

  insert into public.notifications (player_id, title, body) values
    (c.creator, '↩️ Challenge refunded: +95 JD points',
     'Challenge #C-' || c.ref_no || ' against @Kanxa661 is cancelled: the note said Desert Eagle, M1887 and UMP only and an MP40 was used. Your 95 points are back.'),
    (v_kanxa, '⚠️ Warning: challenge note broken again',
     'Challenge #C-' || c.ref_no || ' against @player_c923656c is cancelled: the note said Desert Eagle, M1887 and UMP only and you used an MP40. The 188-point win was taken back and your 95-point stake refunded (net -93). This is your second broken note today. Next time your challenges will be locked or banned.');
end $$;

select (select username from public.players where id = l.player_id) who, l.delta, l.balance_after, l.reason
from public.wallet_ledger l where l.ref = '85535d27-e7a7-431e-9588-334524cf7c94' order by l.created_at;
