-- Solo, duo and squad events, and big events split into groups plus a Final (owner's OK 7 Nov 2026).
-- An event's "mode" lives in tournaments.json: 'solo' | 'duo' | 'squad' (no value = squad).
-- A drawn group or Final carries "parent": nobody registers on one directly, mod-panel moves squads in.
-- Moving a registration keeps its paid_points, card and line-up, so nobody pays twice.
-- Undo: event_modes_groups_rollback.sql

create or replace function public._event_mode(p_slug text) returns text
language sql stable security definer set search_path = public as $$
  select case lower(coalesce(public.tournament_field(p_slug, 'mode'), '')) when 'solo' then 'solo' when 'duo' then 'duo' else 'squad' end
$$;
revoke all on function public._event_mode(text) from public, anon, authenticated;

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
  v_mode text := public._event_mode(p_slug);
  v_need int := case v_mode when 'solo' then 1 when 'duo' then 2 else 4 end;
  v_subs int := case v_mode when 'solo' then 0 when 'duo' then 1 else 2 end;
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

  if jsonb_typeof(p_members) <> 'array' or jsonb_array_length(p_members) < v_need or jsonb_array_length(p_members) > v_need + v_subs then
    raise exception 'This is a % event: add % player(s), and up to % sub(s).', v_mode, v_need, v_subs;
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
  -- only a squad event changes the player's saved squad name and line-up (see _save_lineup_on_player)
  if v_mode = 'squad' then update public.players set squad_name = v_squad where id = v_me; end if;
  return jsonb_build_object('squad_name', v_squad, 'lineup', v_list, 'lineup_at', now());
end $$;
revoke all on function public.verify_my_squad(text, text, jsonb) from public, anon;
grant execute on function public.verify_my_squad(text, text, jsonb) to authenticated;

-- a saved squad of 4 must not fill in a solo or duo line-up
create or replace function public._reg_saved_lineup() returns trigger
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if new.lineup is not null or public._event_mode(new.tournament_slug) <> 'squad' then return new; end if;
  select squad_lineup into v from public.players where id = new.player_id;
  if v is null or jsonb_typeof(v->'members') <> 'array'
     or lower(btrim(coalesce(v->>'squad', ''))) <> lower(btrim(coalesce(new.squad_name, ''))) then return new; end if;
  if exists(select 1 from public.registrations o, jsonb_array_elements(o.lineup) x, jsonb_array_elements(v->'members') y
              where o.tournament_slug = new.tournament_slug and o.player_id <> new.player_id
                and o.status in ('confirmed', 'approved', 'pending', 'waitlisted')
                and x->>'uid' = y->>'uid') then return new; end if;
  new.lineup := v->'members';
  new.lineup_at := now();
  return new;
end $$;

-- and a solo or duo line-up must not replace the saved squad
create or replace function public._save_lineup_on_player() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.lineup is not null and new.lineup_at is distinct from old.lineup_at and public._event_mode(new.tournament_slug) = 'squad' then
    update public.players set squad_lineup = jsonb_build_object('squad', new.squad_name, 'members', new.lineup)
      where id = new.player_id;
  end if;
  return new;
end $$;

-- nobody joins a drawn group or Final directly
create or replace function public._reg_no_group_join() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.tournament_field(new.tournament_slug, 'parent'), '') <> '' then
    raise exception 'Groups are already drawn for this event, so it can''t be joined now.';
  end if;
  return new;
end $$;
revoke all on function public._reg_no_group_join() from public, anon, authenticated;
drop trigger if exists reg_no_group_join on public.registrations;
create trigger reg_no_group_join before insert on public.registrations for each row execute function public._reg_no_group_join();

-- mod-panel only: all the moves of one draw or one group's top squads succeed together or not at all
create or replace function public.event_move_regs(p_moves jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare m jsonb; v_n int := 0; v_done int;
begin
  for m in select * from jsonb_array_elements(p_moves) loop
    update public.registrations set tournament_slug = m->>'to'
     where id = (m->>'id')::uuid and tournament_slug = m->>'from';
    get diagnostics v_done = row_count;
    if v_done <> 1 then raise exception 'Registration % is no longer in %.', m->>'id', m->>'from'; end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function public.event_move_regs(jsonb) from public, anon, authenticated;
grant execute on function public.event_move_regs(jsonb) to service_role;
