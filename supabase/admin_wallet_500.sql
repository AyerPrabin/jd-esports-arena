-- Owner's admin wallet: from "unlimited" (shown as 100B) to a real 500-point balance (13 Nov 2026).
-- After this the admin wallet works like any player's: events, effects, challenges, teammate pay.
-- Steps (one transaction):
--   1. wallets.stats_from: ledger rows before this time are left out of the money totals,
--      so the old 10,000,000 test load and this reset never show as cash in or comp.
--   2. Reconcile: while unlimited, spending was recorded but never taken from the balance, so
--      the balance is higher than the ledger sum. One 'adjust' row closes that gap (no balance change),
--      which keeps security_sweep's balance = ledger check clean.
--   3. unlimited off, then one 'adjust' row moves the balance to exactly 500.
-- Safe to run twice: it stops if the wallet is already a normal wallet.
-- Undo: admin_wallet_500_rollback.sql
begin;

alter table public.wallets add column if not exists stats_from timestamptz;

create or replace function public._money_window(p_since timestamp with time zone)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with led as (
    select l.reason, l.delta from public.wallet_ledger l
    join public.wallets w on w.player_id = l.player_id and not coalesce(w.unlimited,false) and not w.staff
                         and (w.stats_from is null or l.created_at >= w.stats_from)
    where (p_since is null or l.created_at >= p_since)
  ),
  wd as (
    select status, coalesce(payout, amount) as net, coalesce(fee,0) as fee
    from public.withdraw_requests
    where (p_since is null or created_at >= p_since)
  )
  select jsonb_build_object(
    'cash_in',         (select coalesce(sum(delta),0) from led where reason = 'load'),
    'cash_out_paid',   (select coalesce(sum(net),0)  from wd  where status = 'paid'),
    'pending_payouts', (select coalesce(sum(net),0)  from wd  where status = 'pending'),
    'fees_collected',  (select coalesce(sum(fee),0)  from wd  where status = 'paid'),
    'prize_given',     (select coalesce(sum(delta),0) from led where reason = 'prize'),
    'adjust_given',    (select coalesce(sum(delta),0) from led where reason = 'adjust'),
    'earned_points',   (select coalesce(-sum(delta),0) from led
                         where reason in ('entry','effect','optimizer','challenge_stake','refund','challenge_win','challenge_refund'))
  );
$function$;

do $$
declare v_id uuid; v_n int; v_bal int; v_unl boolean; v_sum int;
begin
  select count(*), min(id::text)::uuid into v_n, v_id from public.players where username = 'ayerprabin';
  if v_n <> 1 then raise exception 'Expected exactly one @ayerprabin account, found %', v_n; end if;

  select balance, unlimited into v_bal, v_unl from public.wallets where player_id = v_id for update;
  if not coalesce(v_unl, false) then
    raise notice 'Admin wallet is already a normal wallet (balance %). Nothing changed.', v_bal;
    return;
  end if;

  select coalesce(sum(delta), 0)::int into v_sum from public.wallet_ledger where player_id = v_id;
  if v_bal <> v_sum then
    insert into public.wallet_ledger (player_id, delta, balance_after, reason, ref, note)
    values (v_id, v_bal - v_sum, v_bal, 'adjust', 'admin500:reconcile',
            'Admin test spending that the unlimited wallet never took from the balance');
  end if;

  update public.wallets set unlimited = false, stats_from = now() + interval '1 millisecond'
   where player_id = v_id;

  perform public._wallet_apply(v_id, 500 - v_bal, 'adjust', 'admin500:set',
                               'Admin wallet changed from unlimited to a real 500 points');
end $$;

commit;

-- Check (should show balance 500, unlimited false, ledger_sum 500):
select p.username, w.balance, w.unlimited, w.stats_from,
       (select sum(delta) from public.wallet_ledger l where l.player_id = w.player_id) as ledger_sum
from public.wallets w join public.players p on p.id = w.player_id where p.username = 'ayerprabin';
