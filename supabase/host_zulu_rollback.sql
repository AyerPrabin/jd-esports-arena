-- Undo host_zulu.sql: trigger and switch removed, host_send back to host_chat_all.sql (pings the host again).
begin;
drop trigger if exists host_messages_zulu on public.host_messages;
drop function if exists public.host_messages_zulu();
drop function if exists public.host_zulu_set(boolean);
create or replace function public.host_profile_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('handle', lower(d.handle), 'display_name', d.display_name, 'pending_name', d.pending_name,
                            'pending_at', d.pending_at, 'pid', auth.uid())
    from public.moderators d
   where d.role = 'host' and lower(d.email) = lower(coalesce(auth.jwt() ->> 'email', '')) and auth.uid() is not null
   limit 1
$$;
create or replace function public.host_send(p_handle text, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_h text := lower(trim(coalesce(p_handle, ''))); v_body text := trim(coalesce(p_body, ''));
        v_id bigint; v_quiet boolean; v_email text;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if v_body = '' then raise exception 'Type a message first.'; end if;
  if length(v_body) > 1000 then raise exception 'That message is too long (1000 characters max).'; end if;
  select d.email into v_email from public.moderators d where d.role = 'host' and lower(d.handle) = v_h;
  if v_email is null then raise exception 'This host isn''t on JD Arena any more.'; end if;
  -- any signed-in player may write to an invited host (8 Nov 2026); the 15-per-10-minutes limit below still applies
  if (select count(*) from public.host_messages m where m.player_id = v_me and not m.from_staff and m.created_at > now() - interval '10 minutes') >= 15 then
    raise exception 'You sent a lot of messages. Wait a few minutes for the host to reply.';
  end if;
  -- one alert per unanswered run of messages, so a chatty player can't flood the host's phone
  v_quiet := exists (select 1 from public.host_messages m where m.player_id = v_me and m.host_handle = v_h and not m.from_staff and m.read_at is null);
  insert into public.host_messages (player_id, host_handle, from_staff, body) values (v_me, v_h, false, v_body) returning host_messages.id into v_id;
  if not v_quiet then
    insert into public.notifications (player_id, title, body, push)
    select h.id, '[JD] New message in your host chat',
           coalesce((select '@' || p.username from public.players p where p.id = v_me), 'A player') || ' wrote to you. Open the Mod panel, then Chats.', true
      from public.players h where lower(h.email) = lower(v_email) limit 1;
  end if;
  return v_id;
end;
$$;
alter table public.moderators drop column if exists zulu_on;
notify pgrst, 'reload schema';
commit;
