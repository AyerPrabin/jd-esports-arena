-- Chat cache v2 (2026-10-27): the app/site keeps chats on the phone (chat.js, IndexedDB) and now asks only for
-- messages newer than the last one it has, instead of the whole last 60 every 2.5 seconds. dm_thread already
-- takes p_after; this gives group_thread and jd_thread the same. Old callers keep working (p_after defaults to null).
-- Dropped and re-created (not an overload) so named calls like {p_group, p_before} never become ambiguous.
begin;

drop function if exists public.group_thread(uuid, bigint);
create function public.group_thread(p_group uuid, p_before bigint default null, p_after bigint default null)
returns table(id bigint, sender uuid, mine boolean, kind text, body text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.id, m.sender, m.sender = auth.uid(), m.kind, m.body, m.created_at
  from public.group_messages m
  where m.group_id = p_group and public._group_member(p_group, auth.uid())
    and (p_before is null or m.id < p_before)
    and (p_after is null or m.id > p_after)
  order by m.id desc
  limit 60
$$;
revoke all on function public.group_thread(uuid, bigint, bigint) from public, anon;
grant execute on function public.group_thread(uuid, bigint, bigint) to authenticated;

drop function if exists public.jd_thread(bigint);
create function public.jd_thread(p_before bigint default null, p_after bigint default null)
returns table(id bigint, mine boolean, body text, created_at timestamptz, read_at timestamptz, ai boolean)
language sql stable security definer set search_path = public as $$
  select m.id, not m.from_staff, m.body, m.created_at, m.read_at, false
  from public.jd_messages m
  where m.player_id = auth.uid() and m.channel = 'jd'
    and (p_before is null or m.id < p_before)
    and (p_after is null or m.id > p_after)
  order by m.id desc limit 60
$$;
revoke all on function public.jd_thread(bigint, bigint) from public, anon;
grant execute on function public.jd_thread(bigint, bigint) to authenticated;

commit;
