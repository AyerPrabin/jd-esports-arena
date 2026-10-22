-- ── ZULU and JD Esports are separate chats (2026-10-22) ──
-- The owner's rule: the JD Esports chat is people only (moderators + admin). Everything automatic or AI
-- (welcome, registration, reminders, points, results) shows in the player's ZULU chat instead.
-- jd_messages.channel: 'jd' = JD Esports (human staff <-> player), 'zulu' = ZULU's automatic messages.
-- ZULU no longer auto-replies inside JD Esports; players ask ZULU in the ZULU chat (zulu-ai-reply).
begin;

alter table public.jd_messages add column if not exists channel text not null default 'jd';
alter table public.jd_messages drop constraint if exists jd_messages_channel_check;
alter table public.jd_messages add constraint jd_messages_channel_check check (channel in ('jd', 'zulu'));
update public.jd_messages set channel = 'zulu' where staff_email like 'zulu%' and channel <> 'zulu';
create index if not exists jd_messages_player_channel_idx on public.jd_messages (player_id, channel, id desc);

-- ZULU's automatic messages go to the ZULU chat
create or replace function public._zulu_say(p_player uuid, p_key text, p_body text, p_push boolean default false)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_player is null or coalesce(p_body, '') = '' then return false; end if;
  insert into public.zulu_auto_log (player_id, key) values (p_player, p_key) on conflict do nothing;
  if not found then return false; end if;
  insert into public.jd_messages (player_id, from_staff, staff_email, body, push, channel)
  values (p_player, true, 'zulu', left(p_body, 1000), p_push, 'zulu');
  return true;
exception when others then
  raise warning '_zulu_say %: %', p_key, sqlerrm;
  return false;
end;
$$;
revoke all on function public._zulu_say(uuid, text, text, boolean) from public, anon, authenticated;

-- JD Esports: humans only
drop function if exists public.jd_thread(bigint);
create or replace function public.jd_thread(p_before bigint default null)
returns table (id bigint, mine boolean, body text, created_at timestamptz, read_at timestamptz, ai boolean)
language sql stable security definer set search_path = public as $$
  select m.id, not m.from_staff, m.body, m.created_at, m.read_at, false
  from public.jd_messages m
  where m.player_id = auth.uid() and m.channel = 'jd' and (p_before is null or m.id < p_before)
  order by m.id desc limit 60
$$;
create or replace function public.jd_mark_read()
returns void language sql security definer set search_path = public as $$
  update public.jd_messages set read_at = now()
  where player_id = auth.uid() and channel = 'jd' and from_staff and read_at is null
$$;
create or replace function public.jd_poll()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'unread', (select count(*) from public.jd_messages where player_id = auth.uid() and channel = 'jd' and from_staff and read_at is null),
    'last', (select jsonb_build_object('id', id, 'body', body, 'at', created_at, 'mine', not from_staff)
             from public.jd_messages where player_id = auth.uid() and channel = 'jd' order by id desc limit 1),
    'zulu_unread', (select count(*) from public.jd_messages where player_id = auth.uid() and channel = 'zulu' and read_at is null))
$$;

-- ZULU chat: the automatic messages (newest first)
create or replace function public.zulu_feed()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'body', body, 'created_at', created_at, 'read_at', read_at) order by id desc), '[]'::jsonb)
  from (select id, body, created_at, read_at from public.jd_messages
         where player_id = auth.uid() and channel = 'zulu' order by id desc limit 30) x
$$;
create or replace function public.zulu_feed_read()
returns void language sql security definer set search_path = public as $$
  update public.jd_messages set read_at = now() where player_id = auth.uid() and channel = 'zulu' and read_at is null
$$;
revoke all on function public.jd_thread(bigint) from public, anon;
revoke all on function public.zulu_feed() from public, anon;
revoke all on function public.zulu_feed_read() from public, anon;
grant execute on function public.jd_thread(bigint) to authenticated;
grant execute on function public.zulu_feed() to authenticated;
grant execute on function public.zulu_feed_read() to authenticated;

-- push staff messages marked push; no AI auto-reply inside JD Esports any more
create or replace function public.jd_messages_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ids bigint[];
begin
  select array_agg(id) into v_ids from new_rows where from_staff and push;
  if v_ids is null then return null; end if;
  begin
    perform net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/dm-push',
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
      body := jsonb_build_object('ids', to_jsonb(v_ids), 'kind', 'jd'));
  exception when others then
    raise warning 'jd_messages_push: %', sqlerrm;
  end;
  return null;
end;
$$;
revoke all on function public.jd_messages_push() from public, anon, authenticated;

commit;
