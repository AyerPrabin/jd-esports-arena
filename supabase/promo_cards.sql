-- 2026-11-03 promo cards: ONE free-entry card per approved video (was 2). Every card has a tier and a value:
--   bronze  Rs 5   (always under 10k views, and 99.99 % of lucky draws)
--   silver  Rs 50  (lucky draw only)       gold  Rs 100  (lucky draw only)
-- A video approved with 10,000+ views gets the lucky draw (silver 0.009 %, gold 0.001 %).
-- A card pays one entry whose fee is <= its value (a cheaper event is fine, no change is given). Cards are never
-- points or cash. Old vouchers (max_npr null) keep covering any paid event, as promised when they were given.
begin;
alter table public.entry_vouchers add column if not exists tier text check (tier in ('bronze','silver','gold'));
alter table public.entry_vouchers add column if not exists max_npr int check (max_npr > 0);

create or replace function public._vouchers_fit(p uuid, p_price int)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.entry_vouchers where player_id = p and used_reg is null and expires_at > now()
    and (max_npr is null or max_npr >= coalesce(p_price, 0))
$$;
revoke all on function public._vouchers_fit(uuid, int) from public, anon, authenticated;

create or replace function public._promo_draw(p_views int)
returns text language sql volatile as $$
  select case when coalesce(p_views, 0) < 10000 then 'bronze'
              else (select case when r < 0.00001 then 'gold' when r < 0.0001 then 'silver' else 'bronze' end from (select random() r) x) end
$$;
revoke all on function public._promo_draw(int) from public, anon, authenticated;

create or replace function public.pay_entry_with_voucher(p_tournament_slug text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_price int; v_start timestamptz; v_reg public.registrations; v_slots int; v_count int; v_v bigint; v_best int;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  v_price := public.tournament_entry_npr(p_tournament_slug);
  if v_price is null or v_price <= 0 then raise exception 'This event is free, so no card is needed.'; end if;
  v_start := public.tournament_start_at(p_tournament_slug);
  if v_start is not null and v_start <= now() then raise exception 'This match has already started.'; end if;
  perform pg_advisory_xact_lock(hashtext(p_tournament_slug));
  select * into v_reg from public.registrations where tournament_slug = p_tournament_slug and player_id = auth.uid();
  if v_reg.id is null then raise exception 'Register for this tournament first.'; end if;
  if v_reg.status <> 'pending' then raise exception 'This registration does not need a payment.'; end if;
  select slots into v_slots from public.tournament_capacity where tournament_slug = p_tournament_slug;
  if v_slots is not null then
    select count(*) into v_count from public.registrations
      where tournament_slug = p_tournament_slug and status in ('confirmed','approved');
    if v_count >= v_slots then raise exception 'All slots are full, so your card was not used.'; end if;
  end if;
  -- the smallest card that covers the fee, so a Gold card is never spent on a Rs 5 event
  select id into v_v from public.entry_vouchers
    where player_id = auth.uid() and used_reg is null and expires_at > now() and (max_npr is null or max_npr >= v_price)
    order by max_npr asc nulls last, expires_at limit 1 for update skip locked;
  if v_v is null then
    select max(max_npr) into v_best from public.entry_vouchers where player_id = auth.uid() and used_reg is null and expires_at > now();
    if v_best is not null then raise exception 'Your free card covers events up to Rs %. This one costs Rs %.', v_best, v_price; end if;
    raise exception 'You have no free-entry card left.';
  end if;
  update public.entry_vouchers set used_reg = v_reg.id, used_slug = p_tournament_slug, used_at = now() where id = v_v;
  update public.registrations set status = 'approved', paid_points = 0 where id = v_reg.id;   -- 0: withdrawing never pays out points
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (auth.uid(), p_tournament_slug, '✅ Entry confirmed: ' || p_tournament_slug,
          'Free-entry card used. ' || coalesce(v_reg.squad_name, 'Your squad') || ' is confirmed. Room details will be sent here before the match.');
  return jsonb_build_object('status', 'approved', 'vouchers', public._vouchers_left(auth.uid()));
end $$;

create or replace function public.promo_mine()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'vouchers', public._vouchers_left(auth.uid()),
    'next_expiry', (select min(expires_at) from public.entry_vouchers where player_id = auth.uid() and used_reg is null and expires_at > now()),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('tier', coalesce(tier, 'any'), 'max_npr', max_npr, 'expires_at', expires_at) order by expires_at)
              from public.entry_vouchers where player_id = auth.uid() and used_reg is null and expires_at > now()), '[]'::jsonb),
    'posts', coalesce((select jsonb_agg(jsonb_build_object('url', url, 'platform', platform, 'views', views, 'status', status,
                 'note', note, 'at', created_at) order by created_at desc)
              from (select * from public.promo_posts where player_id = auth.uid() order by created_at desc limit 10) p), '[]'::jsonb))
  where auth.uid() is not null
