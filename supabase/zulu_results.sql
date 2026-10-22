-- ── ZULU publishes results in the JD Esports chat (2026-10-22) ──
-- When the admin publishes standings (site_content 'tournaments' → bo3 with published = true), ZULU writes:
--   * to every squad registered for that event: the full standings (total points per squad, points per match),
--     the winner, and their own place + points; the winning squad gets a "you won" message
--   * to everyone else active in the last 14 days: the winner and the top 3
-- When a winner is set on an event with no standings, its registered squads get the winner.
-- Once per player per event (zulu_auto_log, key 'results:<event>'). No extra push: publish-results already
-- pushes "results are up", so these show as unread in the chat instead.
begin;

create or replace function public._zulu_norm(t text)
returns text language sql immutable as $$ select lower(regexp_replace(coalesce(t, ''), '\s+', ' ', 'g')) $$;

create or replace function public.zulu_publish_results(p_content jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare b jsonb := p_content->'bo3'; v_ev text; v_rows jsonb; v_table text; v_win text; v_top3 text; n int := 0;
        r record; me record; t jsonb;
begin
  -- standings
  -- only fresh results: publishing old standings again never re-sends them
  if b is not null and coalesce((b->>'published')::boolean, false) and jsonb_array_length(coalesce(b->'teams', '[]')) > 0
     and coalesce(public.tournament_start_at(b->>'tournament'), now()) > now() - interval '36 hours' then
    v_ev := b->>'tournament';
    select jsonb_agg(x order by x.total desc, x.kills desc) into v_rows from (
      select tm->>'team' as team,
             (select coalesce(sum((m->>'pts')::int), 0) from jsonb_array_elements(coalesce(tm->'r', '[]')) m) as total,
             (select coalesce(sum((m->>'kills')::int), 0) from jsonb_array_elements(coalesce(tm->'r', '[]')) m) as kills,
             (select string_agg(coalesce(m->>'pts', '0'), ' / ') from jsonb_array_elements(coalesce(tm->'r', '[]')) m) as per
        from jsonb_array_elements(b->'teams') tm) x;
    select string_agg('#' || o || '  ' || (e->>'team') || ' – ' || (e->>'total') || ' pts (' || (e->>'per') || ')', chr(10) order by o)
      into v_table from jsonb_array_elements(v_rows) with ordinality as q(e, o) where o <= 15;
    v_win := v_rows->0->>'team';
    select string_agg('#' || o || ' ' || (e->>'team') || ' (' || (e->>'total') || ')', ', ' order by o)
      into v_top3 from jsonb_array_elements(v_rows) with ordinality as q(e, o) where o <= 3;

    -- squads in the event
    for r in select distinct on (g.player_id) g.player_id, coalesce(nullif(trim(g.squad_name), ''), p.squad_name) as sq
               from public.registrations g join public.players p on p.id = g.player_id
              where g.tournament_slug = v_ev and g.status in ('confirmed', 'approved', 'no_show')
    loop
      select o as place, e->>'total' as total into me
        from jsonb_array_elements(v_rows) with ordinality as q(e, o)
       where public._zulu_norm(e->>'team') = public._zulu_norm(r.sq) limit 1;
      if public._zulu_say(r.player_id, 'results:' || v_ev,
        case when me.place = 1 then '🏆 YOU WON ' || v_ev || '! ' || r.sq || ' finished #1 with ' || me.total || ' points. GG! The JD team will contact you about the prize.'
             when me.place is not null then '📊 Results for ' || v_ev || ' are up. ' || r.sq || ' finished #' || me.place || ' with ' || me.total || ' points.'
             else '📊 Results for ' || v_ev || ' are up.' end || chr(10) || chr(10) ||
        '🥇 Winner: ' || v_win || chr(10) || chr(10) || 'Standings (total · per match):' || chr(10) || v_table || chr(10) || chr(10) ||
        'Full board: jdesport.co.uk/leaderboard.html', false) then n := n + 1; end if;
    end loop;

    -- everyone else who played recently: the winner + top 3
    for r in select p.id as player_id from public.players p
              where p.last_seen_at > now() - interval '14 days'
                and not exists (select 1 from public.registrations g where g.player_id = p.id and g.tournament_slug = v_ev)
    loop
      if public._zulu_say(r.player_id, 'results:' || v_ev,
        '🏆 ' || v_ev || ' winner: ' || v_win || '!' || chr(10) || 'Top 3: ' || v_top3 || chr(10) || chr(10) ||
        'Want your squad on the board next time? Join the next event on Events.', false) then n := n + 1; end if;
    end loop;
  end if;

  -- a winner set on an event without standings
  for t in select x from jsonb_array_elements(coalesce(p_content->'tournaments', '[]')) x
            where coalesce(trim(x->>'winner'), '') <> '' and (b is null or x->>'name' is distinct from b->>'tournament')
              and public.tournament_start_at(x->>'name') > now() - interval '36 hours'
  loop
    for r in select distinct g.player_id from public.registrations g
              where g.tournament_slug = t->>'name' and g.status in ('confirmed', 'approved', 'no_show')
    loop
      if public._zulu_say(r.player_id, 'results:' || (t->>'name'),
        '🏆 ' || (t->>'name') || ' winner: ' || (t->>'winner') || '! GG to every squad that played.' || chr(10) || 'Results: jdesport.co.uk/leaderboard.html', false)
      then n := n + 1; end if;
    end loop;
  end loop;
  return n;
end;
$$;
revoke all on function public.zulu_publish_results(jsonb) from public, anon, authenticated;

create or replace function public.zulu_on_site_content() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.key = 'tournaments' then perform public.zulu_publish_results(new.content); end if;
  return null;
exception when others then
  raise warning 'zulu_on_site_content: %', sqlerrm;
  return null;
end;
$$;
drop trigger if exists zulu_on_site_content on public.site_content;
create trigger zulu_on_site_content after insert or update of content on public.site_content
  for each row execute function public.zulu_on_site_content();

commit;
