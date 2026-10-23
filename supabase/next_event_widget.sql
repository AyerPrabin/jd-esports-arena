-- Android home-screen widget (APK 1.4.0, NextEventWidget.java): the next JD Arena tournament with live seats.
-- Public (anon) and small: only what's already on the public event cards.
create or replace function public.next_event_widget() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((
    select jsonb_build_object('name', t->>'name', 'start', t->>'start', 'date', t->>'date', 'time', t->>'time',
      'prize', t->>'prize', 'entry', coalesce(t->>'entry', 'Free'), 'host', nullif(t->>'host', ''),
      'slots', coalesce(c.slots, nullif(regexp_replace(coalesce(t->>'slots', ''), '\D', '', 'g'), '')::int),
      'taken', (select count(*) from public.registrations r where r.tournament_slug = t->>'name' and r.status in ('confirmed', 'approved')))
    from public.site_content s, jsonb_array_elements(s.content->'tournaments') t
    left join public.tournament_capacity c on c.tournament_slug = t->>'name'
    where s.key = 'tournaments'
      and lower(coalesce(t->>'status', 'upcoming')) not in ('completed', 'cancelled', 'finished')
      and coalesce(trim(t->>'winner'), '') = ''
      and (t->>'start') is not null and (t->>'start')::timestamptz > now() - interval '2 hours'
    order by (t->>'start')::timestamptz limit 1), '{}'::jsonb);
$$;
grant execute on function public.next_event_widget() to anon, authenticated;
