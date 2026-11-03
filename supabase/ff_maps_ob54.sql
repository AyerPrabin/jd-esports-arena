-- 2026-11-03 Free Fire map pool (OB54): Alpine (and Bermuda 2.0) removed, Solara added.
-- New challenges can pick Bermuda, Purgatory, Kalahari, NeXTerra or Solara. Old Alpine challenges stay valid.
begin;
alter table public.challenges drop constraint if exists challenges_map_check;
alter table public.challenges add constraint challenges_map_check check (map is null or map in ('Bermuda','Purgatory','Kalahari','Alpine','NeXTerra','Solara'));
CREATE OR REPLACE FUNCTION public.create_challenge(p_mode text, p_stake integer, p_invite text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_char_skill boolean DEFAULT true, p_gun_attr boolean DEFAULT false, p_ammo text DEFAULT 'limited'::text, p_rounds integer DEFAULT 7, p_map text DEFAULT NULL::text, p_gloo text DEFAULT 'limited'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_inv uuid; c public.challenges;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform public._challenge_player_ok(auth.uid());
  if p_mode not in ('1v1','2v2','3v3','4v4') then raise exception 'Pick a mode: 1v1, 2v2, 3v3 or 4v4.'; end if;
  if p_stake is null or p_stake < 10 or p_stake > 500 then raise exception 'Stake must be between 10 and 500 points.'; end if;
  if coalesce(p_ammo, 'limited') not in ('limited','unlimited') then raise exception 'Ammo must be limited or unlimited.'; end if;
  if coalesce(p_gloo, 'limited') not in ('limited','unlimited') then raise exception 'Gloo walls must be limited or unlimited.'; end if;
  if coalesce(p_rounds, 7) not in (7, 13) then raise exception 'Rounds must be first to 4 or first to 7.'; end if;
  p_map := nullif(trim(coalesce(p_map, '')), '');
  if p_map is not null and p_map not in ('Bermuda','Purgatory','Kalahari','NeXTerra','Solara') then raise exception 'Pick a map in the current pool: Bermuda, Purgatory, Kalahari, NeXTerra or Solara.'; end if;
  if (select count(*) from public.challenges where creator = auth.uid() and status = 'open') >= 3 then
    raise exception 'You already have 3 open challenges. Cancel one or wait for them to be accepted.';
  end if;
  p_invite := nullif(trim(regexp_replace(coalesce(p_invite, ''), '^@', '')), '');
  if p_invite is not null then
    select id into v_inv from public.players where lower(username) = lower(p_invite) or upper(player_tag) = upper(p_invite) limit 1;
    if v_inv is null then raise exception 'No player called %.', p_invite; end if;
    if v_inv = auth.uid() then raise exception 'You can''t challenge yourself.'; end if;
  end if;
  insert into public.challenges (creator, invited, mode, stake, note, char_skill, gun_attr, ammo, rounds, map, gloo_wall)
  values (auth.uid(), v_inv, p_mode, p_stake, nullif(trim(coalesce(p_note, '')), ''),
          coalesce(p_char_skill, true), coalesce(p_gun_attr, false), coalesce(p_ammo, 'limited'), coalesce(p_rounds, 7), p_map,
          coalesce(p_gloo, 'limited'))
  returning * into c;
  perform public._wallet_apply(auth.uid(), -p_stake, 'challenge_stake', c.id::text, p_mode || ' challenge');
  if v_inv is not null then
    insert into public.notifications (player_id, title, body)
    values (v_inv, '⚔️ ' || public._challenge_name(auth.uid()) || ' challenged you',
      p_mode || ' Clash Squad for ' || p_stake || ' points each — winner takes ' || (p_stake * 2 - 2 * public.challenge_fee_per_player()) || '. ' || public._challenge_rules(c) || '. Open Challenges to accept.');
  end if;
  return c.id;
end;
$function$;
commit;
