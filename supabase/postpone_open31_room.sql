-- 2026-11-20 owner: Open #31 moved to Sat 21 Nov 5:30 PM NPT, but tonight's room code was already released
-- (sent 15:08 UTC), so tickets still showed "Room code is out" with the dead room and blocked withdrawals.
-- Clear it; the host stages + sends a NEW room tomorrow. Safe to re-run.
begin;
delete from public.tournament_room_codes where tournament_slug = 'JD Free Fire Open #31';
select count(*) room_rows_left from public.tournament_room_codes where tournament_slug = 'JD Free Fire Open #31';
commit;
