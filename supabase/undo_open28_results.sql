-- 2026-11-16 13:28 UTC: results for JD Free Fire Open #28 (tomorrow's event) were published by mistake.
-- Owner: "undo that". One transaction:
--   1. reject Youtz Esp's pending 101-point withdrawal (made with the wrong 88-point prize; points go back first)
--   2. take back the 3 wrong prizes (88 Youtz Esp, 35 PRIME FORCE, 52 Gym_boys) with 'adjust' rows
--   3. delete the 3 prize notifications and the #28 results rows, tell the 3 players
--   4. put the tournaments content back to the version saved just before the publish (history id 11)
begin;
select public.admin_resolve_withdrawal('f2ba9ec1-0054-4192-aa85-1ee2d864d52e', false,
  'Cancelled: it included a prize that was published by mistake. You can request your real balance again.');
select public._wallet_apply(p, -amt, 'adjust', 'undo:' || r, 'Removed: JD Free Fire Open #28 prize published by mistake')
from (values ('710ab476-6217-4f8b-a11c-b7f26dd873f2'::uuid, 88, 'prize:JD Free Fire Open #28:youtz esp'),
             ('bf7c0a16-54cf-49c2-8d9c-0ad6bc6d1a94'::uuid, 35, 'prize:JD Free Fire Open #28:prime force'),
             ('def00429-e054-469c-9825-5d3229eea00c'::uuid, 52, 'prize:JD Free Fire Open #28:gym_boys')) v(p, amt, r)
where not exists (select 1 from public.wallet_ledger w where w.ref = 'undo:' || v.r);
delete from public.notifications where tournament_slug = 'JD Free Fire Open #28' and title like '%Prize: +%';
delete from public.tournament_results where tournament_slug = 'JD Free Fire Open #28';
insert into public.notifications (player_id, tournament_slug, title, body)
select p, 'JD Free Fire Open #28', 'Prize removed: published by mistake',
  'Sorry, results for JD Free Fire Open #28 were published by mistake (that event is on Tue 17 Nov). The ' || amt ||
  ' points were taken back. Your other points are not affected.'
from (values ('710ab476-6217-4f8b-a11c-b7f26dd873f2'::uuid, 88), ('bf7c0a16-54cf-49c2-8d9c-0ad6bc6d1a94'::uuid, 35),
             ('def00429-e054-469c-9825-5d3229eea00c'::uuid, 52)) v(p, amt);
update public.site_content set content = (select content from public.site_content_history where id = 11), updated_at = now()
 where key = 'tournaments';
select json_build_object(
  'balances', (select json_agg(json_build_object('p', player_id, 'bal', balance)) from public.wallets where player_id in
     ('710ab476-6217-4f8b-a11c-b7f26dd873f2','bf7c0a16-54cf-49c2-8d9c-0ad6bc6d1a94','def00429-e054-469c-9825-5d3229eea00c')),
  'withdraw', (select status from public.withdraw_requests where id = 'f2ba9ec1-0054-4192-aa85-1ee2d864d52e'),
  'e28', (select t->>'status' from public.site_content, jsonb_array_elements(content->'tournaments') t where key='tournaments' and t->>'name'='JD Free Fire Open #28'),
  'bo3', (select content->'bo3'->>'tournament' from public.site_content where key='tournaments'),
  'r28', (select count(*) from public.tournament_results where tournament_slug='JD Free Fire Open #28')) r;
commit;
