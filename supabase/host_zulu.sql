-- ZULU in host chats (owner's ask, 8 Nov 2026), OFF until the host turns it on in the Mod panel (Help).
-- When on, a player's message to that host is answered by the zulu-host Edge Function (deploy with --no-verify-jwt).
-- ZULU's replies are host_messages rows from_staff, starting with "ZULU · " so players can see it is the AI.
-- With ZULU on, host_send no longer pings the host for every message: zulu-host pings them only for big issues,
-- or when the host has replied in person in the last 12 hours (ZULU stays out of that chat).
-- Run AFTER host_profile.sql. Undo: supabase/host_zulu_rollback.sql
begin;

alter table public.moderators add column if not exists zulu_on boolean not null default false;

create or replace function public.host_profile_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('handle', lower(d.handle), 'display_name', d.display_name, 'pending_name', d.pending_name,
                            'pending_at', d.pending_at, 'pid', auth.uid(), 'zulu_on', d.zulu_on)
    from public.moderators d
   where d.role = 'host' and lower(d.email) = lower(coalesce(auth.jwt() ->> 'email', '')) and auth.uid() is not null
   limit 1
$$;

create or replace function public.host_zulu_set(p_on boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update public.moderators set zulu_on = coalesce(p_on, false)
   where role = 'host' and lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) and auth.uid() is not null;
  if not found then raise exception 'Only invited hosts can change this.'; end if;
  return public.host_profile_me();
end;
$$;
revoke all on function public.host_zulu_set(boolean) from public, anon;
grant execute on function public.host_zulu_set(boolean) to authenticated;

-- host_send (host_chat_all.sql) + no host ping while ZULU is on (zulu-host pings for big issues)
create or replace function public.host_send(p_handle text, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_h text := lower(trim(coalesce(p_handle, ''))); v_body text := trim(coalesce(p_body, ''));
        v_id bigint; v_quiet boolean; v_email text; v_zulu boolean;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if v_body = '' then raise exception 'Type a message first.'; end if;
  if length(v_body) > 1000 then raise exception 'That message is too long (1000 characters max).'; end if;
  select d.email, d.zulu_on into v_email, v_zulu from public.moderators d where d.role = 'host' and lower(d.handle) = v_h;
  if v_email is null then raise exception 'This host isn''t on JD Arena any more.'; end if;
  -- any signed-in player may write to an invited host (8 Nov 2026); the 15-per-10-minutes limit below still applies
  if (select count(*) from public.host_messages m where m.player_id = v_me and not m.from_staff and m.created_at > now() - interval '10 minutes') >= 15 then
    raise exception 'You sent a lot of messages. Wait a few minutes for the host to reply.';
  end if;
  -- one alert per unanswered run of messages, so a chatty player can't flood the host's phone
  v_quiet := v_zulu or exists (select 1 from public.host_messages m where m.player_id = v_me and m.host_handle = v_h and not m.from_staff and m.read_at is null);
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

-- a player wrote to a host with ZULU on: zulu-host answers (same pg_net + vault pattern as jd_messages_push)
create or replace function public.host_messages_zulu() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ids bigint[];
begin
  select array_agg(n.id) into v_ids from new_rows n
   where not n.from_staff and exists (select 1 from public.moderators d where d.role = 'host' and lower(d.handle) = n.host_handle and d.zulu_on);
  if v_ids is not null then
    begin
      perform net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/zulu-host',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
        body := jsonb_build_object('ids', to_jsonb(v_ids)));
    exception when others then
      raise warning 'host_messages_zulu: %', sqlerrm;
    end;
  end if;
  return null;
end;
$$;
revoke all on function public.host_messages_zulu() from public, anon, authenticated;
drop trigger if exists host_messages_zulu on public.host_messages;
create trigger host_messages_zulu after insert on public.host_messages
  referencing new table as new_rows for each statement execute function public.host_messages_zulu();

notify pgrst, 'reload schema';
commit;
