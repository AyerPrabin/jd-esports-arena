-- 2026-11-15 owner's go: 100 free-entry vouchers for Gym_boys (player def00429-e054-469c-9825-5d3229eea00c),
-- notification "Gift from father". Each voucher = one free entry to a paid event, valid 1 year.
-- Vouchers are not points: they can't be withdrawn or moved. Safe to re-run: skips if the gift notification exists.
-- Undo: delete from public.entry_vouchers where player_id = 'def00429-e054-469c-9825-5d3229eea00c'
--         and promo_id is null and used_reg is null and created_at::date = '2026-11-15';
begin;
do $$
declare v_p uuid := 'def00429-e054-469c-9825-5d3229eea00c';
begin
  if exists (select 1 from public.notifications where player_id = v_p and title = '🎁 Gift from father') then
    raise notice 'Gift already given, nothing done.';
    return;
  end if;
  insert into public.entry_vouchers (player_id, expires_at)
    select v_p, now() + interval '1 year' from generate_series(1, 100);
  insert into public.notifications (player_id, title, body) values (v_p, '🎁 Gift from father',
    'You got 100 free-entry vouchers as a gift from father. Join any paid event and pick "Use free entry". They last 1 year.');
end $$;
select public._vouchers_left('def00429-e054-469c-9825-5d3229eea00c') as vouchers_now;
commit;
