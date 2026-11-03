-- Chat photos/videos v2 (2026-11-03): small files, max 3 videos per player, deleted after 30 days.
-- Builds on teammate_finder.sql (private bucket chat-media, send_dm_media).
--  * Photos are shrunk in the app before upload (1280px WebP/JPEG, usually 100-300 KB).
--  * Videos: 15 MB max file, and a player can have at most 3 sent videos stored at a time.
--  * Every file is deleted 30 days after upload; files uploaded but never sent go after 1 day.
--    The chat-media-cleanup edge function removes them through the Storage API (deleting rows in
--    storage.objects would leave the files behind), then marks the messages as expired.

update storage.buckets set file_size_limit = 15728640 where id = 'chat-media';

create or replace function public.send_dm_media(p_to uuid, p_path text, p_type text, p_caption text default '')
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_id bigint; v_cap text := left(btrim(coalesce(p_caption, '')), 500); v_mime text;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  if not public._are_friends(v_me, p_to) or public._blocked_either(v_me, p_to) then
    raise exception 'You can only message your friends.';
  end if;
  if p_type not in ('image','video') then raise exception 'Only photos and videos.'; end if;
  select o.metadata->>'mimetype' into v_mime from storage.objects o where o.bucket_id = 'chat-media' and o.name = p_path;
  if p_path is null or split_part(p_path, '/', 1) <> v_me::text or v_mime is null
     or exists(select 1 from public.dm_messages where media = p_path) then
    raise exception 'Upload the file first.';
  end if;
  -- the stored file decides the type, so a video can't be sent as a "photo" to dodge the limit
  if v_mime not like p_type || '/%' then raise exception 'That file type does not match.'; end if;
  if p_type = 'video' and (select count(*) from public.dm_messages
       where sender = v_me and media_type = 'video' and media is not null) >= 3 then
    raise exception 'You can keep 3 videos in chat at a time. Videos are deleted 30 days after sending, then you can send more.';
  end if;
  if (select count(*) from public.dm_messages where sender = v_me and created_at > now() - interval '10 seconds') >= 8 then
    raise exception 'Slow down a little.';
  end if;
  insert into public.dm_messages (sender, recipient, body, media, media_type)
    values (v_me, p_to, coalesce(nullif(v_cap, ''), case when p_type = 'image' then '📷 Photo' else '🎬 Video' end), p_path, p_type)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.send_dm_media(uuid, text, text, text) from public, anon;
grant execute on function public.send_dm_media(uuid, text, text, text) to authenticated;

-- for the cleanup function only: files older than 30 days, or unsent and older than 1 day
create or replace function public.chat_media_expired(p_limit int default 500)
returns setof text language sql stable security definer set search_path = public, storage as $$
  select o.name from storage.objects o
  where o.bucket_id = 'chat-media'
    and (o.created_at < now() - interval '30 days'
         or (o.created_at < now() - interval '1 day' and not exists(select 1 from public.dm_messages m where m.media = o.name)))
  order by o.created_at
  limit least(greatest(coalesce(p_limit, 500), 1), 1000)
$$;
revoke all on function public.chat_media_expired(int) from public, anon, authenticated;
grant execute on function public.chat_media_expired(int) to service_role;

-- after the files are gone: the message stays, with a note instead of the file
create or replace function public.chat_media_forget(p_names text[])
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.dm_messages
     set body = case when media_type = 'video' then '🎬 Video deleted after 30 days' else '📷 Photo deleted after 30 days' end,
         media = null
   where media = any(p_names);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.chat_media_forget(text[]) from public, anon, authenticated;
grant execute on function public.chat_media_forget(text[]) to service_role;

-- daily at 03:20 UTC
select cron.unschedule('chat-media-cleanup') where exists(select 1 from cron.job where jobname = 'chat-media-cleanup');
select cron.schedule('chat-media-cleanup', '20 3 * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/chat-media-cleanup',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 60000)
$$);
