-- Public "paid to players" numbers (2026-11-02) for the home stats strip and /about/.
-- Totals only (no names, no single payouts), so anyone may read them. Safe to run again.
begin;
create or replace function public.payout_stats()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'prizes', coalesce((select sum(delta) from public.wallet_ledger where reason = 'prize'), 0),
    'prize_count', (select count(*) from public.wallet_ledger where reason = 'prize'),
    'withdrawn', coalesce((select sum(coalesce(payout, amount)) from public.withdraw_requests where status = 'paid'), 0),
    'withdraw_count', (select count(*) from public.withdraw_requests where status = 'paid'))
$$;
revoke all on function public.payout_stats() from public;
grant execute on function public.payout_stats() to anon, authenticated;
commit;
