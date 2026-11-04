-- 2026-11-04 money audit follow-up. Safe to run again.
-- 1) Staff wallets: points the owner gives a mod to spend (Og_Bloody's 100,000 on 22 Oct) are not cash. They are
--    left out of the money summary like the owner's unlimited wallet, and a staff wallet can't be withdrawn.
-- 2) Challenges: a "we won" claim the other side never answers is no longer paid automatically after 2 hours.
--    It goes to Disputed and a mod decides from the chat and screenshots (mod panel -> Challenges).
-- 3) Free first game: a new account (made from 4 Nov 2026) gets ONE free-entry card (Rs 5 events, 14 days) the
--    first time it saves a Free Fire UID that no account has claimed the gift with. One per account, one per UID,
--    ever - so new emails with the same game account don't farm it.
begin;

-- ── 1) staff wallets ──
alter table public.wallets add column if not exists staff boolean not null default false;
update public.wallets set staff = true
 where player_id = (select id from public.players where username = 'Og_Bloody');

create or replace function public._money_window(p_since timestamptz)
returns jsonb language sql stable security definer set search_path = public as $$
  with led as (
    select l.reason, l.delta from public.wallet_ledger l
    join public.wallets w on w.player_id = l.player_id and not coalesce(w.unlimited,false) and not w.staff
    where (p_since is null or l.created_at >= p_since)
  ),
  wd as (
    select status, coalesce(payout, amount) as net, coalesce(fee,0) as fee
    from public.withdraw_requests
    where (p_since is null or created_at >= p_since)
  )
  select jsonb_build_object(
    'cash_in',         (select coalesce(sum(delta),0) from led where reason = 'load'),
    'cash_out_paid',   (select coalesce(sum(net),0)  from wd  where status = 'paid'),
    'pending_payouts', (select coalesce(sum(net),0)  from wd  where status = 'pending'),
    'fees_collected',  (select coalesce(sum(fee),0)  from wd  where status = 'paid'),
    'prize_given',     (select coalesce(sum(delta),0) from led where reason = 'prize'),
    'adjust_given',    (select coalesce(sum(delta),0) from led where reason = 'adjust'),
    'earned_points',   (select coalesce(-sum(delta),0) from led
                         where reason in ('entry','effect','optimizer','challenge_stake','refund','challenge_win','challenge_refund'))
  );
$$;
revoke all on function public._money_window(timestamptz) from public, anon, authenticated;
grant execute on function public._money_window(timestamptz) to service_role;

create or replace function public.admin_money_flow()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_day   timestamptz := (date_trunc('day',   now() at time zone 'Asia/Kathmandu')) at time zone 'Asia/Kathmandu';
  v_month timestamptz := (date_trunc('month', now() at time zone 'Asia/Kathmandu')) at time zone 'Asia/Kathmandu';
  v_all jsonb := public._money_window(null);
begin
  return jsonb_build_object(
    'owed_points',   (select coalesce(sum(balance),0) from public.wallets where not coalesce(unlimited,false) and not staff),
    'staff_points',  (select coalesce(sum(balance),0) from public.wallets where staff),
    'cash_on_esewa', ((v_all->>'cash_in')::int - (v_all->>'cash_out_paid')::int),
    'all',   v_all,
    'month', public._money_window(v_month),
    'today', public._money_window(v_day)
  );
end; $$;
revoke all on function public.admin_money_flow() from public, anon, authenticated;
grant execute on function public.admin_money_flow() to service_role;

