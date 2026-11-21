-- realtime_private.sql (21 Nov 2026, audit #13): the chat "something new" pings go out on PRIVATE channels.
-- Before: public topics, so anyone with the public key could listen to jd-staff / jd-p-<id> or send fake pings
-- that made every open mod tab reload its chats. Now: only the signed-in player hears jd-p-<their id>, only
-- moderators hear jd-staff, and nobody can send (no INSERT policy: only these server triggers send).
-- The pings still carry no text or names. The online-now presence channel (jd-online) stays public on purpose.
-- Pages fall back to 20 s polling if a join fails. Run: npx supabase db query --remote --yes -f supabase/realtime_private.sql
-- Undo: npx supabase db query --remote --yes -f supabase/jd_chat_live.sql (public pings again)
begin;

create or replace function public.jd_messages_live() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    if new.channel = 'jd' then perform realtime.send('{}'::jsonb, 'new', 'jd-staff', true); end if;
    if new.from_staff then perform realtime.send(jsonb_build_object('c', new.channel), 'new', 'jd-p-' || new.player_id, true); end if;
  exception when others then
    raise warning 'jd_messages_live: %', sqlerrm;
  end;
  return null;
end;
$$;

create or replace function public.jd_messages_seen() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin perform realtime.send('{}'::jsonb, 'seen', 'jd-staff', true); exception when others then null; end;
  return null;
end;
$$;

-- who may listen (is_moderator is SECURITY DEFINER, so the moderators table's own RLS doesn't block it)
drop policy if exists "jd chat pings: own player or moderators" on realtime.messages;
create policy "jd chat pings: own player or moderators" on realtime.messages
  for select to authenticated
  using (realtime.messages.extension = 'broadcast' and (
    (select realtime.topic()) = 'jd-p-' || (select auth.uid())::text
    or ((select realtime.topic()) = 'jd-staff' and (select public.is_moderator()))));

select policyname, cmd from pg_policies where schemaname = 'realtime';
commit;
