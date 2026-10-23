-- ZULU knows event changes in real time (2026-10-23).
--  * event_changes: publish-tournaments logs what changed on each event (new event, time, prize, entry, slots,
--    format, map, cancelled, winner) by comparing the live copy before and after every publish.
--  * zulu_live_context() also returns each event's host mod, whether the room details went out (never the code
--    itself) and the last 48 h of changes, so ZULU can say "Open #10 moved to 9:30 PM".
--  * zulu_ctx_version(): a cheap fingerprint of everything in that context. ZULU's edge cache keeps the context
--    until this changes, instead of a blind 45 s timer: an edit, a new squad or a room code shows up on the next message.
begin;

create table if not exists public.event_changes (
  id bigserial primary key,
  at timestamptz not null default now(),
  tournament text not null,
  what text not null
);
alter table public.event_changes enable row level security;   -- service role only
create index if not exists event_changes_at_idx on public.event_changes (at desc);

create or replace function public.zulu_ctx_version() returns text
language sql stable security definer set search_path = public as $$
  select md5(concat_ws('|',
    (select updated_at from public.site_content where key = 'tournaments'),
    (select count(*) || ':' || coalesce(max(created_at)::text, '') || ':' || coalesce(max(checked_in_at)::text, '')
       from public.registrations where created_at > now() - interval '30 days'),
    (select max(sent_at) from public.tournament_room_codes),
    (select max(id) from public.event_changes),
    (select max(created_at) from public.notifications where created_at > now() - interval '1 day')));
$$;
revoke all on function public.zulu_ctx_version() from public, anon, authenticated;
grant execute on function public.zulu_ctx_version() to service_role;

create or replace function public.zulu_live_context() returns jsonb
language sql stable security definer set search_path = public as $function$
  select jsonb_build_object(
    'now', now(),
    'version', public.zulu_ctx_version(),
    'tournaments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'name', t->>'name', 'status', t->>'status', 'winner', t->>'winner', 'date', t->>'date', 'time', t->>'time',
        'start', t->>'start', 'prize', t->>'prize', 'entry', t->>'entry', 'format', t->>'format', 'map', t->>'map',
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
revoke all on function public.zulu_live_context() from public, anon, authenticated;
grant execute on function public.zulu_live_context() to service_role;

commit;
