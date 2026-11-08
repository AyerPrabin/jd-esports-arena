-- Undo host_profile.sql: host photo read rule and name functions removed, chat list back to host_chat_all.sql.
-- The display_name / pending_name columns are kept (data), they are simply no longer read.
begin;
drop policy if exists "avatars select host photo" on storage.objects;
drop function if exists public.host_name_review(text, boolean);
drop function if exists public.host_names_pending();
drop function if exists public.host_name_request(text);
drop function if exists public.host_profile_me();
drop function if exists public._jd_is_owner();
create or replace function public.host_chat_list() returns jsonb
language sql stable security definer set search_path = public as $$
  with hosts as (
    select distinct lower(d.handle) h from public.moderators d where d.role = 'host' and coalesce(d.handle, '') <> '')
  select coalesce(jsonb_agg(jsonb_build_object('handle', hosts.h, 'body', l.body, 'at', l.created_at, 'mine', not l.from_staff,
           'unread', (select count(*) from public.host_messages u where u.player_id = auth.uid() and u.host_handle = hosts.h and u.from_staff and u.read_at is null))
         order by l.created_at desc nulls last, hosts.h), '[]'::jsonb)
    from hosts
    left join lateral (select m.body, m.created_at, m.from_staff from public.host_messages m
                        where m.player_id = auth.uid() and m.host_handle = hosts.h order by m.id desc limit 1) l on true
   where auth.uid() is not null
$$;
notify pgrst, 'reload schema';
commit;
