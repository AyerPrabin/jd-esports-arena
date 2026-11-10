-- challenge_loser_no_shot.sql (10 Nov 2026): owner: "don't ask for the lost people, only in winners".
-- report_challenge: a WIN still needs its Victory screenshot (+ saved FF UID); "we lost" needs no photo.
-- Everything else is the same as challenge_result_shots.sql (run that first; it is live since 10 Nov).
-- Also: a saved Free Fire UID AND in-game name are required to create or accept a challenge, and to report a win.
-- Run: npx supabase db query --remote --yes -f supabase/challenge_loser_no_shot.sql

create or replace function public.report_challenge(p_id uuid, p_result text, p_shot text default null)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare c public.challenges; v_me_creator boolean; v_other uuid; v_mine text; v_theirs text; v_mime text; v_uid text; v_name text;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_result not in ('won','lost') then raise exception 'Report won or lost.'; end if;
  select * into c from public.challenges where id = p_id;
  -- only the WINNER sends a screenshot; "we lost" needs no photo (owner, 10 Nov 2026)
  if p_result = 'won' then
  if p_shot is null or btrim(p_shot) = '' then
    raise exception 'Send your Victory screenshot. Refresh the page if you don''t see the photo step.';
  end if;
  select coalesce(trim(ff_uid), ''), coalesce(trim(ff_name), '') into v_uid, v_name from public.players where id = auth.uid();
  if coalesce(v_uid, '') = '' or coalesce(v_name, '') = '' then
    raise exception 'Save your Free Fire UID and in-game name first (tap your name > Game UID & name), so the mod can match you in the screenshot.';
  end if;
  -- the photo must be taken for THIS match: uploaded after the challenge was accepted (no old Victory screens)
  select o.metadata->>'mimetype' into v_mime from storage.objects o where o.bucket_id = 'chat-media' and o.name = p_shot
    and c.accepted_at is not null and o.created_at >= c.accepted_at;
  if split_part(p_shot, '/', 1) <> auth.uid()::text or v_mime is null
     or exists(select 1 from public.challenge_messages where media = p_shot)
     or exists(select 1 from public.dm_messages where media = p_shot) then
    raise exception 'Upload a screenshot of this match (taken after the challenge was accepted).';
  end if;
  if v_mime not like 'image/%' then raise exception 'The result must be a photo or screenshot.'; end if;
  else
    p_shot := null;
  end if;
  select * into c from public.challenges where id = p_id for update;
  if c.id is null or auth.uid() not in (c.creator, c.opponent) then raise exception 'Challenge not found.'; end if;
  if c.status <> 'accepted' then raise exception 'This challenge isn''t waiting for a result.'; end if;
  v_me_creator := auth.uid() = c.creator;
  v_other := case when v_me_creator then c.opponent else c.creator end;
  if (v_me_creator and c.creator_claim is not null) or (not v_me_creator and c.opponent_claim is not null) then
    raise exception 'You already reported this result.';
  end if;
  if v_me_creator then
    update public.challenges set creator_claim = p_result, creator_shot = p_shot, claim_at = coalesce(claim_at, now()) where id = p_id returning * into c;
  else
    update public.challenges set opponent_claim = p_result, opponent_shot = p_shot, claim_at = coalesce(claim_at, now()) where id = p_id returning * into c;
  end if;
  if p_shot is not null then
    insert into public.challenge_messages (challenge_id, sender, kind, body, media)
    values (p_id, auth.uid(), 'image',
      '📷 Result: Victory · FF ' || case when v_name <> '' then v_name || ' · ' else '' end || 'UID ' || v_uid, p_shot);
  end if;
  v_mine := p_result;
  v_theirs := case when v_me_creator then c.opponent_claim else c.creator_claim end;

  if v_mine = 'lost' and (v_theirs is null or v_theirs = 'won') then
    perform public._challenge_payout(p_id, v_other, 'loser confirmed');
    return 'completed';
  end if;
  if v_mine = 'won' and v_theirs = 'lost' then
    perform public._challenge_payout(p_id, auth.uid(), 'both agreed');
    return 'completed';
  end if;
  if v_theirs is not null then
    update public.challenges set status = 'disputed' where id = p_id;
    perform public._challenge_tell_staff('⚖️ Challenge disputed',
      'Both sides say they won a ' || c.mode || ' challenge (' || c.stake * 2 || ' pts). Both screenshots, with each side''s FF name and UID, are in the match chat. Decide it in Mod panel → Challenges.');
    insert into public.notifications (player_id, title, body) values
      (c.creator, 'Challenge under review', 'Both sides say they won, so a JD mod will decide from both screenshots.'),
      (c.opponent, 'Challenge under review', 'Both sides say they won, so a JD mod will decide from both screenshots.');
    return 'disputed';
  end if;
  insert into public.notifications (player_id, title, body)
  values (v_other, '⚔️ Send your result in 10 minutes', public._challenge_name(auth.uid()) || ' says they won the ' || c.mode
    || ' challenge and sent their Victory screenshot. Open the challenge within 10 minutes: tap We lost, or We won with your own Victory screenshot. No answer = their win stands.');
  return 'waiting';
end;
$function$;
revoke all on function public.report_challenge(uuid, text, text) from public, anon;
grant execute on function public.report_challenge(uuid, text, text) to authenticated;

-- create_challenge and accept_challenge call this
create or replace function public._challenge_player_ok(p_player uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_until timestamptz;
begin
  if (select adult_confirmed_at from public.players where id = p_player) is null then
    raise exception 'Challenges are 18+. Please confirm your age first.';
  end if;
  if exists(select 1 from public.banned_players where player_id = p_player) then
    raise exception 'Your account is banned.';
  end if;
  if exists(select 1 from public.players where id = p_player and (coalesce(trim(ff_uid), '') = '' or coalesce(trim(ff_name), '') = '')) then
    raise exception 'Save your Free Fire UID and in-game name first (tap your name > Game UID & name). Challenges need them so results can be checked.';
  end if;
  select until into v_until from public.challenge_bans where player_id = p_player and until > now();
  if v_until is not null then
    raise exception 'Challenges are locked until % (Nepal time) after a false result. Pay 5 points on the Challenges page to play now.',
      to_char(v_until at time zone 'Asia/Kathmandu', 'DD Mon HH24:MI');
  end if;
  if exists(select 1 from public.wallets where player_id = p_player and unlimited) then
    raise exception 'The admin wallet can''t be used for challenges.';
  end if;
  if exists(select 1 from public.wallets where player_id = p_player and staff) then
    raise exception 'Staff wallets can''t be used for challenges: their points are for JD Arena spending only.';
  end if;
end;
$function$;
