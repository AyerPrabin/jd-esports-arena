-- ── Weekly Pass (2026-10-21; enforced for free tournaments starting on/after Tue 27 Oct 2026) ──
-- Weekly Pass  (basic) - 50 points / 7 days: join every free tournament + a lite squad effect for the week.
-- Weekly Pro   (pro)   - 80 points / 7 days: everything in the pass + a Pro squad effect, 24 h early registration
--                        (same early-access window as app users / Optimizer Max), first in line when a waitlist
--                        moves, and a PRO badge on the public roster.
-- Paid-entry tournaments are unchanged. Upgrading Pass -> Pro turns the pass days left into Pro days (x50/80).
-- Daily announcement to every player until 27 Oct (jd_pass_announce, pg_cron), then it switches itself off.
begin;

create table if not exists public.weekly_passes (
  id bigserial primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  tier text not null check (tier in ('basic','pro')),
  starts_at timestamptz not null,
  expires_at timestamptz not null,
  price int not null,
  ref text,
  created_at timestamptz not null default now()
);
alter table public.weekly_passes add column if not exists ref text;
create index if not exists weekly_passes_player on public.weekly_passes(player_id, expires_at desc);
alter table public.weekly_passes enable row level security;
drop policy if exists "players read own weekly passes" on public.weekly_passes;
create policy "players read own weekly passes" on public.weekly_passes for select using (auth.uid() = player_id);

-- wallet ledger: new reason 'pass' (everything else unchanged)
alter table public.wallet_ledger drop constraint if exists wallet_ledger_reason_check;
alter table public.wallet_ledger add constraint wallet_ledger_reason_check check (reason in
  ('load','entry','effect','withdraw','withdraw_returned','refund','adjust','prize','challenge_stake','challenge_win',
   'challenge_refund','optimizer','pass'));

create or replace function public.weekly_pass_tier(p_player uuid, p_at timestamptz default now())
returns text language sql stable security definer set search_path = public as $$
  select case when bool_or(tier = 'pro') then 'pro' when count(*) > 0 then 'basic' end
  from public.weekly_passes where player_id = p_player and starts_at <= p_at and expires_at > p_at;
$$;
revoke all on function public.weekly_pass_tier(uuid, timestamptz) from public, anon, authenticated;

create or replace function public.my_weekly_pass()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tier', public.weekly_pass_tier(auth.uid(), greatest(now(), timestamptz '2026-10-27 00:00:00+05:45')),
    'active_now', public.weekly_pass_tier(auth.uid()) is not null,
    'starts_at', (select min(starts_at) from public.weekly_passes where player_id = auth.uid() and expires_at > now() and expires_at > starts_at),
    'expires_at', (select max(expires_at) from public.weekly_passes where player_id = auth.uid() and expires_at > now()),
    'required_from', '2026-10-27T00:00:00+05:45');
$$;
revoke all on function public.my_weekly_pass() from public, anon;
grant execute on function public.my_weekly_pass() to authenticated;

