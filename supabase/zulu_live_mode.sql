-- zulu_live_mode.sql (10 Nov 2026): ZULU gets each event's mode (solo/duo/squad), game, all 3 maps,
-- stage and matches, so it never guesses the mode. Re-created from the LIVE definition.
-- Run: npx supabase db query --remote --yes -f supabase/zulu_live_mode.sql
CREATE OR REPLACE FUNCTION public.zulu_live_context()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object(
    'now', now(),
    'version', public.zulu_ctx_version(),
    'tournaments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', t->>'name', 'status', t->>'status', 'winner', t->>'winner', 'date', t->>'date', 'time', t->>'time',
        'start', t->>'start', 'prize', t->>'prize', 'entry', t->>'entry', 'format', t->>'format', 'map', t->>'map', 'map2', t->>'map2', 'map3', t->>'map3',
        'game', t->>'game', 'stage', nullif(t->>'stage',''), 'matches', nullif(t->>'matches',''),
        'mode', coalesce(nullif(lower(t->>'mode'),''), case when t->>'game' ilike '%solo%' then 'solo' when t->>'game' ilike '%duo%' then 'duo' else 'squad' end),
        'host', nullif(t->>'host', ''),
        'slots', coalesce(c.slots::text, t->>'slots'), 'platform', c.platform_mode,
        'confirmed', (select count(*) from public.registrations r where r.tournament_slug = t->>'name' and r.status in ('confirmed','approved')),
        'playing', (select count(*) from public.registrations r where r.tournament_slug = t->>'name' and r.status in ('confirmed','approved') and r.checked_in_at is not null),
        'waitlisted', (select count(*) from public.registrations r where r.tournament_slug = t->>'name' and r.status = 'waitlisted'),
        'room_sent_at', (select rc.sent_at from public.tournament_room_codes rc where rc.tournament_slug = t->>'name'),
        'early_access', t->>'early_access', 'reg_opens', t->>'reg_opens',
        'pass_needed', coalesce(public.tournament_entry_npr(t->>'name'), 0) = 0
                       and coalesce(public.tournament_start_at(t->>'name'), now()) >= timestamptz '2026-10-27 00:00:00+05:45'))
      from public.site_content s, jsonb_array_elements(s.content->'tournaments') t
      left join public.tournament_capacity c on c.tournament_slug = t->>'name'
      where s.key = 'tournaments'), '[]'::jsonb),
    'changes', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'tournament', e.tournament, 'what', e.what) order by e.at desc)
      from (select * from public.event_changes where at > now() - interval '48 hours' order by at desc limit 20) e), '[]'::jsonb),
    'bo3', (select jsonb_build_object('title', b->>'title', 'tournament', b->>'tournament', 'published', b->'published',
              'teams', (select jsonb_agg(jsonb_build_object('team', x->>'team', 'r', x->'r')) from jsonb_array_elements(coalesce(b->'teams','[]'::jsonb)) x))
            from public.site_content s, lateral (select s.content->'bo3' as b) q where s.key = 'tournaments'),
    'announcements', coalesce((select jsonb_agg(jsonb_build_object('title', a.title, 'body', a.body)) from public.recent_announcements() a), '[]'::jsonb));
$function$;
