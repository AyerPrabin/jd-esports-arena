-- ── Find Teammate board (2026-11-02) ──
-- Players post "I'm a Rusher looking for a squad" or "my squad needs a Sniper", free or for a fee,
-- for one event or any event. Shown on the home page (#teammates, teammates.js) and opened from the
-- 👥 button on each event card. "Team up" sends a friend request with the post's context, so the
-- two players chat in 💬 Messages once it is accepted (DMs stay friends-only: no stranger spam).
-- * A Free Fire UID + in-game name are required to post AND to team up. Posting shows them on the
--   card (the form says so); the UID is only returned to signed-in players.
-- * Roles: presets (Rusher, Sniper, Supporter, IGL, Bomber, All-rounder) or anything the player types.
-- * Paid posts ask a fee in JD points only (never eSewa between players). After teaming up, the hirer
--   pays it with lfg_pay(): points move straight from wallet to wallet with ledger rows on both sides.
--   Unlimited (staff) wallets can't pay, so no points are made out of nothing.
-- * Max 3 live posts per player, each lives 7 days. Banned and blocked players are hidden.
-- RLS on, no policies: everything goes through the SECURITY DEFINER RPCs below. Safe to run again.
begin;

create table if not exists public.teammate_posts (
  id bigserial primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  kind text not null check (kind in ('player','squad')),          -- player: needs a squad · squad: needs a player
  roles text[] not null check (cardinality(roles) between 1 and 5),   -- presets or the player's own words, 1-20 chars each
  pay text not null default 'free' check (pay in ('free','paid')),
  amount int check (amount is null or amount between 1 and 5000),   -- JD points
  tournament text not null default '' check (char_length(tournament) <= 80),   -- '' = any event
  note text not null default '' check (char_length(note) <= 160),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days'
);
create unique index if not exists teammate_posts_one_per_event on public.teammate_posts (player_id, tournament);
create index if not exists teammate_posts_live_idx on public.teammate_posts (expires_at desc);
alter table public.teammate_posts enable row level security;

-- create or refresh my post for this event (re-posting bumps it to the top for another 7 days)
create or replace function public.lfg_post(p_kind text, p_roles text[], p_pay text, p_amount int, p_tournament text, p_note text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_t text := btrim(coalesce(p_tournament, '')); v_id bigint;
  v_roles text[] := (select array_agg(distinct x) from (select btrim(regexp_replace(r, '[[:cntrl:]]', '', 'g')) x
                      from unnest(coalesce(p_roles, '{}')) r) y where x <> '');
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  if not exists(select 1 from public.players where id = v_me and ff_uid is not null and ff_name is not null) then
    raise exception 'Add your Free Fire UID and in-game name first.';
  end if;
  delete from public.teammate_posts where expires_at < now() - interval '30 days';   -- tidy old posts
  if v_roles is null then raise exception 'Pick at least one role.'; end if;
  if cardinality(v_roles) > 5 or exists(select 1 from unnest(v_roles) r where char_length(r) > 20) then
    raise exception 'Up to 5 roles, 20 characters each.';
  end if;
  if p_pay = 'paid' and coalesce(p_amount, 0) not between 1 and 5000 then raise exception 'Enter the fee: 1-5000 JD points.'; end if;
  if (select count(*) from public.teammate_posts where player_id = v_me and expires_at > now() and tournament <> v_t) >= 3 then
    raise exception 'You already have 3 live posts. Delete one first.';
  end if;
  insert into public.teammate_posts (player_id, kind, roles, pay, amount, tournament, note)
    values (v_me, p_kind, v_roles, p_pay, case when p_pay = 'paid' then p_amount end, v_t,
            btrim(regexp_replace(coalesce(p_note, ''), '[[:cntrl:]]', ' ', 'g')))
  on conflict (player_id, tournament) do update set kind = excluded.kind, roles = excluded.roles, pay = excluded.pay,
    amount = excluded.amount, note = excluded.note, created_at = now(), expires_at = now() + interval '7 days'
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.lfg_delete(p_id bigint)
returns void language sql security definer set search_path = public as $$
  delete from public.teammate_posts where id = p_id and player_id = auth.uid()
$$;

-- live posts, newest first (mine first). p_tournament: that event's posts plus "any event" ones.
create or replace function public.lfg_list(p_tournament text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x.j order by x.mine desc, x.created_at desc), '[]'::jsonb) from (
    select p.created_at, p.player_id = auth.uid() as mine, jsonb_build_object(
      'id', p.id, 'player', pl.id, 'username', pl.username, 'logo', pl.squad_logo,
      'ign', pl.ff_name, 'uid', case when auth.uid() is not null then pl.ff_uid end,
      'kind', p.kind, 'roles', p.roles, 'pay', p.pay, 'amount', p.amount, 'tournament', p.tournament,
      'note', p.note, 'at', p.created_at, 'mine', p.player_id = auth.uid(),
      -- you and them, for the card's button: friend | sent (you asked) | received (they asked) | null
      'rel', case when auth.uid() is not null and p.player_id <> auth.uid() then
        (select case when f.status = 'accepted' then 'friend' when f.requester = auth.uid() then 'sent' else 'received' end
           from public.friendships f
          where least(f.requester, f.addressee) = least(auth.uid(), p.player_id)
            and greatest(f.requester, f.addressee) = greatest(auth.uid(), p.player_id) limit 1) end) as j
    from public.teammate_posts p join public.players pl on pl.id = p.player_id
    where p.expires_at > now() and pl.ff_uid is not null
      and (p_tournament is null or p.tournament in ('', p_tournament))
      and not exists(select 1 from public.banned_players b where b.player_id = p.player_id)
      and (auth.uid() is null or not public._blocked_either(auth.uid(), p.player_id))
    order by p.player_id = auth.uid() desc, p.created_at desc
    limit 60
  ) x
$$;

-- "Team up": friend request carrying the post's context. Returns sent | pending | accepted | friend
create or replace function public.lfg_contact(p_id bigint)
returns text language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); p public.teammate_posts; f public.friendships; v_ign text;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  select ff_name into v_ign from public.players where id = v_me and ff_uid is not null;
  if v_ign is null then raise exception 'Add your Free Fire UID and in-game name first.'; end if;
  select * into p from public.teammate_posts where id = p_id and expires_at > now();
  if p.id is null or public._blocked_either(v_me, p.player_id) then raise exception 'That post is no longer up.'; end if;
  if p.player_id = v_me then raise exception 'That''s your own post.'; end if;
  select * into f from public.friendships
    where least(requester, addressee) = least(v_me, p.player_id) and greatest(requester, addressee) = greatest(v_me, p.player_id);
  if f.status = 'accepted' then return 'friend'; end if;
  if f.id is not null and f.requester = v_me then return 'pending'; end if;
  if f.id is not null then perform public.respond_friend_request(p.player_id, true); return 'accepted'; end if;
  -- same cap + log as send_friend_request, so cancel/re-send can't spam notifications
  if (select count(*) from public.friend_request_log where requester = v_me and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Too many requests. Try again in a while.';
  end if;
  insert into public.friendships (requester, addressee) values (v_me, p.player_id);
  if not exists(select 1 from public.friend_request_log where requester = v_me and addressee = p.player_id
                and created_at > now() - interval '24 hours') then
    insert into public.notifications (player_id, title, body) values (p.player_id,
      '👥 ' || public._chat_name(v_me) || ' wants to team up',
      left(v_ign || ' saw your ' || case when p.kind = 'player' then 'teammate' else 'squad' end || ' post'
        || case when p.tournament <> '' then ' for ' || p.tournament else '' end
        || '. Open 💬 Messages to accept and chat.', 300));
  end if;
  insert into public.friend_request_log (requester, addressee) values (v_me, p.player_id);
  return 'sent';
end $$;

revoke all on function public.lfg_post(text, text[], text, int, text, text) from public, anon;
revoke all on function public.lfg_delete(bigint) from public, anon;
revoke all on function public.lfg_list(text) from public;
revoke all on function public.lfg_contact(bigint) from public, anon;
grant execute on function public.lfg_post(text, text[], text, int, text, text) to authenticated;
grant execute on function public.lfg_delete(bigint) to authenticated;
grant execute on function public.lfg_list(text) to anon, authenticated;
grant execute on function public.lfg_contact(bigint) to authenticated;

-- ── pay a teammate in JD points (direct: wallet to wallet, the post's fee, only once you're friends) ──
alter table public.wallet_ledger drop constraint if exists wallet_ledger_reason_check;
alter table public.wallet_ledger add constraint wallet_ledger_reason_check check (reason in
  ('load','entry','effect','withdraw','withdraw_returned','refund','adjust','prize','challenge_stake','challenge_win',
   'challenge_refund','optimizer','pass','referral','teammate_pay','teammate_paid'));

drop function if exists public.lfg_pay(bigint);
-- p_amount = the fee the payer saw; if the poster changed it since, nothing is paid
create or replace function public.lfg_pay(p_id bigint, p_amount int)
returns int language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); p public.teammate_posts; v_bal int; v_ref text;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  select * into p from public.teammate_posts where id = p_id and expires_at > now() for update;
  if p.id is null then raise exception 'That post is no longer up.'; end if;
  if p.player_id = v_me then raise exception 'That''s your own post.'; end if;
  if exists(select 1 from public.banned_players where player_id in (v_me, p.player_id)) then
    raise exception 'This payment is not allowed.';
  end if;
  if p.pay <> 'paid' or p.amount is null then raise exception 'This teammate plays for free.'; end if;
  if p_amount is distinct from p.amount then raise exception 'The fee changed to % pts. Check it and pay again.', p.amount; end if;
  if not public._are_friends(v_me, p.player_id) or public._blocked_either(v_me, p.player_id) then
    raise exception 'Team up first: they must accept your request before you pay.';
  end if;
  if coalesce((select unlimited from public.wallets where player_id = v_me), false) then
    raise exception 'Staff wallets can''t pay teammates.';
  end if;
  v_ref := 'tm:' || p.id || ':' || v_me;
  if exists(select 1 from public.wallet_ledger where player_id = v_me and reason = 'teammate_pay' and ref = v_ref
            and created_at > now() - interval '7 days') then
    raise exception 'You already paid for this post.';
  end if;
  if coalesce((select -sum(delta) from public.wallet_ledger where player_id = v_me and reason = 'teammate_pay'
               and created_at > now() - interval '1 day'), 0) + p.amount > 10000 then
    raise exception 'Daily limit: 10000 points to teammates.';
  end if;
  v_bal := public._wallet_apply(v_me, -p.amount, 'teammate_pay', v_ref, 'Paid ' || public._chat_name(p.player_id));
  perform public._wallet_apply(p.player_id, p.amount, 'teammate_paid', v_ref, 'From ' || public._chat_name(v_me));
  insert into public.notifications (player_id, title, body) values (p.player_id,
    '🪙 ' || public._chat_name(v_me) || ' paid you ' || p.amount || ' pts',
    'Teammate fee' || case when p.tournament <> '' then ' for ' || left(p.tournament, 80) else '' end || '. It''s in your points wallet.');
  return v_bal;
