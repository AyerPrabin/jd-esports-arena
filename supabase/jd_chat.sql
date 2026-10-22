-- ── JD Esports chat (2026-10-22) ──
-- One official conversation per player, pinned in Messages as "JD Esports" with a verified tick.
-- Moderators and the admin write to it from /mod/ (mod-panel Edge Function, service role); the player
-- sees every staff message as "JD Esports" and never which moderator wrote it (staff_email stays
-- server-side). The player can reply; replies show up in the moderator panel's Chats tab.
-- It is a real chat, not a notification: nothing goes into the notifications table. New staff
-- messages are pushed to the player's phone by dm-push (kind 'jd').
begin;

create table if not exists public.jd_messages (
  id bigserial primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  from_staff boolean not null,
  staff_email text,                                   -- who on the JD team wrote it (never sent to players)
  body text not null check (length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at timestamptz                                 -- read by the other side
);
create index if not exists jd_messages_player_idx on public.jd_messages (player_id, id desc);
create index if not exists jd_messages_unread_player_idx on public.jd_messages (player_id) where from_staff and read_at is null;
create index if not exists jd_messages_unread_staff_idx on public.jd_messages (id desc) where not from_staff and read_at is null;
alter table public.jd_messages enable row level security;
-- no policies on purpose: players go through the functions below, staff through the service role

-- the signed-in player's JD Esports chat, newest first (60 per page)
create or replace function public.jd_thread(p_before bigint default null)
returns table (id bigint, mine boolean, body text, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.id, not m.from_staff, m.body, m.created_at, m.read_at
  from public.jd_messages m
  where m.player_id = auth.uid() and (p_before is null or m.id < p_before)
  order by m.id desc limit 60
$$;

create or replace function public.jd_send(p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_body text := trim(coalesce(p_body, '')); v_id bigint;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if v_body = '' then raise exception 'Type a message first.'; end if;
  if length(v_body) > 1000 then raise exception 'That message is too long (1000 characters max).'; end if;
  if (select count(*) from public.jd_messages where player_id = v_me and not from_staff and created_at > now() - interval '10 minutes') >= 15 then
    raise exception 'You sent a lot of messages. The JD team will reply soon, wait a few minutes.';
  end if;
  insert into public.jd_messages (player_id, from_staff, body) values (v_me, false, v_body) returning jd_messages.id into v_id;
  return v_id;
end;
$$;

create or replace function public.jd_mark_read()
returns void language sql security definer set search_path = public as $$
  update public.jd_messages set read_at = now()
  where player_id = auth.uid() and from_staff and read_at is null
$$;

-- for the Messages badge + the pinned row: unread count and the last message
create or replace function public.jd_poll()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'unread', (select count(*) from public.jd_messages where player_id = auth.uid() and from_staff and read_at is null),
    'last', (select jsonb_build_object('id', id, 'body', body, 'at', created_at, 'mine', not from_staff)
             from public.jd_messages where player_id = auth.uid() order by id desc limit 1))
$$;

revoke all on function public.jd_thread(bigint) from public, anon;
revoke all on function public.jd_send(text) from public, anon;
revoke all on function public.jd_mark_read() from public, anon;
revoke all on function public.jd_poll() from public, anon;
grant execute on function public.jd_thread(bigint) to authenticated;
grant execute on function public.jd_send(text) to authenticated;
grant execute on function public.jd_mark_read() to authenticated;
grant execute on function public.jd_poll() to authenticated;

-- push each new staff message to the player (dm-push, kind 'jd'; a failed hand-off never blocks the send)
create or replace function public.jd_messages_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ids bigint[];
begin
  select array_agg(id) into v_ids from new_rows where from_staff;
  if v_ids is null then return null; end if;
  begin
    perform net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/dm-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
      ),
      body := jsonb_build_object('ids', to_jsonb(v_ids), 'kind', 'jd')
    );
  exception when others then
    raise warning 'jd_messages_push: %', sqlerrm;
  end;
  return null;
end;
$$;
revoke all on function public.jd_messages_push() from public, anon, authenticated;
drop trigger if exists jd_messages_push on public.jd_messages;
create trigger jd_messages_push after insert on public.jd_messages
  referencing new table as new_rows for each statement execute function public.jd_messages_push();

commit;
