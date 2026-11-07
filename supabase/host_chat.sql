-- Host chat: one chat between a player and each invited host, separate from the JD Esports chat.
-- A table of its own, not a jd_messages channel: older jd_messages readers (ZULU learning, inbox, push triggers)
-- can never see or answer these messages. No client reads this table directly: only the functions below and mod-panel.
-- from_staff = the host's side (same name as jd_messages so the rule 9 trigger _chat_respect works unchanged).
-- Undo: host_chat_rollback.sql

create table if not exists public.host_messages (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  host_handle text not null check (host_handle ~ '^[a-z0-9._]{2,30}$'),
  from_staff boolean not null default false,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists host_messages_thread_idx on public.host_messages (player_id, host_handle, id desc);
create index if not exists host_messages_host_idx on public.host_messages (host_handle, id desc);
alter table public.host_messages enable row level security;
revoke all on public.host_messages from public, anon, authenticated;
grant select, insert, update on public.host_messages to service_role;

-- Keeps chats on JD Arena: no links from anyone, no phone numbers from a host.
-- Players may send a number, because a host pays prizes directly and may need their eSewa or Khalti number.
create or replace function public._host_chat_filter() returns trigger
language plpgsql security definer set search_path = public as $$
declare v text := translate(new.body, '०१२३४५६७८९', '0123456789');
begin
  -- _chat_respect trusts from_staff, but a host isn't JD staff: hide their rude words too (no strike, the JD team decides)
  if new.from_staff then select r.masked into new.body from public.jd_mask_rude(new.body) r; end if;
  if v ~* '(https?:|www\.|[[:alnum:]-]+\.(com|net|org|np|me|gg|link|ly|co|io|app|xyz|in)([^[:alnum:]]|$))' then
    raise exception 'Links can''t be sent in host chat.';
  end if;
  if new.from_staff and regexp_replace(v, '[[:space:].+,()-]', '', 'g') ~ '[0-9]{7,}' then
    raise exception 'Phone numbers can''t be sent to players. Use Room code for room details.';
  end if;
  return new;
end;
$$;
revoke all on function public._host_chat_filter() from public, anon, authenticated;
drop trigger if exists host_chat_filter on public.host_messages;
create trigger host_chat_filter before insert on public.host_messages for each row execute function public._host_chat_filter();
drop trigger if exists chat_respect on public.host_messages;
create trigger chat_respect before insert on public.host_messages for each row execute function public._chat_respect();

create or replace function public._host_of_event(p_slug text) returns text
language sql stable security definer set search_path = public as $$
  select lower(regexp_replace(trim(coalesce(public.tournament_field(p_slug, 'host'), '')), '^@+', ''))
$$;
revoke all on function public._host_of_event(text) from public, anon, authenticated;

-- the signed-in player's host chats: hosts they've written with, plus active hosts of events they joined
create or replace function public.host_chat_list() returns jsonb
language sql stable security definer set search_path = public as $$
  with mine as (
    select distinct h from (
      select public._host_of_event(r.tournament_slug) h from public.registrations r where r.player_id = auth.uid()
      union select m.host_handle from public.host_messages m where m.player_id = auth.uid()) x
    where h <> '' and exists (select 1 from public.moderators d where d.role = 'host' and lower(d.handle) = x.h))
  select coalesce(jsonb_agg(jsonb_build_object('handle', mine.h, 'body', l.body, 'at', l.created_at, 'mine', not l.from_staff,
           'unread', (select count(*) from public.host_messages u where u.player_id = auth.uid() and u.host_handle = mine.h and u.from_staff and u.read_at is null))
         order by l.created_at desc nulls last), '[]'::jsonb)
    from mine
    left join lateral (select m.body, m.created_at, m.from_staff from public.host_messages m
                        where m.player_id = auth.uid() and m.host_handle = mine.h order by m.id desc limit 1) l on true
$$;

create or replace function public.host_thread(p_handle text, p_before bigint default null, p_after bigint default null)
returns table (id bigint, mine boolean, body text, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.id, not m.from_staff, m.body, m.created_at, m.read_at
    from public.host_messages m
   where m.player_id = auth.uid() and m.host_handle = lower(p_handle)
     and (p_before is null or m.id < p_before) and (p_after is null or m.id > p_after)
   order by m.id desc limit 60
$$;

create or replace function public.host_mark_read(p_handle text) returns void
language sql security definer set search_path = public as $$
  update public.host_messages set read_at = now()
   where player_id = auth.uid() and host_handle = lower(p_handle) and from_staff and read_at is null
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
  if not exists (select 1 from public.host_messages m where m.player_id = v_me and m.host_handle = v_h)
     and not exists (select 1 from public.registrations r where r.player_id = v_me and public._host_of_event(r.tournament_slug) = v_h) then
    raise exception 'Join one of this host''s events to chat with them.';
  end if;
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

revoke all on function public.host_chat_list() from public, anon;
revoke all on function public.host_thread(text, bigint, bigint) from public, anon;
revoke all on function public.host_mark_read(text) from public, anon;
revoke all on function public.host_send(text, text) from public, anon;
grant execute on function public.host_chat_list() to authenticated;
grant execute on function public.host_thread(text, bigint, bigint) to authenticated;
grant execute on function public.host_mark_read(text) to authenticated;
grant execute on function public.host_send(text, text) to authenticated;