$$;

create or replace function public.promo_review(p_id bigint, p_approve boolean, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); p public.promo_posts; v_note text := nullif(left(trim(coalesce(p_note, '')), 200), '');
        v_tier text; v_val int;
begin
  if not public._promo_reviewer() then raise exception 'Only JD staff can review promo posts.'; end if;
  select * into p from public.promo_posts where id = p_id for update;
  if p.id is null or p.status <> 'pending' then raise exception 'That post was already checked.'; end if;
  if p.player_id = v_me then raise exception 'You can''t check your own post.'; end if;
  if p_approve then
    perform pg_advisory_xact_lock(hashtext('promo:' || p.player_id));
    if (select count(*) from public.promo_posts where player_id = p.player_id and status = 'approved') >= 3 then
      raise exception 'This player already has 3 approved videos (the most allowed). Reject this one.';
    end if;
    update public.promo_posts set status = 'approved', note = v_note, reviewed_by = v_me, reviewed_at = now() where id = p.id;
    v_tier := public._promo_draw(p.views);
    v_val := case v_tier when 'gold' then 100 when 'silver' then 50 else 5 end;
    insert into public.entry_vouchers (player_id, promo_id, expires_at, tier, max_npr) values (p.player_id, p.id, now() + interval '30 days', v_tier, v_val);
    insert into public.notifications (player_id, title, body) values (p.player_id,
      case v_tier when 'gold' then '🥇 GOLD free-entry card!' when 'silver' then '🥈 SILVER free-entry card!' else '🥉 Bronze free-entry card unlocked' end,
      'Thanks for promoting JD Arena! Your ' || p.platform || ' post earned 1 ' || v_tier || ' card: one free entry to any event up to Rs ' || v_val ||
      '. Join and pick "Use free entry". It lasts 30 days. Cards are entries only, never cash.' ||
      case when p.views < 10000 then ' Get 10,000+ views on your next video for a lucky draw: Silver (Rs 50) or Gold (Rs 100).' else '' end);
    return v_tier;
  end if;
  update public.promo_posts set status = 'rejected', note = v_note, reviewed_by = v_me, reviewed_at = now() where id = p.id;
  insert into public.notifications (player_id, title, body) values (p.player_id, 'Promo post not approved',
    left('Your ' || p.platform || ' post didn''t qualify' || coalesce(': ' || v_note, '') || '. It needs 1,000+ real views and must tag AyerFire. You can send another post.', 300));
  return 'rejected';
end $$;

CREATE OR REPLACE FUNCTION public.register_for_tournament(p_tournament_slug text, p_squad_name text, p_squad_logo text, p_status text, p_payment_screenshot text, p_device_type text)
 RETURNS registrations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    -- 2026-10-22: no points, no registration (no "hold a place" entries for the admin and mods to chase)
    if not exists (select 1 from public.wallets w where w.player_id = auth.uid()
                   and (w.unlimited or w.balance >= public.tournament_entry_npr(p_tournament_slug)))
       and public._vouchers_fit(auth.uid(), public.tournament_entry_npr(p_tournament_slug)) = 0 then   -- a free-entry card that covers this fee also lets them join
      raise exception 'Not enough points: this event costs % points. Load points first (Wallet > Load points), then join.',
        public.tournament_entry_npr(p_tournament_slug);
    end if;
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
      raise exception 'That squad name is already taken for this event - please pick a different name.';
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
    'Registered: ' || p_tournament_slug,
    'TICKET::' || ('JD-' || upper(substr(replace(v_row.id::text, '-', ''), 1, 8))) || '::' || v_effective_status
  );
  return v_row;
end;
$function$;
commit;
