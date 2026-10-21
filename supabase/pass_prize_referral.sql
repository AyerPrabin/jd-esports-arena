-- ── Free-to-join + Weekly Pass from the prize, referrals, minimum withdrawal (2026-10-22) ──
-- Owner decisions:
--  * Free tournaments stay free to join (the 27 Oct "pass required to join" rule is removed). When a squad WINS a
--    prize in a free tournament starting on/after Tue 27 Oct 2026 and the winner had no Weekly Pass on match day,
--    50 points (or the whole prize if smaller) come out of the prize and they get a Weekly Pass (7 days) for it.
--  * Referrals: a new player enters a friend's JD tag (or opens jdesport.co.uk/?ref=TAG) within 14 days of signing
--    up. On the invited player's FIRST prize both get +40 points (once per invited player).
--  * Minimum withdrawal: 100 points.
-- The new register_for_tournament (no pass check) and the announcement text are appended from reg_ann.sql.
begin;

alter table public.wallet_ledger drop constraint if exists wallet_ledger_reason_check;
alter table public.wallet_ledger add constraint wallet_ledger_reason_check check (reason in
  ('load','entry','effect','withdraw','withdraw_returned','refund','adjust','prize','challenge_stake','challenge_win',
   'challenge_refund','optimizer','pass','referral'));

-- ── referrals ──
create table if not exists public.referrals (
  referred_id uuid primary key references public.players(id) on delete cascade,
  referrer_id uuid not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  bonus_paid_at timestamptz,
  check (referred_id <> referrer_id)
);
create index if not exists referrals_referrer on public.referrals(referrer_id);
alter table public.referrals enable row level security;
drop policy if exists "players read own referrals" on public.referrals;
create policy "players read own referrals" on public.referrals for select using (auth.uid() in (referred_id, referrer_id));

create or replace function public.set_referrer(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text := upper(regexp_replace(trim(coalesce(p_code, '')), '^@', ''));
  v_ref uuid;
  v_name text;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.referrals where referred_id = auth.uid()) then
    raise exception 'You already joined with a friend''s invite code.';
  end if;
  if (select created_at from public.players where id = auth.uid()) < now() - interval '14 days' then
    raise exception 'Invite codes work in your first 14 days on JD Arena.';
  end if;
  if exists(select 1 from public.wallet_ledger where player_id = auth.uid() and reason = 'prize') then
    raise exception 'Invite codes are for new players who haven''t won a prize yet.';
  end if;
  if v_code = '' then raise exception 'Enter your friend''s JD tag or username.'; end if;
  select id, coalesce(username, player_tag) into v_ref, v_name from public.players
    where upper(player_tag) = v_code or upper(player_tag) = 'JD-' || v_code or upper(username) = v_code limit 1;
  if v_ref is null then raise exception 'No player with that JD tag or username.'; end if;
  if v_ref = auth.uid() then raise exception 'You can''t use your own code.'; end if;
  if exists(select 1 from public.referrals where referred_id = v_ref and referrer_id = auth.uid()) then
    raise exception 'You invited this player - you can''t use their code too.';
  end if;
  if exists(select 1 from public.banned_players where player_id = v_ref) then raise exception 'That code can''t be used.'; end if;
  insert into public.referrals (referred_id, referrer_id) values (auth.uid(), v_ref);
  insert into public.notifications (player_id, title, body) values (v_ref, '🤝 A friend joined with your code',
    coalesce((select coalesce(username, player_tag) from public.players where id = auth.uid()), 'A new player') ||
    ' signed up with your invite. When their squad wins its first prize, you both get +40 points.');
  return jsonb_build_object('inviter', v_name);
end;
$$;
revoke all on function public.set_referrer(text) from public, anon;
grant execute on function public.set_referrer(text) to authenticated;

