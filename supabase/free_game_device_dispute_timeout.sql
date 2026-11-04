-- 2026-11-04 follow-up to money_review_free_game.sql. Safe to run again.
-- 1) Free first game, harder to farm: besides a new account and an unused Free Fire UID, the account must have the
--    JD Arena Android app on a phone (a Firebase token in push_fcm_tokens) that has never collected the gift.
--    A new Gmail with a made-up UID on the same phone gets nothing. The gift is checked when the UID is saved and
--    again when the app saves its token, whichever comes last.
-- 2) A disputed challenge no mod decides within 24 hours of the claim is refunded to both sides, so nobody's
--    points are stuck forever. Mods are reminded at 12 hours.
begin;

alter table public.welcome_vouchers add column if not exists fcm_token text;
create unique index if not exists welcome_vouchers_token on public.welcome_vouchers (fcm_token) where fcm_token is not null;

create or replace function public._maybe_welcome(p_player uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_uid text; v_joined timestamptz; v_token text; v_voucher bigint;
begin
  select ff_uid, created_at into v_uid, v_joined from public.players where id = p_player;
  if v_uid is null or v_joined < '2026-11-04 00:00:00+05:45' then return false; end if;
  if exists(select 1 from public.welcome_vouchers where player_id = p_player or ff_uid = v_uid) then return false; end if;
  select t.token into v_token from public.push_fcm_tokens t
   where t.player_id = p_player and not exists(select 1 from public.welcome_vouchers w where w.fcm_token = t.token)
   order by t.created_at desc limit 1;
  if v_token is null then return false; end if;   -- no app on a fresh phone yet: checked again when the token arrives
  insert into public.welcome_vouchers (ff_uid, player_id, fcm_token) values (v_uid, p_player, v_token) on conflict do nothing;
  if not found then return false; end if;   -- another account won the race for this UID / phone
  insert into public.entry_vouchers (player_id, expires_at, tier, max_npr)
  values (p_player, now() + interval '14 days', 'bronze', 5) returning id into v_voucher;
  update public.welcome_vouchers set voucher_id = v_voucher where player_id = p_player;
  insert into public.notifications (player_id, title, body) values (p_player, '🎁 Your first game is free',
    'Welcome to JD Arena! You have 1 free-entry card for any Rs 5 tournament. Tap Join on an event and choose "Use free entry". It lasts 14 days.');
  return true;
end $$;
revoke all on function public._maybe_welcome(uuid) from public, anon, authenticated;

-- same signature and return type as before, so a plain replace
create or replace function public.set_my_game_id(p_uid text, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid text := regexp_replace(coalesce(p_uid, ''), '\s', '', 'g');
  -- in-game names use fancy Unicode, so only control characters are removed
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g'));
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if v_uid !~ '^[0-9]{6,13}$' then raise exception 'Free Fire UID must be 6-13 numbers (Free Fire > your profile > UID).'; end if;
  if char_length(v_name) < 1 or char_length(v_name) > 30 then raise exception 'Enter your in-game name (up to 30 characters).'; end if;
  update public.players set ff_uid = v_uid, ff_name = v_name where id = auth.uid();
  return jsonb_build_object('free_game', public._maybe_welcome(auth.uid()));
end $$;
revoke all on function public.set_my_game_id(text, text) from public, anon;
grant execute on function public.set_my_game_id(text, text) to authenticated;

create or replace function public._welcome_on_token() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.player_id is not null then
    begin
      perform public._maybe_welcome(new.player_id);
    exception when others then
      raise warning 'welcome gift: %', sqlerrm;   -- never block saving the push token
    end;
  end if;
  return null;
end $$;
revoke all on function public._welcome_on_token() from public, anon, authenticated;
drop trigger if exists welcome_on_token on public.push_fcm_tokens;
create trigger welcome_on_token after insert or update of player_id on public.push_fcm_tokens
  for each row execute function public._welcome_on_token();

-- ── disputes: reminder at 12 h, refund at 24 h ──
alter table public.challenges add column if not exists review_nudged_at timestamptz;

create or replace function public.challenge_sweep()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n_exp int := 0; n_review int := 0; n_ref int := 0; n_stuck int := 0;
begin
  if exists(select 1 from public.system_state where id = 1 and locked) then
    return jsonb_build_object('skipped', 'locked');
  end if;
  for r in select id from public.challenges where status = 'open' and created_at < now() - interval '2 hours' loop
    perform public._challenge_refund(r.id, 'expired', 'nobody accepted within 2 hours'); n_exp := n_exp + 1;
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
  return jsonb_build_object('expired', n_exp, 'to_review', n_review, 'refunded', n_ref, 'undecided_refunded', n_stuck);
end;
$$;
revoke all on function public.challenge_sweep() from public, anon, authenticated;
grant execute on function public.challenge_sweep() to service_role;
commit;
