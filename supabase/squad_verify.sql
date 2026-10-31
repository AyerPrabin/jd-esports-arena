-- ── Verify your squad (owner, 31 Oct 2026) ──
-- After joining, the ticket shows "Verify your squad": the captain types the squad's real name and the 4 players
-- (up to 2 subs) with their Free Fire in-game names and UIDs. Stops random squad names ("abc", "test", "1234")
-- and gives the admin a real line-up to check the room against. verify_my_squad() is the only writer.
-- Locked once the room details are sent. Safe to run again.
begin;

alter table public.registrations add column if not exists lineup jsonb;
alter table public.registrations add column if not exists lineup_at timestamptz;

-- true for names that are clearly not a real squad: too short, only numbers/symbols, one letter repeated,
-- or a placeholder word. Fancy Unicode letters are fine (only ASCII digits/symbols count as "no letters").
create or replace function public._junk_squad_name(p text)
returns boolean language sql immutable set search_path = public as $$
  select n is null or char_length(n) < 3
    or n ~ '^[0-9 !-/:-@\[-`{-~]+$'
    or lower(regexp_replace(n, '\s', '', 'g')) ~ '^(.)\1+$'
    or lower(regexp_replace(n, '[\s._-]', '', 'g')) in ('test', 'testing', 'abc', 'abcd', 'abcde', 'asdf', 'qwerty', 'xyz',
      'squad', 'mysquad', 'team', 'myteam', 'yoursquad', 'squadname', 'teamname', 'name', 'na', 'none', 'null', 'random',
      'hello', 'hi', 'ok', 'jd', 'jdesport', 'jdesports', 'jdarena', 'freefire', 'ff', 'guild')
  from (select btrim(coalesce(p, '')) n) s
$$;
revoke all on function public._junk_squad_name(text) from public, anon, authenticated;

create or replace function public.verify_my_squad(p_slug text, p_squad text, p_members jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  r public.registrations;
  v_squad text := btrim(regexp_replace(coalesce(p_squad, ''), '[[:cntrl:]]', '', 'g'));
  v_my_uid text;
  m jsonb;
  v_list jsonb := '[]'::jsonb;
  v_uids text[] := '{}';
  v_uid text; v_name text;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  select * into r from public.registrations
    where tournament_slug = p_slug and player_id = v_me
      and status in ('confirmed', 'approved', 'pending', 'waitlisted')
    for update;
  if not found then raise exception 'Join this tournament first, then verify your squad.'; end if;
  if exists(select 1 from public.tournament_room_codes where tournament_slug = p_slug and sent_at is not null) then
    raise exception 'The room details are already out, so the line-up is locked. Contact JD support if something is wrong.';
  end if;

  if char_length(v_squad) > 30 then raise exception 'Squad name can be up to 30 characters.'; end if;
  if public._junk_squad_name(v_squad) then
    raise exception 'Please use your squad''s real name, the one you play under (not "test", "abc" or only numbers).';
  end if;
  if exists(select 1 from public.registrations
              where tournament_slug = p_slug and id <> r.id and status in ('confirmed', 'approved', 'pending', 'waitlisted')
                and lower(btrim(squad_name)) = lower(v_squad)) then
    raise exception 'Another squad in this tournament already uses that name. Use your own squad''s name.';
  end if;

  if jsonb_typeof(p_members) <> 'array' or jsonb_array_length(p_members) < 4 or jsonb_array_length(p_members) > 6 then
    raise exception 'Add your 4 players (and up to 2 subs).';
  end if;
  for m in select * from jsonb_array_elements(p_members) loop
    v_uid := regexp_replace(coalesce(m->>'uid', ''), '\s', '', 'g');
    v_name := btrim(regexp_replace(coalesce(m->>'name', ''), '[[:cntrl:]]', '', 'g'));
    if char_length(v_name) < 1 or char_length(v_name) > 30 then raise exception 'Every player needs their in-game name (up to 30 characters).'; end if;
    if v_uid !~ '^[0-9]{6,13}$' then raise exception 'UID for % must be 6-13 numbers (Free Fire > profile > UID).', v_name; end if;
    if v_uid = any(v_uids) then raise exception 'UID % is in the line-up twice.', v_uid; end if;
    v_uids := v_uids || v_uid;
    v_list := v_list || jsonb_build_object('name', v_name, 'uid', v_uid);
  end loop;

  -- the captain plays in their own squad: if their account has a UID, it must be in the line-up
  select ff_uid into v_my_uid from public.players where id = v_me;
  if v_my_uid is not null and not (v_my_uid = any(v_uids)) then
    raise exception 'Your own UID (%) must be in the line-up.', v_my_uid;
  end if;

  -- one player, one squad per tournament
  if exists(select 1 from public.registrations o, jsonb_array_elements(o.lineup) x
              where o.tournament_slug = p_slug and o.id <> r.id and o.status in ('confirmed', 'approved', 'pending', 'waitlisted')
                and x->>'uid' = any(v_uids)) then
    raise exception 'One of these UIDs is already in another squad''s line-up for this tournament. Each player can play for one squad only.';
  end if;

  update public.registrations set squad_name = v_squad, lineup = v_list, lineup_at = now() where id = r.id;
  update public.players set squad_name = v_squad where id = v_me;
  return jsonb_build_object('squad_name', v_squad, 'lineup', v_list, 'lineup_at', now());
end $$;
revoke all on function public.verify_my_squad(text, text, jsonb) from public, anon;
grant execute on function public.verify_my_squad(text, text, jsonb) to authenticated;

commit;
