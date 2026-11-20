-- 2026-11-18 owner's go ("okay go live"): one-time player survey in JD chat (players reply there; push via jd_messages_push).
-- Safe to re-run: skips players who already got it.
begin;
insert into public.jd_messages (player_id, from_staff, staff_email, channel, body, push)
select p.id, true, 'ayerprabin95@gmail.com', 'jd',
'📊 JD wants your opinion! Reply here 👇
1️⃣ Best time for you? (a) 2 PM (b) 6:30 PM (c) 8 PM (d) 9:30 PM
2️⃣ How many events a day? 1 / 2 / 3+
3️⃣ Which mode? Squad / Duo / Solo
4️⃣ Would you join paid events with bigger prizes? (e.g. 50 points entry → Rs 500 prize) Yes / No / Maybe
5️⃣ Would you invite friends to JD? (each friend = 1 free event card for you, up to 3) Yes / No
6️⃣ What should JD fix or add?

Nepali: Kun time ramro? Din ma kati game? Squad, duo ki solo? Thulo prize ko paid event ma khelnuhunchha? Saathi invite garnuhunchha (1 saathi = 1 free card)? Ke sudhaarnu parchha? Yahi reply garnus 🙏', true
from public.players p
where not exists (select 1 from public.jd_messages m where m.player_id = p.id and m.channel = 'jd' and m.body like '📊 JD wants your opinion!%');
select count(*) sent from public.jd_messages where channel = 'jd' and body like '📊 JD wants your opinion!%';
commit;
