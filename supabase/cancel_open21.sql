-- 2026-11-14 owner's go: JD Free Fire Open #21 (prize 500, 50-pt entry, today 9:30 PM NPT) is cancelled and removed.
-- Every paid entry gets 100% back (5 squads x 50 = 250 checked 14 Nov). Safe to re-run: refunds are keyed by ref.
begin;
create temp table c21 on commit drop as
  select id, player_id, squad_name, status, coalesce(paid_points, 0) paid
  from public.registrations where tournament_slug = 'JD Free Fire Open #21';
-- waitlisted rows are refunded by the delete trigger, so only slot holders here
select public._wallet_apply(player_id, paid, 'refund', 'cancel21:' || id::text,
       'Refund: JD Free Fire Open #21 cancelled')
  from c21 where paid > 0 and status <> 'waitlisted'
    and not exists (select 1 from public.wallet_ledger w where w.reason = 'refund' and w.ref = 'cancel21:' || c21.id::text);
insert into public.notifications (player_id, tournament_slug, title, body, push)
  select player_id, 'JD Free Fire Open #21', '❌ JD Free Fire Open #21 cancelled',
    'Sorry, today''s JD Free Fire Open #21 is cancelled. Your ' || paid || ' points entry is fully back in your wallet.' || chr(10) ||
    'Aajako event cancel bhayo, tapaiko pura point wallet ma firta aayo.', true
  from c21;
delete from public.registrations where id in (select id from c21);
update public.site_content
   set content = jsonb_set(content, '{tournaments}',
       (select coalesce(jsonb_agg(t), '[]'::jsonb) from jsonb_array_elements(content->'tournaments') t
         where t->>'name' <> 'JD Free Fire Open #21'))
 where key = 'tournaments';
delete from public.tournament_capacity where tournament_slug = 'JD Free Fire Open #21';
select squad_name, status, paid refunded from c21 order by 1;
commit;
select jsonb_array_length(content->'tournaments') events_left from public.site_content where key = 'tournaments';
