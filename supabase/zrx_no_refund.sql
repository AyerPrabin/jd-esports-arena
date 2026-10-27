-- ── ZRX_FAMILY2: wrongly published as Open #9 winner - no pass refund, points to 0 (owner, 28 Oct 2026) ──
begin;
do $$
declare v_p uuid; v_bal int;
begin
  select id into v_p from public.players where squad_name = 'ZRX_FAMILY2';
  if exists (select 1 from public.wallet_ledger where ref = 'passrefund_reversed:13') then return; end if;
  select balance into v_bal from public.wallets where player_id = v_p;
  if v_bal > 0 then
    perform public._wallet_apply(v_p, -v_bal, 'adjust', 'passrefund_reversed:13',
      'Open #9 result was published wrongly - the pass refund does not apply, points reset to 0');
  end if;
  insert into public.notifications (player_id, title, body) values (v_p, 'Open #9 correction',
    'The Open #9 result was published by mistake and the pass came from that wrong prize, so no refund applies. Your points are 0.');
end $$;
commit;
