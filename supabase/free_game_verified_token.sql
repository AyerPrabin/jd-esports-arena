-- 2026-11-04 fix for free_game_device_dispute_timeout.sql (security review): save_fcm_token accepts any well-formed
-- string, so a made-up "token" could stand in for a phone. The free game now only counts a token Firebase has
-- actually delivered a push to (last_ok_at, set by _shared/push.ts sendFcm; tokens FCM rejects are deleted).
-- A new token is tested with one "notifications are on" push; when it is delivered the gift is checked again.
-- Safe to run again.
begin;

create or replace function public._maybe_welcome(p_player uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_uid text; v_joined timestamptz; v_token text; v_voucher bigint;
begin
  select ff_uid, created_at into v_uid, v_joined from public.players where id = p_player;
  if v_uid is null or v_joined < '2026-11-04 00:00:00+05:45' then return false; end if;
  if exists(select 1 from public.welcome_vouchers where player_id = p_player or ff_uid = v_uid) then return false; end if;
  select t.token into v_token from public.push_fcm_tokens t
   where t.player_id = p_player and t.last_ok_at is not null
     and not exists(select 1 from public.welcome_vouchers w where w.fcm_token = t.token)
   order by t.created_at desc limit 1;
  if v_token is null then
    -- an app token Firebase hasn't confirmed yet: send one test push (at most once a day); delivery re-runs this
    if exists(select 1 from public.push_fcm_tokens t where t.player_id = p_player and t.last_ok_at is null
               and not exists(select 1 from public.welcome_vouchers w where w.fcm_token = t.token))
       and not exists(select 1 from public.notifications where player_id = p_player
               and title = '🔔 Notifications are on' and created_at > now() - interval '1 day') then
      insert into public.notifications (player_id, title, body) values (p_player, '🔔 Notifications are on',
        'JD Arena will tell you about your matches, results and challenges here.');
    end if;
    return false;
  end if;
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

drop trigger if exists welcome_on_token on public.push_fcm_tokens;
create trigger welcome_on_token after insert or update of player_id on public.push_fcm_tokens
  for each row execute function public._welcome_on_token();
-- the first confirmed delivery to a token (later deliveries skip the check)
drop trigger if exists welcome_on_token_ok on public.push_fcm_tokens;
create trigger welcome_on_token_ok after update of last_ok_at on public.push_fcm_tokens
  for each row when (old.last_ok_at is null and new.last_ok_at is not null)
  execute function public._welcome_on_token();
commit;