create or replace function public.request_withdrawal(p_amount integer, p_esewa_id text, p_esewa_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_req public.withdraw_requests;
  v_bal int;
  v_fee int;
  v_payout int;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform public._assert_open();
  if exists(select 1 from public.wallets where player_id = auth.uid() and unlimited) then
    raise exception 'The admin wallet has unlimited points, so it can''t be withdrawn.';
  end if;
  if exists(select 1 from public.wallets where player_id = auth.uid() and staff) then
    raise exception 'This is a staff wallet: its points are for spending on JD Arena, not for withdrawing. Ask the owner.';
  end if;
  if (select count(*) from public.withdraw_requests where player_id = auth.uid() and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Too many withdrawal requests — please wait an hour and try again.';
  end if;
  if p_amount is null or p_amount < 1 then raise exception 'Enter how many points to withdraw.'; end if;
  if p_amount < 100 then raise exception 'The minimum withdrawal is 100 points.'; end if;
  -- 1% platform fee, at least 1 point.
  v_fee := greatest(1, ceil(p_amount::numeric / 100))::int;
  v_payout := p_amount - v_fee;
  p_esewa_id := trim(coalesce(p_esewa_id, ''));
  p_esewa_name := trim(coalesce(p_esewa_name, ''));
  if length(p_esewa_id) < 5 or length(p_esewa_id) > 40 then
    raise exception 'Enter your eSewa ID (the phone number or email on your eSewa account).';
  end if;
  if length(p_esewa_name) < 2 or length(p_esewa_name) > 60 then
    raise exception 'Enter the name on your eSewa account.';
  end if;
  insert into public.withdraw_requests (player_id, amount, esewa_id, esewa_name, fee, payout)
  values (auth.uid(), p_amount, p_esewa_id, p_esewa_name, v_fee, v_payout) returning * into v_req;
  v_bal := public._wallet_apply(auth.uid(), -p_amount, 'withdraw', v_req.id::text, null);
  return jsonb_build_object('id', v_req.id, 'amount', p_amount, 'fee', v_fee, 'payout', v_payout, 'balance', v_bal);
end; $$;
revoke all on function public.request_withdrawal(integer, text, text) from public, anon, authenticated;
grant execute on function public.request_withdrawal(integer, text, text) to authenticated;

-- staff spending points must not reach other players as withdrawable winnings: no challenges from a staff wallet
create or replace function public._challenge_player_ok(p_player uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select adult_confirmed_at from public.players where id = p_player) is null then
    raise exception 'Challenges are 18+. Please confirm your age first.';
  end if;
  if exists(select 1 from public.banned_players where player_id = p_player) then
    raise exception 'Your account is banned.';
  end if;
  if exists(select 1 from public.wallets where player_id = p_player and unlimited) then
    raise exception 'The admin wallet can''t be used for challenges.';
  end if;
  if exists(select 1 from public.wallets where player_id = p_player and staff) then
    raise exception 'Staff wallets can''t be used for challenges: their points are for JD Arena spending only.';
  end if;
end;
$$;
revoke all on function public._challenge_player_ok(uuid) from public, anon, authenticated;

-- ── 2) unanswered win claims go to a mod ──
-- the JD team (owner + staff mods) hears about every challenge that needs a decision
create or replace function public._challenge_tell_staff(p_title text, p_body text)
returns void language sql security definer set search_path = public as $$
  insert into public.notifications (player_id, title, body)
  select p.id, p_title, p_body from public.players p
  where lower(p.email) = 'ayerprabin95@gmail.com'
     or lower(p.email) in (select lower(email) from public.moderators where coalesce(role, 'staff') = 'staff');
$$;
revoke all on function public._challenge_tell_staff(text, text) from public, anon, authenticated;

create or replace function public.challenge_sweep()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n_exp int := 0; n_review int := 0; n_ref int := 0;
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
  for r in select id from public.challenges where status = 'accepted' and claim_at is null and accepted_at < now() - interval '3 hours' loop
    perform public._challenge_refund(r.id, 'refunded', 'no result reported within 3 hours'); n_ref := n_ref + 1;
  end loop;
  return jsonb_build_object('expired', n_exp, 'to_review', n_review, 'refunded', n_ref);
end;
$$;
revoke all on function public.challenge_sweep() from public, anon, authenticated;
grant execute on function public.challenge_sweep() to service_role;

create or replace function public.report_challenge(p_id uuid, p_result text)
returns text language plpgsql security definer set search_path = public as $$
declare c public.challenges; v_me_creator boolean; v_other uuid; v_mine text; v_theirs text;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_result not in ('won','lost') then raise exception 'Report won or lost.'; end if;
  select * into c from public.challenges where id = p_id for update;
  if c.id is null or auth.uid() not in (c.creator, c.opponent) then raise exception 'Challenge not found.'; end if;
  if c.status <> 'accepted' then raise exception 'This challenge isn''t waiting for a result.'; end if;
  v_me_creator := auth.uid() = c.creator;
  v_other := case when v_me_creator then c.opponent else c.creator end;
  if (v_me_creator and c.creator_claim is not null) or (not v_me_creator and c.opponent_claim is not null) then
    raise exception 'You already reported this result.';
  end if;
  if v_me_creator then
    update public.challenges set creator_claim = p_result, claim_at = coalesce(claim_at, now()) where id = p_id returning * into c;
  else
    update public.challenges set opponent_claim = p_result, claim_at = coalesce(claim_at, now()) where id = p_id returning * into c;
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
      'Both sides reported the same result on a ' || c.mode || ' challenge (' || c.stake * 2 || ' pts). Decide it in Mod panel → Challenges.');
    insert into public.notifications (player_id, title, body) values
      (c.creator, 'Challenge under review', 'The results don''t match, so a JD mod will decide. Keep your screenshots and share them in the challenge chat.'),
      (c.opponent, 'Challenge under review', 'The results don''t match, so a JD mod will decide. Keep your screenshots and share them in the challenge chat.');
    return 'disputed';
  end if;
  insert into public.notifications (player_id, title, body)
  values (v_other, '⚔️ Confirm your challenge result', public._challenge_name(auth.uid()) || ' says they won the ' || c.mode
    || ' challenge. Confirm or dispute within 2 hours — if you don''t answer, a JD mod decides from the chat and screenshots.');
  return 'waiting';