end $$;
revoke all on function public.lfg_pay(bigint, int) from public, anon;
grant execute on function public.lfg_pay(bigint, int) to authenticated;

-- ── photos + videos in 1:1 chat (up to 25 MB) ──
-- Private bucket: files sit at chat-media/<sender id>/<name>; only the two people in that chat can open one
-- (short-lived signed links). The app keeps a private offline copy (Cache Storage), never in the gallery or Files.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-media', 'chat-media', false, 26214400,
        array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','video/quicktime'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

alter table public.dm_messages add column if not exists media text;
alter table public.dm_messages add column if not exists media_type text check (media_type in ('image','video'));
create index if not exists dm_messages_media_idx on public.dm_messages (media) where media is not null;

-- per player: 20 uploads an hour and 150 MB a day; whole bucket: 700 MB, so chat can never fill the
-- project's storage (the 'app' bucket hosts the APK). Files uploaded but never sent still count.
create or replace function public._chat_media_quota_ok()
returns boolean language sql stable security definer set search_path = public, storage as $$
  select (select count(*) from storage.objects where bucket_id = 'chat-media'
          and name like auth.uid()::text || '/%' and created_at > now() - interval '1 hour') < 20
     and (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects where bucket_id = 'chat-media'
          and name like auth.uid()::text || '/%' and created_at > now() - interval '1 day') < 150 * 1024 * 1024
     and (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects where bucket_id = 'chat-media') < 700 * 1024 * 1024
