-- ── One delta-sync call for the chat (2026-10-25) ──
-- chat.js used to poll dm_poll + jd_poll every 5 s and, every third poll, re-download the last 40 notifications
-- and the whole ZULU feed. jd_sync(p_since) answers all of it in one round trip and sends only what changed:
--   now      server time = the cursor the device sends next time
--   dm, jd   the same unread counts / newest message as dm_poll() and jd_poll()
--   al       your notifications (alerts) created or read since p_since (first sync: the newest 40)
--   al_ids   ids of your newest 40 alerts, so the device drops ones deleted on the server (e.g. a removed squad's room code)
--   zf       ZULU messages created or read since p_since (first sync: the newest 30)
--   ev       event changes since p_since (event_changes), so pages can refresh event cards
-- The device keeps everything in IndexedDB and merges by id. p_since is moved back 15 s here: a row's created_at is
-- its transaction's start time, so a slow insert can land "in the past" - the overlap catches it, ids dedupe it.
begin;

create or replace function public.jd_sync(p_since timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_since timestamptz := p_since - interval '15 seconds';
begin
  if v_me is null then raise exception 'not signed in'; end if;
  return jsonb_build_object(
    'now', now(),
    'dm', public.dm_poll(),
    'jd', public.jd_poll(),
    'al', coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc) from (
             select id, title, body, room_id, room_pass, tournament_slug, created_at, read_at
               from public.notifications
              where player_id = v_me and (p_since is null or created_at > v_since or read_at > v_since)
              order by created_at desc limit case when p_since is null then 40 else 80 end) n), '[]'::jsonb),
    'al_ids', coalesce((select jsonb_agg(id) from (select id from public.notifications where player_id = v_me
                          order by created_at desc limit 40) x), '[]'::jsonb),
    'zf', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'body', body, 'created_at', created_at, 'read_at', read_at) order by id desc) from (
             select id, body, created_at, read_at from public.jd_messages
              where player_id = v_me and channel = 'zulu' and (p_since is null or created_at > v_since or read_at > v_since)
              order by id desc limit 30) z), '[]'::jsonb),
    'ev', case when p_since is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('t', tournament, 'what', what, 'at', at) order by id)
             from (select id, tournament, what, at from public.event_changes where at > v_since order by id desc limit 20) e), '[]'::jsonb) end
  );
end;
$$;
create index if not exists notifications_player_created_idx on public.notifications(player_id, created_at desc);
revoke all on function public.jd_sync(timestamptz) from public, anon;
grant execute on function public.jd_sync(timestamptz) to authenticated;

commit;
notify pgrst, 'reload schema';