create or replace function public.my_referrals()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'code', (select player_tag from public.players where id = auth.uid()),
    'invited', (select count(*) from public.referrals where referrer_id = auth.uid()),
    'won', (select count(*) from public.referrals where referrer_id = auth.uid() and bonus_paid_at is not null),
    'earned', 40 * (select count(*) from public.referrals where referrer_id = auth.uid() and bonus_paid_at is not null),
    'inviter', (select coalesce(p.username, p.player_tag) from public.referrals r join public.players p on p.id = r.referrer_id
                where r.referred_id = auth.uid()),
    'inviter_bonus_paid', (select bonus_paid_at is not null from public.referrals where referred_id = auth.uid()),
    'can_enter', (select created_at > now() - interval '14 days' from public.players where id = auth.uid())
                 and not exists(select 1 from public.referrals where referred_id = auth.uid())
                 and not exists(select 1 from public.wallet_ledger where player_id = auth.uid() and reason = 'prize'));
$$;
revoke all on function public.my_referrals() from public, anon;
grant execute on function public.my_referrals() to authenticated;

-- ── prize payout: + Weekly Pass from the prize, + referral bonus on the first prize ──
create or replace function public._award_one(p_slug text, p_squad text, p_amount integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_player uuid;
  v_ref text := 'prize:' || p_slug || ':' || lower(trim(p_squad));
  v_bal int;
  v_start timestamptz;
  v_cut int := 0;
  v_ps timestamptz;
  v_pe timestamptz;
  v_referrer uuid;
  v_note text := '';
begin
  if p_amount is null or p_amount < 1 then
    return jsonb_build_object('squad', p_squad, 'status', 'no_amount');
  end if;
  if exists(select 1 from public.wallet_ledger where reason = 'prize' and ref = v_ref) then
    return jsonb_build_object('squad', p_squad, 'status', 'already_paid');
  end if;
  select player_id into v_player from public.registrations
    where tournament_slug = p_slug and lower(trim(squad_name)) = lower(trim(p_squad))
      and status in ('confirmed','approved')
    order by created_at asc limit 1;
  if v_player is null then
    return jsonb_build_object('squad', p_squad, 'status', 'unmatched', 'amount', p_amount);
  end if;
  v_bal := public._wallet_apply(v_player, p_amount, 'prize', v_ref, p_slug);

  -- Weekly Pass from the prize: free tournament from Tue 27 Oct, no pass on match day
  v_start := public.tournament_start_at(p_slug);
  if coalesce(public.tournament_entry_npr(p_slug), 0) = 0
     and coalesce(v_start, now()) >= timestamptz '2026-10-27 00:00:00+05:45'
     and public.weekly_pass_tier(v_player, coalesce(v_start, now())) is null then
    v_cut := least(50, p_amount);
    perform pg_advisory_xact_lock(hashtext('pass:' || v_player::text));
    v_bal := public._wallet_apply(v_player, -v_cut, 'pass', 'passprize:' || p_slug || ':' || lower(trim(p_squad)), 'Weekly Pass from prize');
    select greatest(now(), coalesce(max(expires_at), now())) into v_ps from public.weekly_passes
      where player_id = v_player and expires_at > now();
    v_ps := coalesce(v_ps, now());
    v_pe := v_ps + interval '7 days';
    insert into public.weekly_passes (player_id, tier, starts_at, expires_at, price, ref)
      values (v_player, 'basic', v_ps, v_pe, v_cut, 'passprize:' || p_slug);
    v_note := ' ' || v_cut || ' points of it paid for a Weekly Pass (your squad had none), valid until ' ||
              to_char(v_pe at time zone 'Asia/Kathmandu', 'Dy DD Mon') || ' - next time you keep the full prize.';
  end if;

  -- referral: the invited player's first prize -> +40 for them and +40 for the friend who invited them
  update public.referrals set bonus_paid_at = now() where referred_id = v_player and bonus_paid_at is null
    returning referrer_id into v_referrer;
  if v_referrer is not null then
    v_bal := public._wallet_apply(v_player, 40, 'referral', 'ref:' || v_player::text, 'Invite bonus - first win');
    perform public._wallet_apply(v_referrer, 40, 'referral', 'ref:' || v_player::text || ':by', 'Your invited friend won');
    insert into public.notifications (player_id, title, body) values (v_referrer, '🤝 +40 points: your friend won',
      coalesce((select coalesce(username, player_tag) from public.players where id = v_player), 'Your invited friend') ||
      ' won their first prize, so you both got +40 points. Invite more friends from your profile.');
    v_note := v_note || ' +40 invite bonus for your first win.';
  end if;

  insert into public.notifications (player_id, tournament_slug, title, body)
  values (v_player, p_slug, '🏆 Prize: +' || p_amount || ' JD points',
          'Congratulations! ' || p_squad || '''s prize for ' || p_slug || ' (' || p_amount || ' points) is in your wallet.' ||
          v_note || ' Balance: ' || v_bal || ' points. You can use it for entries or withdraw it to eSewa.');
  return jsonb_build_object('squad', p_squad, 'status', 'paid', 'amount', p_amount, 'player_id', v_player,
                            'pass_cut', v_cut, 'referral', v_referrer is not null);
end;
$function$;

-- ── withdrawals: at least 100 points ──
create or replace function public.request_withdrawal(p_amount integer, p_esewa_id text, p_esewa_name text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
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
end; $function$;

-- ── registration without the pass check (early-access window kept) + new announcement text ──
create or replace function public.register_for_tournament(p_tournament_slug text, p_squad_name text, p_squad_logo text, p_status text, p_payment_screenshot text, p_device_type text)
 returns registrations language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_slots int;
  v_count int;
  v_already_registered boolean;
  v_effective_status text := p_status;
  v_platform_mode text;
  v_row public.registrations;
  v_name text;
  v_start timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;

  if p_squad_logo is not null and (length(p_squad_logo) > 200000 or p_squad_logo !~ '^data:image/(png|jpe?g|webp|gif);base64,[A-Za-z0-9+/=]+$') then
    raise exception 'Squad logo must be a PNG, JPG, WEBP or GIF image under 200 KB.';
  end if;
  if p_squad_name is not null and length(trim(p_squad_name)) > 40 then
    raise exception 'Squad name must be 40 characters or fewer.';
  end if;
  v_name := coalesce(nullif(trim(p_squad_name), ''), (select squad_name from public.players where id = auth.uid()));
  if v_name is null or length(trim(v_name)) < 2 then
    raise exception 'Enter your squad name (at least 2 characters).';
  end if;
  update public.players set squad_name = trim(v_name),
    squad_logo = coalesce(p_squad_logo, squad_logo)
    where id = auth.uid();
  if p_status not in ('pending','confirmed') then
    raise exception 'Invalid registration status';
  end if;

  if coalesce(public.tournament_entry_npr(p_tournament_slug), 0) > 0 then
    p_status := 'pending';
    v_effective_status := 'pending';
  end if;

  if exists(select 1 from public.banned_players where player_id = auth.uid()) then
    raise exception 'Your account is banned from registering for tournaments.';
  end if;

  v_start := public.tournament_start_at(p_tournament_slug);   -- for the early-access window below

  declare v_open timestamptz;
  begin
    if lower(coalesce(public.tournament_field(p_tournament_slug, 'early_access'), '')) in ('yes','true')
       and not exists(select 1 from public.registrations where tournament_slug = p_tournament_slug and player_id = auth.uid()) then
      begin v_open := nullif(public.tournament_field(p_tournament_slug, 'reg_opens'), '')::timestamptz;
      exception when others then v_open := null; end;
      if v_open is not null and now() < v_open then
        if now() < v_open - interval '24 hours' then
          raise exception 'Registration opens at % (app users 24 hours earlier).', to_char(v_open at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM') || ' NPT';
        end if;
        if (select app_installed_at from public.players where id = auth.uid()) is null and not public._optimizer_is_max(auth.uid())
           and public.weekly_pass_tier(auth.uid(), greatest(now(), coalesce(v_start, now()))) is distinct from 'pro' then
          raise exception 'Early access: only JD Arena app users, Weekly Pro and Optimizer Max members can join before %. Open the app to join now.', to_char(v_open at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM') || ' NPT';
        end if;
      end if;
    end if;
  end;
  if p_device_type not in ('mobile','emulator') then
    raise exception 'Pick a device type: mobile or emulator.';
  end if;

  select platform_mode into v_platform_mode from public.tournament_capacity where tournament_slug = p_tournament_slug;
  v_platform_mode := coalesce(v_platform_mode, 'mixed');
  if v_platform_mode <> 'mixed' and v_platform_mode <> p_device_type then
    raise exception 'This tournament is % only -- you declared %.', v_platform_mode, p_device_type;
  end if;

  perform pg_advisory_xact_lock(hashtext(p_tournament_slug));

  select exists(
    select 1 from public.registrations
    where tournament_slug = p_tournament_slug and player_id = auth.uid()
  ) into v_already_registered;

  if not v_already_registered then
    if exists(select 1 from public.registrations r
              where r.tournament_slug = p_tournament_slug
                and r.player_id <> auth.uid()
                and r.status in ('confirmed','approved','waitlisted','pending')
                and lower(trim(r.squad_name)) = lower(trim(v_name))) then
      raise exception 'That squad name is already taken for this event — please pick a different name.';
    end if;
    select slots into v_slots from public.tournament_capacity where tournament_slug = p_tournament_slug;
    if v_slots is not null then
      select count(*) into v_count from public.registrations
        where tournament_slug = p_tournament_slug and status in ('confirmed', 'approved');
      if v_count >= v_slots then
        if p_status = 'confirmed' then
          v_effective_status := 'waitlisted';
        else
          raise exception 'Tournament full';
        end if;
      end if;
    end if;
  end if;

  insert into public.registrations (tournament_slug, player_id, squad_name, squad_logo, status, payment_screenshot, device_type)
  values (p_tournament_slug, auth.uid(), trim(v_name), null, v_effective_status, p_payment_screenshot, p_device_type)
  returning * into v_row;

  insert into public.notifications (player_id, tournament_slug, title, body)
  values (
    auth.uid(),
    p_tournament_slug,
    '🎫 Registered: ' || p_tournament_slug,
    'TICKET::' || ('JD-' || upper(substr(replace(v_row.id::text, '-', ''), 1, 8))) || '::' || v_effective_status
  );

  return v_row;
end;
$function$;

create or replace function public.jd_pass_announce()
returns int language plpgsql security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'Asia/Kathmandu')::date;
  v_launch date := date '2026-10-27';
  v_left int := v_launch - v_today;
  v_title text;
  v_body text;
  v_n int;
begin
  if v_today > v_launch then
    perform cron.unschedule(jobid) from cron.job where jobname = 'jd-pass-announce';
    return 0;
  end if;
  begin
    insert into public.jd_pass_announce_log(day) values (v_today);
  exception when unique_violation then return 0; end;
  v_title := case when v_left = 0 then '🎟 Weekly Pass: new rule starts TODAY'
                  when v_left = 1 then '🎟 Weekly Pass rule starts tomorrow'
                  else '🎟 Free tournaments + Weekly Pass from Tue 27 Oct (' || v_left || ' days)' end;
  v_body := 'From Tue 27 Oct free JD tournaments stay free to join. If your squad WINS a prize without a Weekly Pass, '
         || '50 points (Rs 50) come out of the prize and you get the Weekly Pass for 7 days. With a pass you keep the full prize. '
         || 'Weekly Pro Rs 80: Pro effects, 24 h early registration, first on waitlists, PRO badge. Invite friends: Rs 40 each '
         || 'when they win their first prize. jdesport.co.uk/pass';
  insert into public.notifications (player_id, title, body, push)
    select id, v_title, v_body, true from public.players;
  get diagnostics v_n = row_count;
  update public.jd_pass_announce_log set recipients = v_n where day = v_today;
  return v_n;
end;
$$;

commit;
