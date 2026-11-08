-- Host profile (owner's ask, 8 Nov 2026): an invited host picks a display name, the owner approves it in /admin/,
-- and the host uploads a host photo. The @handle never changes: chats (host_messages.host_handle), events
-- ("host" in tournaments.json) and the moderators unique index all key on it.
-- * Name: host_name_request() saves pending_name and notifies the owner; host_name_review() (owner only) approves
--   or rejects it and notifies the host. Players only ever see the approved display_name.
-- * Photo: <host's player id>/host.jpg in the private avatars bucket. Uploading there is already allowed (own folder).
--   The new read rule lets signed-in players open ONLY that one file, ONLY for host accounts - a host's personal
--   avatar.jpg stays visible to friends only, as before. Photos are not reviewed.
-- Undo: supabase/host_profile_rollback.sql
begin;

alter table public.moderators add column if not exists display_name text;
alter table public.moderators add column if not exists pending_name text;
alter table public.moderators add column if not exists pending_at timestamptz;

create or replace function public._jd_is_owner() returns boolean
language sql stable as $$ select lower(coalesce(auth.jwt() ->> 'email', '')) = 'ayerprabin95@gmail.com' $$;

-- the signed-in host's own row (null for everyone else)
create or replace function public.host_profile_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('handle', lower(d.handle), 'display_name', d.display_name, 'pending_name', d.pending_name,
                            'pending_at', d.pending_at, 'pid', auth.uid())
    from public.moderators d
   where d.role = 'host' and lower(d.email) = lower(coalesce(auth.jwt() ->> 'email', '')) and auth.uid() is not null
   limit 1
$$;

create or replace function public.host_name_request(p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_name text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g'); v_h text;
begin
  select lower(d.handle) into v_h from public.moderators d
   where d.role = 'host' and lower(d.email) = lower(coalesce(auth.jwt() ->> 'email', ''));
  if v_h is null or auth.uid() is null then raise exception 'Only invited hosts can set a host name.'; end if;
  if length(v_name) < 2 or length(v_name) > 24 then raise exception 'Use 2 to 24 characters.'; end if;
  if v_name !~ '^[A-Za-z0-9 ._-]+$' then raise exception 'Use letters, numbers, spaces, dots, dashes or underscores.'; end if;
  if v_name ~* '(\mjd|\m(admin|official|support|staff|moderator|zulu)\M)' then raise exception 'That name looks like JD staff. Pick another one.'; end if;
  update public.moderators set pending_name = v_name, pending_at = now()
   where role = 'host' and lower(handle) = v_h;
  insert into public.notifications (player_id, title, body, push)
  select p.id, '[JD] Host name to review', '@' || v_h || ' wants to be shown as "' || v_name || '". Approve or reject it in Admin, Moderators.', true
    from public.players p where lower(p.email) = 'ayerprabin95@gmail.com' limit 1;
  return public.host_profile_me();
end;
$$;

create or replace function public.host_names_pending() returns table(handle text, display_name text, pending_name text, pending_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._jd_is_owner() then raise exception 'Owner only.'; end if;
  return query select lower(d.handle), d.display_name, d.pending_name, d.pending_at
    from public.moderators d where d.role = 'host' and d.pending_name is not null order by d.pending_at;
end;
$$;

create or replace function public.host_name_review(p_handle text, p_ok boolean) returns void
language plpgsql security definer set search_path = public as $$
declare v_h text := lower(trim(coalesce(p_handle, ''))); v_name text; v_email text;
begin
  if not public._jd_is_owner() then raise exception 'Owner only.'; end if;
  select d.pending_name, d.email into v_name, v_email from public.moderators d where d.role = 'host' and lower(d.handle) = v_h;
  if v_name is null then raise exception 'No name waiting for @%.', v_h; end if;
  update public.moderators set display_name = case when p_ok then v_name else display_name end, pending_name = null, pending_at = null
   where role = 'host' and lower(handle) = v_h;
  insert into public.notifications (player_id, title, body, push)
  select p.id, case when p_ok then 'Host name approved' else 'Host name not approved' end,
         case when p_ok then 'Players now see you as "' || v_name || '".' else '"' || v_name || '" wasn''t approved. Pick another name in the Mod panel, Help.' end, true
    from public.players p where lower(p.email) = lower(v_email) limit 1;
end;
$$;

-- chat list: approved name, the host's player id and whether a host photo exists
create or replace function public.host_chat_list() returns jsonb
language sql stable security definer set search_path = public, storage as $$
  with hosts as (
    select distinct on (lower(d.handle)) lower(d.handle) h, d.display_name, p.id pid
      from public.moderators d left join public.players p on lower(p.email) = lower(d.email)
     where d.role = 'host' and coalesce(d.handle, '') <> '')
  select coalesce(jsonb_agg(jsonb_build_object('handle', hosts.h, 'name', hosts.display_name, 'pid', hosts.pid,
           'photo', exists (select 1 from storage.objects o where o.bucket_id = 'avatars' and o.name = hosts.pid::text || '/host.jpg'),
           'body', l.body, 'at', l.created_at, 'mine', not l.from_staff,
           'unread', (select count(*) from public.host_messages u where u.player_id = auth.uid() and u.host_handle = hosts.h and u.from_staff and u.read_at is null))
         order by l.created_at desc nulls last, hosts.h), '[]'::jsonb)
    from hosts
    left join lateral (select m.body, m.created_at, m.from_staff from public.host_messages m
                        where m.player_id = auth.uid() and m.host_handle = hosts.h order by m.id desc limit 1) l on true
   where auth.uid() is not null
$$;

revoke all on function public._jd_is_owner() from public, anon;
revoke all on function public.host_profile_me() from public, anon;
revoke all on function public.host_name_request(text) from public, anon;
revoke all on function public.host_names_pending() from public, anon;
revoke all on function public.host_name_review(text, boolean) from public, anon;
grant execute on function public._jd_is_owner() to authenticated;
grant execute on function public.host_profile_me() to authenticated;
grant execute on function public.host_name_request(text) to authenticated;
grant execute on function public.host_names_pending() to authenticated;
grant execute on function public.host_name_review(text, boolean) to authenticated;

-- only <host player id>/host.jpg, only for host accounts
drop policy if exists "avatars select host photo" on storage.objects;
create policy "avatars select host photo" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and storage.filename(name) = 'host.jpg'
         and exists (select 1 from public.moderators d join public.players p on lower(p.email) = lower(d.email)
                      where d.role = 'host' and p.id::text = (storage.foldername(name))[1]));

notify pgrst, 'reload schema';
commit;
