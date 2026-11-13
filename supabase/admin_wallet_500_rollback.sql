-- Undo admin_wallet_500.sql: the owner's wallet goes back to unlimited (100B).
-- The two 'adjust' ledger rows stay (the ledger can't be edited); with unlimited on, the
-- owner's rows are left out of the money totals and the security sweep again.
begin;
update public.wallets w set unlimited = true, stats_from = null
  from public.players p
 where p.id = w.player_id and p.username = 'ayerprabin';
commit;