end;
$$;
revoke all on function public.report_challenge(uuid, text) from public, anon;
grant execute on function public.report_challenge(uuid, text) to authenticated;

-- ── 3) one free game for a new account, once its Free Fire UID is saved ──
create table if not exists public.welcome_vouchers (
  ff_uid text primary key,
  player_id uuid not null unique references public.players(id) on delete cascade,
  voucher_id bigint references public.entry_vouchers(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.welcome_vouchers enable row level security;   -- no policies: functions only

drop function if exists public.set_my_game_id(text, text);   -- returned void; now says whether the gift was given
create or replace function public.set_my_game_id(p_uid text, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid text := regexp_replace(coalesce(p_uid, ''), '\s', '', 'g');
  -- in-game names use fancy Unicode, so only control characters are removed
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g'));
  v_joined timestamptz;
  v_voucher bigint;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if v_uid !~ '^[0-9]{6,13}$' then raise exception 'Free Fire UID must be 6-13 numbers (Free Fire > your profile > UID).'; end if;
  if char_length(v_name) < 1 or char_length(v_name) > 30 then raise exception 'Enter your in-game name (up to 30 characters).'; end if;
  update public.players set ff_uid = v_uid, ff_name = v_name where id = auth.uid() returning created_at into v_joined;
  if v_joined >= '2026-11-04 00:00:00+05:45'
     and not exists(select 1 from public.welcome_vouchers where player_id = auth.uid() or ff_uid = v_uid) then
    insert into public.entry_vouchers (player_id, expires_at, tier, max_npr)
    values (auth.uid(), now() + interval '14 days', 'bronze', 5) returning id into v_voucher;
    insert into public.welcome_vouchers (ff_uid, player_id, voucher_id) values (v_uid, auth.uid(), v_voucher)
    on conflict do nothing;
    if not found then   -- lost a race with another account on the same UID: take the card back
      delete from public.entry_vouchers where id = v_voucher;
      return jsonb_build_object('free_game', false);
    end if;
    insert into public.notifications (player_id, title, body) values (auth.uid(), '🎁 Your first game is free',
      'Welcome to JD Arena! You have 1 free-entry card for any Rs 5 tournament. Tap Join on an event and choose "Use free entry". It lasts 14 days.');
    return jsonb_build_object('free_game', true);
  end if;
  return jsonb_build_object('free_game', false);
end $$;
revoke all on function public.set_my_game_id(text, text) from public, anon;
grant execute on function public.set_my_game_id(text, text) to authenticated;
commit;

-- ── 4) photos in the Clash Squad match chat (result screenshots) ──
-- Same private chat-media bucket and 30-day clean-up as DM photos. Only the two captains (and the mods, through
-- the mod panel's signed links) can open them.
begin;
alter table public.challenge_messages add column if not exists media text;
alter table public.challenge_messages drop constraint if exists challenge_messages_kind_check;
alter table public.challenge_messages add constraint challenge_messages_kind_check check (kind in ('text','ai','image'));

create or replace function public.send_challenge_image(p_id uuid, p_path text, p_caption text default '')
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_id bigint; v_mime text; v_cap text := left(btrim(coalesce(p_caption, '')), 200);
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  if not exists(select 1 from public.challenges where id = p_id and v_me in (creator, opponent) and status in ('accepted','disputed','completed')) then
    raise exception 'Chat opens once the challenge is accepted.';
  end if;
  select o.metadata->>'mimetype' into v_mime from storage.objects o where o.bucket_id = 'chat-media' and o.name = p_path;
  if p_path is null or split_part(p_path, '/', 1) <> v_me::text or v_mime is null
     or exists(select 1 from public.challenge_messages where media = p_path)
     or exists(select 1 from public.dm_messages where media = p_path) then
    raise exception 'Upload the photo first.';
  end if;
  if v_mime not like 'image/%' then raise exception 'Only photos can be sent here.'; end if;
  if (select count(*) from public.challenge_messages where sender = v_me and media is not null and created_at > now() - interval '10 minutes') >= 8 then
    raise exception 'That is a lot of photos. Wait a few minutes.';
  end if;
  insert into public.challenge_messages (challenge_id, sender, kind, body, media)
  values (p_id, v_me, 'image', case when v_cap = '' then '📷 Photo' else '📷 ' || v_cap end, p_path) returning id into v_id;
  return v_id;
end $$;
revoke all on function public.send_challenge_image(uuid, text, text) from public, anon;
grant execute on function public.send_challenge_image(uuid, text, text) to authenticated;

drop policy if exists "chat media read by chat members" on storage.objects;
create policy "chat media read by chat members" on storage.objects for select to authenticated
  using (bucket_id = 'chat-media' and ((storage.foldername(name))[1] = auth.uid()::text
         or exists(select 1 from public.dm_messages m where m.media = storage.objects.name and auth.uid() in (m.sender, m.recipient))
         or exists(select 1 from public.challenge_messages cm join public.challenges c on c.id = cm.challenge_id
                   where cm.media = storage.objects.name and auth.uid() in (c.creator, c.opponent))));

create or replace function public.chat_media_expired(p_limit int default 500)
returns setof text language sql stable security definer set search_path = public, storage as $$
  select o.name from storage.objects o
  where o.bucket_id = 'chat-media'
    and (o.created_at < now() - interval '30 days'
         or (o.created_at < now() - interval '1 day'
             and not exists(select 1 from public.dm_messages m where m.media = o.name)
             and not exists(select 1 from public.challenge_messages cm where cm.media = o.name)))
  order by o.created_at
  limit least(greatest(coalesce(p_limit, 500), 1), 1000)
$$;
revoke all on function public.chat_media_expired(int) from public, anon, authenticated;
grant execute on function public.chat_media_expired(int) to service_role;

create or replace function public.chat_media_forget(p_names text[])
returns int language plpgsql security definer set search_path = public as $$
declare n int; m int;
begin
  update public.dm_messages
     set body = case when media_type = 'video' then '🎬 Video deleted after 30 days' else '📷 Photo deleted after 30 days' end,
         media = null
   where media = any(p_names);
  get diagnostics n = row_count;
  update public.challenge_messages set body = '📷 Photo deleted after 30 days', media = null where media = any(p_names);
  get diagnostics m = row_count;
  return n + m;
end $$;
revoke all on function public.chat_media_forget(text[]) from public, anon, authenticated;
grant execute on function public.chat_media_forget(text[]) to service_role;
commit;

-- ── 5) ZULU hand-off rings the mods (dm-push): at most once per player every 10 minutes ──
begin;
create table if not exists public.mod_ring_log (
  player_id uuid primary key references public.players(id) on delete cascade,
  rung_at timestamptz not null default now()
);
alter table public.mod_ring_log enable row level security;   -- no policies: service role only
commit;