create or replace function public.buy_weekly_pass(p_tier text, p_effect text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_price int;
  v_cur public.weekly_passes;
  v_launch constant timestamptz := timestamptz '2026-10-27 00:00:00+05:45';
  v_start timestamptz := greatest(now(), timestamptz '2026-10-27 00:00:00+05:45');  -- bought early: the week starts on launch day
  v_bonus interval := interval '0';
  v_exp timestamptz;
  v_bal int;
  v_ref text := 'pass:' || gen_random_uuid()::text;
  v_fx jsonb;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_tier not in ('basic','pro') then raise exception 'Pick Weekly Pass or Weekly Pro.'; end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then
    raise exception 'Your account is banned from JD tournaments.';
  end if;
  v_price := case p_tier when 'basic' then 50 else 80 end;
  if p_effect is not null and not public.fx_tier_ok(case p_tier when 'basic' then 'lite' else 'pro' end, p_effect) then
    raise exception 'That effect is not included in this pass.';
  end if;
  perform pg_advisory_xact_lock(hashtext('pass:' || auth.uid()::text));
  select * into v_cur from public.weekly_passes where player_id = auth.uid() and expires_at > now()
    order by expires_at desc limit 1;
  if found then
    if v_cur.tier = 'basic' and p_tier = 'pro' then   -- upgrade: the lite effect of the old pass ends here
      update public.effect_passes set expires_at = least(expires_at, greatest(starts_at, now()))
        where player_id = auth.uid() and code in (select ref from public.weekly_passes
          where player_id = auth.uid() and tier = 'basic' and expires_at > now() and ref is not null);
    end if;
    if v_cur.tier = 'basic' and p_tier = 'pro' and now() < v_launch then   -- upgrade before launch: same week, now Pro
      update public.weekly_passes set expires_at = starts_at where id = v_cur.id;
      v_price := 30;                                                         -- pays only the difference
    elsif v_cur.tier = p_tier or (v_cur.tier = 'pro' and p_tier = 'basic') then
      v_start := v_cur.expires_at;                                  -- stack after the current pass
    else                                                            -- basic -> pro upgrade now
      v_bonus := (v_cur.expires_at - greatest(now(), v_cur.starts_at)) * (50.0 / 80.0)::float8;
      update public.weekly_passes set expires_at = now() where player_id = auth.uid() and tier = 'basic' and expires_at > now();
    end if;
  end if;
  v_exp := v_start + interval '7 days' + v_bonus;
  v_bal := public._wallet_apply(auth.uid(), -v_price, 'pass', v_ref,
                                case p_tier when 'basic' then 'Weekly Pass' else 'Weekly Pro' end);
  insert into public.weekly_passes (player_id, tier, starts_at, expires_at, price, ref) values (auth.uid(), p_tier, v_start, v_exp, v_price, v_ref);
  if p_effect is not null then
    v_fx := public._apply_effect_plan(auth.uid(), case p_tier when 'basic' then 'fx_lite_week' else 'fx_week' end, p_effect, null, v_ref);
    update public.effect_passes set starts_at = v_start, expires_at = v_exp where code = v_ref;   -- effect runs with the pass week
    v_fx := v_fx || jsonb_build_object('starts_at', v_start, 'expires_at', v_exp);
  end if;
  insert into public.notifications (player_id, title, body) values (auth.uid(),
    case p_tier when 'basic' then '🎟 Weekly Pass active' else '👑 Weekly Pro active' end,
    case when v_start > now() then 'Starts ' || to_char(v_start at time zone 'Asia/Kathmandu', 'Dy DD Mon') || ', valid until ' else 'Valid until ' end || to_char(v_exp at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM') || ' NPT. ' ||
    case p_tier when 'basic' then 'You can join every free JD tournament this week.'
                else 'Free tournaments, Pro effect, 24 h early registration, waitlist priority and your PRO badge.' end);
  return jsonb_build_object('tier', p_tier, 'starts_at', v_start, 'expires_at', v_exp, 'balance', v_bal, 'effect', v_fx);
end;
$$;
revoke all on function public.buy_weekly_pass(text, text) from public, anon;
grant execute on function public.buy_weekly_pass(text, text) to authenticated;

-- registration: pass required for free tournaments starting on/after 27 Oct; Weekly Pro joins early access
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

  -- Weekly Pass: free tournaments from Tue 27 Oct 2026 need an active pass (new registrations only)
  v_start := public.tournament_start_at(p_tournament_slug);
  if coalesce(public.tournament_entry_npr(p_tournament_slug), 0) = 0
     and coalesce(v_start, now()) >= timestamptz '2026-10-27 00:00:00+05:45'
     and not exists(select 1 from public.registrations where tournament_slug = p_tournament_slug and player_id = auth.uid())
     and public.weekly_pass_tier(auth.uid(), greatest(coalesce(v_start, now()), now())) is null then
    raise exception 'Free tournaments from 27 Oct need a Weekly Pass that covers the match day: Rs 50 / week (join every free tournament) or Weekly Pro Rs 80. Get it at jdesport.co.uk/pass';
  end if;

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

-- waitlist: Weekly Pro squads are promoted first, then first come first served
create or replace function public.promote_from_waitlist()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_tournament text := coalesce(new.tournament_slug, old.tournament_slug);
  v_slots int;
  v_count int;
  v_next public.registrations;
begin
  select slots into v_slots from public.tournament_capacity where tournament_slug = v_tournament;
  if v_slots is null then
    return coalesce(new, old);
  end if;
  select count(*) into v_count from public.registrations
    where tournament_slug = v_tournament and status in ('confirmed', 'approved');
  if v_count >= v_slots then
    return coalesce(new, old);
  end if;
  select * into v_next from public.registrations
    where tournament_slug = v_tournament and status = 'waitlisted'
    order by (public.weekly_pass_tier(player_id) = 'pro') desc nulls last, created_at asc
    limit 1;
  if not found then
    return coalesce(new, old);
  end if;
  update public.registrations set status = 'confirmed' where id = v_next.id;
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (
    v_next.player_id, v_tournament,
    '🎟 Off the waitlist: ' || v_tournament,
    'A slot opened up — you''re confirmed! Check the tournament card for your ticket.'
  );
  return coalesce(new, old);
end;
$function$;

-- public roster carries the pass tier (PRO badge); return type changes, so drop + recreate
drop function if exists public.get_public_roster();
create function public.get_public_roster()
 returns table(tournament_slug text, squad_name text, squad_logo text, registered_at timestamp with time zone, effect text, pass_tier text)
 language sql stable security definer set search_path to 'public'
as $function$
  select r.tournament_slug, r.squad_name, coalesce(r.squad_logo, p.squad_logo), r.created_at,
    coalesce(r.effect, (
      select ep.effect from public.effect_passes ep
      where ep.player_id = r.player_id and ep.starts_at <= now() and ep.expires_at > now()
      order by ep.expires_at asc limit 1
    )),
    public.weekly_pass_tier(r.player_id)
  from public.registrations r left join public.players p on p.id = r.player_id
  where r.status in ('confirmed', 'approved')
  order by r.created_at asc;
$function$;
grant execute on function public.get_public_roster() to anon, authenticated;

-- daily announcement until launch day (one per day, 18:00 NPT), then the job removes itself
create table if not exists public.jd_pass_announce_log (day date primary key, sent_at timestamptz not null default now(), recipients int);
alter table public.jd_pass_announce_log enable row level security;

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
  v_title := case when v_left = 0 then '🎟 Weekly Pass starts TODAY'
                  when v_left = 1 then '🎟 Weekly Pass starts tomorrow'
                  else '🎟 New: Weekly Pass from Tue 27 Oct (' || v_left || ' days)' end;
  v_body := 'From Tue 27 Oct, joining free JD tournaments needs a Weekly Pass (buy early: your 7 days start on 27 Oct). Rs 50 / week - join every free '
         || 'tournament + squad effects. Weekly Pro Rs 80: Pro effects, 24 h early registration, first in line on '
         || 'waitlists and a PRO badge. Get it at jdesport.co.uk/pass';
  insert into public.notifications (player_id, title, body, push)
    select id, v_title, v_body, true from public.players;
  get diagnostics v_n = row_count;
  update public.jd_pass_announce_log set recipients = v_n where day = v_today;
  return v_n;
end;
$$;
revoke all on function public.jd_pass_announce() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'jd-pass-announce';
select cron.schedule('jd-pass-announce', '15 12 * * *', 'select public.jd_pass_announce()');

commit;
