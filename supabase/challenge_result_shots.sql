-- challenge_result_shots.sql (10 Nov 2026): a challenge result needs a screenshot.
-- Owner: "player send screenshot after challenge ... with victory photo, same with losing teams", and the
-- players' UIDs must be findable from the screenshots. Timer starts at the first report; no answer in
-- 10 min = the side that sent a photo wins.
--   * report_challenge now takes p_shot (a photo the player uploaded to chat-media) and refuses a report without
--     one. The photo is posted in the match chat as "Result: Victory/Defeat · FF <name> · UID <uid>" from the
--     reporter's saved Free Fire name + UID, so a mod can match the names in the screenshot. A saved FF UID is
--     needed to report.
--   * After one side reports a WIN with its photo, the other side has 10 minutes to send theirs (Lost = pays out
--     at once as before; Won too = dispute, a mod decides as before). No answer = the win stands (challenge_sweep,
--     now every minute). Guards: the photo must be uploaded after the challenge was accepted, and a win claimed
--     less than 10 min after accepting (too quick for a real match) goes to a mod instead (old 2-hour rule).
--     Claims made before this file (no photo) keep the old 2-hour rule.
-- Run: npx supabase db query --remote --yes -f supabase/challenge_result_shots.sql
-- Undo: drop trigger challenge_false_claim on public.challenges; drop function public.challenge_unlock_pay();
--       drop function public.report_challenge(uuid, text, text); run report_challenge from
--       supabase/money_review_free_game.sql and the old challenge_sweep again, then
--       select cron.alter_job(jobid, schedule := '*/5 * * * *') from cron.job where jobname = 'challenge-sweep';

alter table public.challenges add column if not exists creator_shot text, add column if not exists opponent_shot text;

drop function if exists public.report_challenge(uuid, text);
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
  if p_shot is null or btrim(p_shot) = '' then
    raise exception 'Send your result screenshot (the Victory or Defeat screen). Refresh the page if you don''t see the photo step.';
  end if;
  select coalesce(trim(ff_uid), ''), coalesce(trim(ff_name), '') into v_uid, v_name from public.players where id = auth.uid();
  if coalesce(v_uid, '') = '' then
    raise exception 'Save your Free Fire UID first (tap your name > Game UID & name), so the mod can match you in the screenshot.';
  end if;
  select * into c from public.challenges where id = p_id;
  -- the photo must be taken for THIS match: uploaded after the challenge was accepted (no old Victory screens)
  select o.metadata->>'mimetype' into v_mime from storage.objects o where o.bucket_id = 'chat-media' and o.name = p_shot
    and c.accepted_at is not null and o.created_at >= c.accepted_at;
  if split_part(p_shot, '/', 1) <> auth.uid()::text or v_mime is null
     or exists(select 1 from public.challenge_messages where media = p_shot)
     or exists(select 1 from public.dm_messages where media = p_shot) then
    raise exception 'Upload a screenshot of this match (taken after the challenge was accepted).';
  end if;
  if v_mime not like 'image/%' then raise exception 'The result must be a photo or screenshot.'; end if;
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
  insert into public.challenge_messages (challenge_id, sender, kind, body, media)
  values (p_id, auth.uid(), 'image',
    '📷 Result: ' || case when p_result = 'won' then 'Victory' else 'Defeat' end ||
    ' · FF ' || case when v_name <> '' then v_name || ' · ' else '' end || 'UID ' || v_uid, p_shot);
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
    || ' challenge and sent their Victory screenshot. Open the challenge and send your result screenshot within 10 minutes, or their win stands.');
  return 'waiting';
end;
$function$;
revoke all on function public.report_challenge(uuid, text, text) from public, anon;
grant execute on function public.report_challenge(uuid, text, text) to authenticated;

