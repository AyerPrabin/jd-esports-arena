-- ── Squad invite links (owner, 28 Oct 2026) ──
-- The squad captain (the account that registers the squad) gets one squad chat named after the squad and a share
-- link jdesport.co.uk/chat/?join=<code>. Anyone signed in who opens it joins that chat - no friend request needed -
-- so the whole squad can talk in the app. Up to 8 players (4 + subs). The captain can make a new link (the old one
-- stops working). Banned players and players the captain blocked cannot join.
begin;
alter table public.chat_groups add column if not exists invite_code text;
alter table public.chat_groups add column if not exists is_squad boolean not null default false;
create unique index if not exists chat_groups_invite_code on public.chat_groups(invite_code) where invite_code is not null;
create unique index if not exists chat_groups_one_squad_chat on public.chat_groups(created_by) where is_squad;

create or replace function public._squad_code()
returns text language sql volatile set search_path = public as $$
  select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + floor(random() * 31)::int, 1), '')
  from generate_series(1, 8)
$$;
revoke all on function public._squad_code() from public, anon, authenticated;

-- the caller's squad chat + invite code (created on first use)
create or replace function public.squad_invite(p_reset boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); g public.chat_groups; v_name text;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  select coalesce(nullif(trim(squad_name), ''), 'My squad') into v_name from public.players where id = v_me;
  perform pg_advisory_xact_lock(hashtext('squadchat:' || v_me::text));
  select * into g from public.chat_groups where created_by = v_me and is_squad;
  if not found then
    insert into public.chat_groups (name, created_by, is_squad, invite_code)
      values (left(v_name, 40), v_me, true, public._squad_code()) returning * into g;
    insert into public.chat_group_members (group_id, player_id, added_by) values (g.id, v_me, v_me)
      on conflict do nothing;
    perform public._group_system(g.id, public._chat_name(v_me) || ' created the squad chat - share the invite link with your squad');
  elsif p_reset or g.invite_code is null then
    update public.chat_groups set invite_code = public._squad_code() where id = g.id returning * into g;
  end if;
  if not public._group_member(g.id, v_me) then   -- captain left once; invite brings them back
    insert into public.chat_group_members (group_id, player_id, added_by) values (g.id, v_me, v_me);
  end if;
  return jsonb_build_object('group_id', g.id, 'name', g.name, 'code', g.invite_code,
    'members', (select count(*) from public.chat_group_members where group_id = g.id), 'max', 8);
end;
$$;
revoke all on function public.squad_invite(boolean) from public, anon;
grant execute on function public.squad_invite(boolean) to authenticated;

-- a teammate opens the link
create or replace function public.join_squad_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); g public.chat_groups; v_count int;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  select * into g from public.chat_groups where invite_code = lower(trim(coalesce(p_code, ''))) and is_squad;
  if not found then raise exception 'This squad invite link is not valid any more - ask your captain for a new one.'; end if;
  if public._group_member(g.id, v_me) then
    return jsonb_build_object('group_id', g.id, 'name', g.name, 'joined', false);
  end if;
  if g.created_by is not null and public._blocked_either(g.created_by, v_me) then
    raise exception 'You can''t join this squad chat.';
  end if;
  perform pg_advisory_xact_lock(hashtext('squadjoin:' || g.id::text));
  select count(*) into v_count from public.chat_group_members where group_id = g.id;
  if v_count >= 8 then raise exception 'This squad chat is full (8 players).'; end if;
  insert into public.chat_group_members (group_id, player_id, added_by, last_read_id)
    values (g.id, v_me, g.created_by, coalesce((select max(id) from public.group_messages where group_id = g.id), 0));
  perform public._group_system(g.id, public._chat_name(v_me) || ' joined with the invite link 👋');
  if g.created_by is not null then
    insert into public.notifications (player_id, title, body)
      values (g.created_by, '👥 ' || public._chat_name(v_me) || ' joined your squad chat', 'Open 💬 Messages to talk with your squad.');
  end if;
  return jsonb_build_object('group_id', g.id, 'name', g.name, 'joined', true);
end;
$$;
revoke all on function public.join_squad_invite(text) from public, anon;
grant execute on function public.join_squad_invite(text) to authenticated;
commit;
