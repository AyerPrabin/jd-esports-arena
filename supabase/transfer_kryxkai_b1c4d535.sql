-- 13 Nov 2026, owner request: move all of Kryxkai's points (JD-JVDUH) to player_b1c4d535 (JD-YUNCK), 3-point charge removed.
-- Fails and changes nothing if Kryxkai's balance is no longer 95.
begin;
do $$
declare
  v_from uuid := '5d627fa9-c9e3-4b11-91e9-6aab317e1785';
  v_to   uuid := 'b1c4d535-43d9-4f48-9f0a-7b7fe305742e';
  v_bal int; v_new int; v_ref text := 'XFER-' || to_char(now(), 'YYYYMMDDHH24MISS');
begin
  select balance into v_bal from public.wallets where player_id = v_from for update;
  if v_bal is distinct from 95 then raise exception 'Kryxkai balance is % (expected 95), nothing moved', v_bal; end if;
  perform public._wallet_apply(v_from, -95, 'adjust', v_ref || '-OUT', 'Transfer to player_b1c4d535 (JD-YUNCK), owner approved; includes 3-point charge');
  v_new := public._wallet_apply(v_to, 92, 'adjust', v_ref || '-IN', 'Transfer from Kryxkai (JD-JVDUH), 95 points minus 3-point charge');
  insert into public.notifications (player_id, title, body) values
    (v_from, '95 JD points transferred', 'Your 95 points were moved to player_b1c4d535 as requested (3-point charge). Balance: 0 points.'),
    (v_to, '+92 JD points received', '92 points were moved to your wallet from Kryxkai (95 minus a 3-point charge). Balance: ' || v_new || ' points.');
end $$;
commit;
select p.username, w.balance from public.wallets w join public.players p on p.id = w.player_id
where w.player_id in ('5d627fa9-c9e3-4b11-91e9-6aab317e1785', 'b1c4d535-43d9-4f48-9f0a-7b7fe305742e');
