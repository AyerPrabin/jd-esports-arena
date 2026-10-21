-- ── ZULU live context (2026-10-21) ──
-- One round trip for everything ZULU grounds its answers in, straight from the live
-- database instead of the GitHub Pages copy of tournaments.json (which lags a publish by
-- minutes): every tournament without team logos, live confirmed/waitlisted seat counts,
-- whether a Weekly Pass is needed, the latest published standings, and the same
-- privacy-filtered announcements as recent_announcements(). Service role only.
create or replace function public.zulu_live_context()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'now', now(),
    'tournaments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', t->>'name', 'status', t->>'status', 'winner', t->>'winner', 'date', t->>'date', 'time', t->>'time',
        'start', t->>'start', 'prize', t->>'prize', 'entry', t->>'entry', 'format', t->>'format', 'map', t->>'map',
        'slots', coalesce(c.slots::text, t->>'slots'), 'platform', c.platform_mode,
        'confirmed', (select count(*) from public.registrations r where r.tournament_slug = t->>'name' and r.status in ('confirmed','approved')),
        'waitlisted', (select count(*) from public.registrations r where r.tournament_slug = t->>'name' and r.status = 'waitlisted'),
        'early_access', t->>'early_access', 'reg_opens', t->>'reg_opens',
        'pass_needed', coalesce(public.tournament_entry_npr(t->>'name'), 0) = 0
                       and coalesce(public.tournament_start_at(t->>'name'), now()) >= timestamptz '2026-10-27 00:00:00+05:45'))
      from public.site_content s, jsonb_array_elements(s.content->'tournaments') t
      left join public.tournament_capacity c on c.tournament_slug = t->>'name'
      where s.key = 'tournaments'), '[]'::jsonb),
    'bo3', (select jsonb_build_object('title', b->>'title', 'tournament', b->>'tournament', 'published', b->'published',
              'teams', (select jsonb_agg(jsonb_build_object('team', x->>'team', 'r', x->'r')) from jsonb_array_elements(coalesce(b->'teams','[]'::jsonb)) x))
            from public.site_content s, lateral (select s.content->'bo3' as b) q where s.key = 'tournaments'),
    'announcements', coalesce((select jsonb_agg(jsonb_build_object('title', a.title, 'body', a.body)) from public.recent_announcements() a), '[]'::jsonb));
$$;
revoke all on function public.zulu_live_context() from public, anon, authenticated;
grant execute on function public.zulu_live_context() to service_role;
