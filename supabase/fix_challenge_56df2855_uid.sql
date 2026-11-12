-- 12 Nov 2026, owner decision: challenge 56df2855 (#C-1069, player_c923656c vs Kanxa661, 55 each) is refunded.
-- player_c923656c's win screenshot was sent as FF "Drift z10" UID 6677055922; the account's saved FF ID is
-- "MOON BEAK" UID 2708194692 (different name and UID while playing). The 108-point win is taken back and both get
-- their 55 stake back. No warning (owner asked for a refund only). Runs once only.
-- Net: player_c923656c -53, Kanxa661 +55.
-- Run: npx supabase db query --remote --yes -f supabase/fix_challenge_56df2855_uid.sql
do $$
declare
  v_id uuid := '56df2855-a87d-48b2-bb72-7a070c8fd447';
  v_kanxa uuid := '872b9c11-a917-400b-b24d-a6a85c6598a5';
  c public.challenges;
begin
  select * into c from public.challenges where id = v_id for update;
  if c.status <> 'completed' or c.winner is distinct from c.creator or c.opponent <> v_kanxa then
    raise exception 'Challenge is not in the expected state (already fixed?): % / %', c.status, c.winner;
  end if;
  if exists(select 1 from public.wallet_ledger where ref = v_id::text and reason in ('challenge_refund','adjust')) then
    raise exception 'Already refunded.';
  end if;

  perform public._wallet_apply(c.creator, -108, 'adjust', v_id::text, '2v2 challenge #C-' || c.ref_no || ' refunded: FF name/UID did not match the account');
  perform public._wallet_apply(c.creator, 55, 'challenge_refund', v_id::text, '2v2 challenge refunded: stake back');
  perform public._wallet_apply(v_kanxa, 55, 'challenge_refund', v_id::text, '2v2 challenge refunded: stake back');

  update public.challenges
     set status = 'refunded', winner = null, resolved_at = now(),
         resolution = 'refunded by JD: the winner''s Free Fire name and UID did not match their account'
   where id = v_id;

  insert into public.notifications (player_id, title, body) values
    (v_kanxa, '↩️ Challenge refunded: +55 JD points',
     'Challenge #C-' || c.ref_no || ' against @player_c923656c is refunded: the Free Fire name and UID on their win did not match their account. Your 55 points are back.'),
    (c.creator, 'Challenge refunded',
     'Challenge #C-' || c.ref_no || ' against @Kanxa661 is refunded because the Free Fire name and UID on your win (Drift z10) did not match your saved account. The 108-point win was taken back and your 55-point stake returned (net -53). Always play with the Free Fire ID saved on your profile.');
end $$;

select (select username from public.players where id = l.player_id) who, l.delta, l.balance_after, l.reason
from public.wallet_ledger l where l.ref = '56df2855-a87d-48b2-bb72-7a070c8fd447' order by l.created_at;
