-- 2026-11-03 ZULU squad match: once a week ZULU groups players who posted "🙋 Looking for a squad" in Find
-- Teammates, by language (AI reads their post), 2-4 per group, and opens a squad chat with an intro:
-- "you're all looking for a squad, why not try as one?". Anyone can leave the chat. Nobody is grouped with a
-- player they blocked (or who blocked them), banned players are skipped, and a player is matched at most once
-- every 7 days. Free posts only (no points or coins ever change hands in a ZULU squad). Server only (zulu-squad-match edge function, service role). Safe to run again.
begin;
create table if not exists public.squad_matches (
  id bigserial primary key,
  group_id uuid references public.chat_groups(id) on delete set null,
  lang text not null,
  members uuid[] not null,
  created_at timestamptz not null default now()
);
create index if not exists squad_matches_time on public.squad_matches (created_at desc);
alter table public.squad_matches enable row level security;   -- no policies: service role only

-- who can be matched this week (only what ZULU needs to guess the language and write the intro)
create or replace function public.squad_match_candidates()
returns table(player_id uuid, username text, ign text, roles text[], note text, tournament text, city text, country text)
language sql stable security definer set search_path = public as $$
  select distinct on (p.player_id) p.player_id, pl.username, pl.ff_name, p.roles, p.note, p.tournament, pl.area_city, pl.area_country
  from public.teammate_posts p join public.players pl on pl.id = p.player_id
  where p.kind = 'player' and p.pay = 'free' and p.expires_at > now()   -- free play only: no JD points / coins involved and pl.ff_uid is not null and pl.username is not null
    and not exists(select 1 from public.banned_players b where b.player_id = p.player_id)
    and not exists(select 1 from public.squad_matches m where p.player_id = any(m.members) and m.created_at > now() - interval '7 days')
  order by p.player_id, p.created_at desc
$$;

-- pairs among the candidates that must never share a chat
create or replace function public.squad_match_blocks(p_ids uuid[])
returns table(a uuid, b uuid) language sql stable security definer set search_path = public as $$
  select blocker, blocked from public.player_blocks where blocker = any(p_ids) and blocked = any(p_ids)
$$;

-- make the squad chat. Re-checks everything, so a bad call can't put strangers together against these rules.
create or replace function public.zulu_make_squad(p_name text, p_members uuid[], p_intro text, p_lang text)
returns uuid language plpgsql security definer set search_path = public as $$
declare g uuid; v uuid; a uuid; b uuid; n int := coalesce(array_length(p_members, 1), 0);
begin
  if n < 2 or n > 4 then raise exception 'A ZULU squad needs 2 to 4 players.'; end if;
  foreach a in array p_members loop
    if exists(select 1 from public.banned_players where player_id = a) then raise exception 'Banned player in the group.'; end if;
    if exists(select 1 from public.squad_matches m where a = any(m.members) and m.created_at > now() - interval '7 days') then
      raise exception 'Player already matched this week.';
    end if;
    foreach b in array p_members loop
      if a <> b and public._blocked_either(a, b) then raise exception 'Blocked pair in the group.'; end if;
    end loop;
  end loop;
  insert into public.chat_groups (name, created_by) values (left(coalesce(nullif(trim(p_name), ''), 'ZULU Squad'), 40), null) returning id into g;
  foreach v in array p_members loop
    insert into public.chat_group_members (group_id, player_id, added_by) values (g, v, null) on conflict do nothing;
  end loop;
  perform public._group_system(g, '🤖 ZULU made this squad chat for players who are looking for a squad. Not for you? Leave any time from the chat menu.');
  perform public._group_system(g, '🤖 ZULU: ' || left(trim(p_intro), 480));
  insert into public.notifications (player_id, title, body, push)
    select v, '🤝 ZULU found you a squad', 'You and ' || (n - 1) || ' other player' || case when n > 2 then 's' else '' end ||
      ' are all looking for a squad. Say hi in Messages and try a match together!', true
    from unnest(p_members) v;
  insert into public.squad_matches (group_id, lang, members) values (g, left(coalesce(p_lang, '?'), 12), p_members);
  return g;
end $$;

revoke all on function public.squad_match_candidates() from public, anon, authenticated;
revoke all on function public.squad_match_blocks(uuid[]) from public, anon, authenticated;
revoke all on function public.zulu_make_squad(text, uuid[], text, text) from public, anon, authenticated;
grant execute on function public.squad_match_candidates() to service_role;
grant execute on function public.squad_match_blocks(uuid[]) to service_role;
grant execute on function public.zulu_make_squad(text, uuid[], text, text) to service_role;

-- every Saturday 6:15 PM Nepal (12:30 UTC), before the weekend events
select cron.unschedule(jobid) from cron.job where jobname = 'zulu-squad-match';
select cron.schedule('zulu-squad-match', '30 12 * * 6', $cron$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/zulu-squad-match',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 120000);
$cron$);
commit;
