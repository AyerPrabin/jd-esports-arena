-- ── JD Esports chat in real time (2026-10-22) ──
-- Each new chat message sends a Realtime broadcast so the open mod panel / player chat refreshes at once
-- instead of waiting for its next poll. The broadcast carries NO message text or names: it is only a
-- "something new" ping; the pages then load the data through their normal, permission-checked calls.
--   topic 'jd-staff'        : any new JD Esports (human) chat message -> /mod/ Chats refreshes
--   topic 'jd-p-<player id>': a staff or ZULU message for that player -> their Messages refresh
begin;

create or replace function public.jd_messages_live() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    if new.channel = 'jd' then perform realtime.send('{}'::jsonb, 'new', 'jd-staff', false); end if;
    if new.from_staff then perform realtime.send(jsonb_build_object('c', new.channel), 'new', 'jd-p-' || new.player_id, false); end if;
  exception when others then
    raise warning 'jd_messages_live: %', sqlerrm;
  end;
  return null;
end;
$$;
revoke all on function public.jd_messages_live() from public, anon, authenticated;
drop trigger if exists jd_messages_live on public.jd_messages;
create trigger jd_messages_live after insert on public.jd_messages for each row execute function public.jd_messages_live();

-- a player opening the chat marks staff messages read: tell the mod panel ("Seen")
create or replace function public.jd_messages_seen() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin perform realtime.send('{}'::jsonb, 'seen', 'jd-staff', false); exception when others then null; end;
  return null;
end;
$$;
revoke all on function public.jd_messages_seen() from public, anon, authenticated;
drop trigger if exists jd_messages_seen on public.jd_messages;
create trigger jd_messages_seen after update of read_at on public.jd_messages
  for each row when (new.from_staff and new.channel = 'jd' and old.read_at is null and new.read_at is not null)
  execute function public.jd_messages_seen();

commit;
