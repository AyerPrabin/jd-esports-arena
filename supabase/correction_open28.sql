-- 2026-11-18 owner's go ("send correction"): the 16 Nov wrong publish told players "#28 winner: Gym_boys".
-- Send the real result to exactly those players, in the same channel. Safe to re-run.
begin;
insert into public.jd_messages (player_id, from_staff, staff_email, channel, body, push)
select distinct m.player_id, true, 'zulu', m.channel,
'✅ Correction: the "#28 winner: Gym_boys" message on 16 Nov was a mistake. The real JD Free Fire Open #28 (17 Nov) result: #1 Youtz Esp (65 pts), #2 Paragon esports (62), #3 Infinity (44). Prizes are in the winners'' wallets. Sorry for the confusion!
Sacchyaune: 16 Nov ko "Gym_boys winner" message galti thiyo. #28 ko sahi winner Youtz Esp ho.', true
from public.jd_messages m
where m.body ilike '%#28 winner: Gym_boys%'
  and not exists (select 1 from public.jd_messages c where c.player_id = m.player_id and c.body like '✅ Correction: the "#28 winner: Gym_boys"%');
select count(*) sent from public.jd_messages where body like '✅ Correction: the "#28 winner: Gym_boys"%';
commit;
