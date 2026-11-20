-- 2026-11-18 owner's go: player_56155037 (JD-PP58M) paid Rs 50 by eSewa on 17 Nov 10:16 UTC (sender "Kiran"),
-- but eSewa refused the "_" in the remark so no load request was filed. Credit 50 points once and mark that
-- eSewa payment as used. Safe to re-run: keyed by the payment's ref.
begin;
create temp table k50 on commit drop as
  select p.id pay_id, pl.id player_id from public.payments_in p, public.players pl
   where pl.id = '56155037-944d-4e01-b1d9-8c365b21ecf7' and p.provider = 'esewa' and p.amount = 50
     and p.load_id is null and p.received_at between '2026-11-17 10:15' and '2026-11-17 10:18';
select public._wallet_apply(player_id, 50, 'load', 'esewa:' || pay_id::text, 'eSewa Rs 50 on 17 Nov (remark refused "_"), added by JD')
  from k50 where not exists (select 1 from public.wallet_ledger w where w.reason = 'load' and w.ref = 'esewa:' || k50.pay_id::text);
update public.payments_in set matched_by = 'owner-manual', matched_at = now() where id in (select pay_id from k50) and matched_at is null;
insert into public.notifications (player_id, title, body, push)
  select player_id, '💰 +50 JD points added',
    'Your Rs 50 eSewa payment from 17 Nov is now 50 points in your wallet. Sorry for the wait!' || chr(10) ||
    'Tapaiko 17 Nov ko Rs 50 eSewa payment aba wallet ma 50 point bhayo. Dhilo bhayo, maaf garnus!', true
  from k50 where not exists (select 1 from public.notifications n where n.player_id = k50.player_id and n.title = '💰 +50 JD points added');
select (select count(*) from k50) payment_found, w.balance from public.wallets w where w.player_id = '56155037-944d-4e01-b1d9-8c365b21ecf7';
commit;
