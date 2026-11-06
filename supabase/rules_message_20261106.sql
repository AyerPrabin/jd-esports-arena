-- 2026-11-06 owner's go: every open tournament pays Rs 180, and every player gets the new rules once. A re-run sends nothing.
begin;
update public.site_content set updated_at = now(), content = jsonb_set(content, '{tournaments}', (
    select jsonb_agg(case when t->>'name' = 'JD Free Fire Open #14' then t || '{"prize":"180"}'::jsonb else t end order by o)
    from jsonb_array_elements(content->'tournaments') with ordinality x(t, o)))
  where key = 'tournaments';
insert into public.notifications (player_id, title, body)
  select p.id, '📢 New JD rules', 'Free tournaments: a free card or 15 points (no more 5 points). Open tournaments #14, #15, #17 and #18 now have a Rs 180 prize pool; big prizes are only in big paid tournaments. Every prize pool pays 50% to 1st, 30% to 2nd and 20% to 3rd. New for your safety: create a 6-number wallet PIN in your wallet. You need it to load or withdraw.'
  from public.players p
  where not exists(select 1 from public.banned_players b where b.player_id = p.id)
    and not exists(select 1 from public.notifications n where n.player_id = p.id and n.title = '📢 New JD rules');
commit;
