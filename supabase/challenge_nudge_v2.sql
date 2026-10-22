-- Daily challenge reminder, ZULU voice (2026-10-22): same audience and once-a-day log as
-- challenge_daily_reminder() in schema.sql; only the wording changes. Never says "bet":
-- always "challenge ... win up to N points". The small-stake example (20 each) is worked
-- out with challenge_fee_per_player(), so it stays right if the fee changes.
begin;
create or replace function public.challenge_daily_reminder()
returns int language plpgsql security definer set search_path = public as $$
declare v_day date := (now() at time zone 'Asia/Kathmandu')::date; v_open int; v_top int; v_pot int; v_small int; v_body text; v_n int;
begin
  insert into public.challenge_daily_log (day) values (v_day) on conflict do nothing;
  if not found then return 0; end if; -- already sent today
  select count(*), coalesce(max(stake), 0) into v_open, v_top from public.challenges where status = 'open' and invited is null;
  v_pot := v_top * 2 - 2 * public.challenge_fee_per_player();
  v_small := 20 * 2 - 2 * public.challenge_fee_per_player();
  v_body := case
    when v_open = 1 then 'ZULU here 👋 1 Clash Squad challenge is waiting in the lobby - the winner gets ' || v_pot || ' points. Open JD Arena and accept it!'
    when v_open > 1 then 'ZULU here 👋 ' || v_open || ' Clash Squad challenges are waiting - biggest win ' || v_pot || ' points. Open JD Arena and pick one!'
    else 'ZULU here 👋 Challenge someone with 20 points and win up to ' || v_small || ' points! Post a 1v1 Clash Squad in JD Arena - you pick skills, guns and ammo.'
  end;
  insert into public.notifications (player_id, title, body)
  select p.id, '⚔️ Daily challenge time', v_body from public.players p
  where p.daily_challenge_alert
    and p.adult_confirmed_at is not null -- challenges are 18+: never nudge anyone who hasn't confirmed
    and not exists(select 1 from public.banned_players b where b.player_id = p.id)
    and not exists(select 1 from public.challenges c where p.id in (c.creator, c.opponent)
                   and c.created_at >= (v_day::timestamp at time zone 'Asia/Kathmandu'));
  get diagnostics v_n = row_count;
  update public.challenge_daily_log set sent = v_n where day = v_day;
  return v_n;
end;
$$;
revoke all on function public.challenge_daily_reminder() from public, anon, authenticated;
commit;