create or replace function public.challenge_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n_exp int := 0; n_review int := 0; n_ref int := 0; n_stuck int := 0; n_auto int := 0;
begin
  if exists(select 1 from public.system_state where id = 1 and locked) then
    return jsonb_build_object('skipped', 'locked');
  end if;
  for r in select id from public.challenges where status = 'open' and created_at < now() - interval '2 hours' loop
    perform public._challenge_refund(r.id, 'expired', 'nobody accepted within 2 hours'); n_exp := n_exp + 1;
  end loop;
  -- one side reported a WIN with its screenshot and the other side sent nothing in 10 minutes: the win stands
  for r in select id, case when creator_claim = 'won' then creator else opponent end as winner from public.challenges
           where status = 'accepted' and claim_at < now() - interval '10 minutes'
             and claim_at >= accepted_at + interval '10 minutes'   -- too quick for a real match: a mod decides (2-hour rule below)
             and ((creator_claim = 'won' and creator_shot is not null and opponent_claim is null)
               or (opponent_claim = 'won' and opponent_shot is not null and creator_claim is null))
           for update loop
    perform public._challenge_payout(r.id, r.winner, 'no answer within 10 minutes - the reported win with its screenshot stands');
    n_auto := n_auto + 1;
  end loop;
  for r in select id, creator, opponent, mode, stake from public.challenges
           where status = 'accepted' and claim_at < now() - interval '2 hours'
             and ((creator_claim = 'won' and opponent_claim is null) or (opponent_claim = 'won' and creator_claim is null))
           for update loop
    update public.challenges set status = 'disputed', resolution = 'no answer within 2 hours - a mod decides'
     where id = r.id;
    perform public._challenge_tell_staff('⚖️ Challenge needs a decision',
      'A ' || r.mode || ' challenge (' || r.stake * 2 || ' pts): one side says they won, the other never answered. '
      || 'Check the chat and screenshots in Mod panel → Challenges.');
    insert into public.notifications (player_id, title, body) values
      (r.creator, 'Challenge under review', 'No answer to the result within 2 hours, so a JD mod will decide. Share your result screenshot in the challenge chat.'),
      (r.opponent, 'Challenge under review', 'No answer to the result within 2 hours, so a JD mod will decide. Share your result screenshot in the challenge chat.');
    n_review := n_review + 1;
  end loop;
  for r in select id, mode, stake from public.challenges
           where status = 'disputed' and review_nudged_at is null and coalesce(claim_at, accepted_at) < now() - interval '12 hours' loop
    update public.challenges set review_nudged_at = now() where id = r.id;
    perform public._challenge_tell_staff('⏰ Challenge still waiting for a mod',
      'A ' || r.mode || ' challenge (' || r.stake * 2 || ' pts) has waited 12 hours. Decide it in Mod panel → Challenges, or both sides are refunded at 24 hours.');
  end loop;
  for r in select id from public.challenges
           where status = 'disputed' and coalesce(claim_at, accepted_at) < now() - interval '24 hours' loop
    perform public._challenge_refund(r.id, 'refunded', 'no mod decision within 24 hours - both stakes refunded'); n_stuck := n_stuck + 1;
  end loop;
  for r in select id from public.challenges where status = 'accepted' and claim_at is null and accepted_at < now() - interval '3 hours' loop
    perform public._challenge_refund(r.id, 'refunded', 'no result reported within 3 hours'); n_ref := n_ref + 1;
  end loop;
  return jsonb_build_object('auto_won', n_auto, 'expired', n_exp, 'to_review', n_review, 'refunded', n_ref, 'undecided_refunded', n_stuck);
end;
$function$;

select cron.alter_job(jobid, schedule := '* * * * *') from cron.job where jobname = 'challenge-sweep';

-- ── False "we won" claims (owner, 10 Nov 2026): a player who reported WON but the challenge went to the other
-- side (a mod decided it from the screenshots) gets a warning and 2 days without challenges. They can pay
-- 5 points to play again at once. Every strike is counted so mods can see repeat offenders.
create table if not exists public.challenge_bans (
  player_id uuid primary key references public.players(id) on delete cascade,
  until timestamptz not null,
  strikes integer not null default 0,
  last_challenge uuid,
  updated_at timestamptz not null default now()
);
alter table public.challenge_bans enable row level security;
drop policy if exists challenge_bans_own on public.challenge_bans;
create policy challenge_bans_own on public.challenge_bans for select to authenticated using (player_id = auth.uid());

create or replace function public._challenge_false_claim()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_loser uuid; v_claim text; v_n int;
begin
  if new.status <> 'completed' or old.status = 'completed' or new.winner is null then return new; end if;
  v_loser := case when new.winner = new.creator then new.opponent else new.creator end;
  v_claim := case when v_loser = new.creator then new.creator_claim else new.opponent_claim end;
  if v_claim is distinct from 'won' then return new; end if;
  insert into public.challenge_bans (player_id, until, strikes, last_challenge)
  values (v_loser, now() + interval '2 days', 1, new.id)
  on conflict (player_id) do update set until = greatest(challenge_bans.until, now() + interval '2 days'),
    strikes = challenge_bans.strikes + 1, last_challenge = new.id, updated_at = now()
  returning strikes into v_n;
  insert into public.notifications (player_id, title, body) values (v_loser, '⚠️ Warning: false challenge result',
    'You reported a win on a ' || new.mode || ' challenge, but the screenshots showed your side lost. Challenges are locked for 2 days'
    || ' (warning ' || v_n || '). To play now, pay 5 points on the Challenges page. Repeated false results can get the account banned.');
  if v_n >= 3 then
    perform public._challenge_tell_staff('🚩 Repeat false challenge results',
      public._challenge_name(v_loser) || ' has ' || v_n || ' false "we won" results. Consider a ban.');
  end if;
  return new;
end;
$$;
drop trigger if exists challenge_false_claim on public.challenges;
create trigger challenge_false_claim after update of status on public.challenges
  for each row execute function public._challenge_false_claim();

-- create_challenge and accept_challenge both call this: the 2-day lock is checked here (rest unchanged)
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

-- pay 5 points to lift the lock now (the strike stays on record)
create or replace function public.challenge_unlock_pay()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare v_bal int;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform 1 from public.challenge_bans where player_id = auth.uid() and until > now() for update;
  if not found then raise exception 'Your challenges are not locked.'; end if;
  v_bal := public._wallet_apply(auth.uid(), -5, 'adjust', 'challenge_unlock', 'Challenge lock lifted early (5 points)');
  update public.challenge_bans set until = now(), updated_at = now() where player_id = auth.uid();
  return v_bal;
end;
$$;
revoke all on function public.challenge_unlock_pay() from public, anon;
grant execute on function public.challenge_unlock_pay() to authenticated;
revoke all on function public._challenge_false_claim() from public, anon, authenticated;