$$;
revoke all on function public._chat_media_quota_ok() from public, anon;
grant execute on function public._chat_media_quota_ok() to authenticated;

drop policy if exists "chat media upload own folder" on storage.objects;
create policy "chat media upload own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-media' and (storage.foldername(name))[1] = auth.uid()::text and public._chat_media_quota_ok());
drop policy if exists "chat media read by chat members" on storage.objects;
create policy "chat media read by chat members" on storage.objects for select to authenticated
  using (bucket_id = 'chat-media' and ((storage.foldername(name))[1] = auth.uid()::text
         or exists(select 1 from public.dm_messages m where m.media = storage.objects.name and auth.uid() in (m.sender, m.recipient))));

create or replace function public.send_dm_media(p_to uuid, p_path text, p_type text, p_caption text default '')
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_id bigint; v_cap text := left(btrim(coalesce(p_caption, '')), 500);
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  if not public._are_friends(v_me, p_to) or public._blocked_either(v_me, p_to) then
    raise exception 'You can only message your friends.';
  end if;
  if p_type not in ('image','video') then raise exception 'Only photos and videos.'; end if;
  if p_path is null or split_part(p_path, '/', 1) <> v_me::text
     or not exists(select 1 from storage.objects where bucket_id = 'chat-media' and name = p_path)
     or exists(select 1 from public.dm_messages where media = p_path) then
    raise exception 'Upload the file first.';
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

-- dm_thread now also returns the file (older app versions ignore the extra columns)
drop function if exists public.dm_thread(uuid, bigint, bigint);
create function public.dm_thread(p_with uuid, p_before bigint default null, p_after bigint default null)
returns table (id bigint, mine boolean, body text, created_at timestamptz, read_at timestamptz, media text, media_type text)
language sql stable security definer set search_path = public as $$
  select m.id, m.sender = auth.uid(), m.body, m.created_at, m.read_at, m.media, m.media_type
  from public.dm_messages m
  where auth.uid() is not null
    and least(m.sender, m.recipient) = least(auth.uid(), p_with) and greatest(m.sender, m.recipient) = greatest(auth.uid(), p_with)
    and (p_before is null or m.id < p_before)
    and (p_after is null or m.id > p_after)
  order by m.id desc
  limit 60
$$;
revoke all on function public.dm_thread(uuid, bigint, bigint) from public, anon;
grant execute on function public.dm_thread(uuid, bigint, bigint) to authenticated;
commit;
