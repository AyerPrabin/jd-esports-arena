-- Promote JD Arena, earn free entries (2026-11-02).
-- A player posts about JD Arena on TikTok / YouTube / Facebook / Instagram, tags AyerFire, and sends
-- the link once the post passes 500 views. A JD staff mod or the admin opens the link, checks the
-- views and the tag, and approves: the player gets 2 free-entry vouchers (one paid event each,
-- 30 days). Vouchers are NOT points: they can't be withdrawn, moved or turned into points, so a
-- faked view count can never become cash. One approved post per player every 30 days.
-- Safe to run again. Rollback for register_for_tournament: promo_vouchers_rollback.sql
begin;

create table if not exists public.promo_posts (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  url text not null check (length(url) between 12 and 300 and url ~* '^https://'),
  url_key text not null,
  platform text not null check (platform in ('tiktok','youtube','facebook','instagram')),
  views int not null check (views between 500 and 100000000),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  note text check (note is null or length(note) <= 200),
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
-- the same post can't be claimed twice (a rejected one may be sent again later, e.g. once it has the views)
create unique index if not exists promo_posts_url_live on public.promo_posts (url_key) where status <> 'rejected';
create index if not exists promo_posts_player on public.promo_posts (player_id, created_at desc);
create index if not exists promo_posts_pending on public.promo_posts (created_at) where status = 'pending';
alter table public.promo_posts enable row level security;   -- no policies: RPCs only

create table if not exists public.entry_vouchers (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  promo_id bigint references public.promo_posts(id) on delete set null,
  expires_at timestamptz not null,
  used_reg uuid,          -- registration it paid for; cleared again if that registration is removed before the start
  used_slug text,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists entry_vouchers_free on public.entry_vouchers (player_id, expires_at) where used_reg is null;
create index if not exists entry_vouchers_reg on public.entry_vouchers (used_reg) where used_reg is not null;
alter table public.entry_vouchers enable row level security;   -- no policies: RPCs only

create or replace function public._vouchers_left(p uuid)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.entry_vouchers where player_id = p and used_reg is null and expires_at > now()
$$;
revoke all on function public._vouchers_left(uuid) from public, anon, authenticated;

-- staff mod or the owner (never a host mod)
create or replace function public._promo_reviewer()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select lower(email) from auth.users where id = auth.uid()) = 'ayerprabin95@gmail.com', false)
      or exists(select 1 from public.moderators m
                where m.role = 'staff' and m.email = lower((select email from auth.users where id = auth.uid())))
$$;
revoke all on function public._promo_reviewer() from public, anon, authenticated;

-- send a post link
create or replace function public.promo_submit(p_url text, p_views int)
returns text language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_url text := trim(coalesce(p_url, '')); v_host text; v_path text; v_query text; v_plat text; v_id text;
  v_m text[]; v_key text; v_canon text; v_last timestamptz; v_admin uuid;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  -- strict: host is letters/digits/dots/dashes only (no user@, port or backslash tricks that open a different
  -- site than the one shown), path is plain URL characters only
  if v_url !~ '^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~:/?#@!$&''()*+,;=%-]+$' or length(v_url) > 300 then
    raise exception 'Paste the full link to your post (starting with https://).';
  end if;
  -- no dot segments, encoded dots/slashes or doubled slashes (paths a browser would read differently)
  if v_url ~ '/\.{1,2}(/|\?|#|$)' or v_url ~* '%(2e|2f|5c)' or substring(v_url from 9) ~ '//' then
    raise exception 'That link looks broken. Copy it again with the Share button.';
  end if;
  if p_views is null or p_views < 500 then raise exception 'The post needs at least 500 views first.'; end if;
  if p_views > 100000000 then raise exception 'Check the view count.'; end if;
  v_host := lower(substring(v_url from '^https://([A-Za-z0-9.-]+)/'));
  v_path := substring(v_url from '^https://[A-Za-z0-9.-]+(/[^?#]*)');
  v_query := coalesce(substring(v_url from '\?([^#]*)'), '');
  -- one post = one key: the platform's own ID, read from an exact link shape (IDs are case-sensitive).
  -- The link we store and show to mods is rebuilt from that ID, so mods check the same post the key names.
  if v_host in ('youtube.com', 'www.youtube.com', 'm.youtube.com', 'youtu.be') then
    v_plat := 'youtube';
    if v_host = 'youtu.be' then v_id := substring(v_path from '^/([A-Za-z0-9_-]{11})/?$');
    elsif v_path ~ '^/watch/?$' then
      if (select count(*) from regexp_matches(v_query, '(^|&)v=', 'g')) = 1 then
        v_id := substring(v_query from '(?:^|&)v=([A-Za-z0-9_-]{11})(?:&|$)');
      end if;
    else v_id := substring(v_path from '^/(?:shorts|live|embed)/([A-Za-z0-9_-]{11})/?$');
    end if;
    if v_id is not null then v_key := 'yt:' || v_id; v_canon := 'https://www.youtube.com/watch?v=' || v_id; end if;
  elsif v_host in ('tiktok.com', 'www.tiktok.com', 'm.tiktok.com') then
    v_plat := 'tiktok';
    v_m := regexp_match(v_path, '^/@([A-Za-z0-9._-]{1,40})/(video|photo)/([0-9]{6,25})/?$');
    if v_m is not null then v_key := 'tt:' || v_m[3]; v_canon := 'https://www.tiktok.com/@' || v_m[1] || '/' || v_m[2] || '/' || v_m[3]; end if;
  elsif v_host in ('instagram.com', 'www.instagram.com') then
    v_plat := 'instagram'; v_id := substring(v_path from '^/(?:[A-Za-z0-9._]{1,30}/)?(?:p|reel|reels|tv)/([A-Za-z0-9_-]{5,40})/?$');
    if v_id is not null then v_key := 'ig:' || v_id; v_canon := 'https://www.instagram.com/p/' || v_id || '/'; end if;
  elsif v_host in ('facebook.com', 'www.facebook.com', 'm.facebook.com', 'web.facebook.com') then
    v_plat := 'facebook';
    v_id := substring(v_path from '^/(?:[A-Za-z0-9.]{1,50}/)?(?:videos|reel|reels)/([0-9]{6,25})/?$');
    if v_id is null and v_path ~ '^/watch/?$' and (select count(*) from regexp_matches(v_query, '(^|&)v=', 'g')) = 1 then
      v_id := substring(v_query from '(?:^|&)v=([0-9]{6,25})(?:&|$)');
    end if;
    if v_id is not null then v_key := 'fb:' || v_id; v_canon := 'https://www.facebook.com/watch/?v=' || v_id; end if;
  end if;
  -- short share links (vm.tiktok.com, fb.watch) hide the video ID, so the same video could be claimed twice:
  -- ask for the full link instead
  if v_host in ('vm.tiktok.com', 'vt.tiktok.com', 'fb.watch') then
    raise exception 'Short links can''t be checked. Open the video in your browser and copy the full link (tiktok.com/@you/video/… or facebook.com/…/videos/…).';
  end if;
  if v_plat is null then raise exception 'Use a TikTok, YouTube, Facebook or Instagram link.'; end if;
  if v_key is null then raise exception 'Use the link to the video or post itself (tap Share > Copy link in the app).'; end if;
  v_url := v_canon;
  if exists(select 1 from public.promo_posts where url_key = v_key and status <> 'rejected') then
    raise exception 'This post was already sent.';
  end if;
  if (select count(*) from public.promo_posts where player_id = v_me and status = 'pending') >= 2 then
    raise exception 'You already have posts waiting for a check. We''ll look at those first.';
  end if;
  if (select count(*) from public.promo_posts where player_id = v_me and created_at > now() - interval '1 day') >= 5 then
    raise exception 'Too many posts today. Try again tomorrow.';
  end if;
  select max(reviewed_at) into v_last from public.promo_posts where player_id = v_me and status = 'approved';
  if v_last > now() - interval '30 days' then
    raise exception 'You got free entries on %. Your next post can earn more from %.',
      to_char(v_last at time zone 'Asia/Kathmandu', 'DD Mon'), to_char((v_last + interval '30 days') at time zone 'Asia/Kathmandu', 'DD Mon');
  end if;
  insert into public.promo_posts (player_id, url, url_key, platform, views) values (v_me, v_url, v_key, v_plat, p_views);
  select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com' limit 1;
  if v_admin is not null and v_admin <> v_me then
    insert into public.notifications (player_id, title, body)
    values (v_admin, '📣 Promo post to check', public._chat_name(v_me) || ' sent a ' || v_plat || ' post (' || p_views || ' views). Check it in the Mod panel → Promo.');
  end if;
  return 'sent';
end $$;

-- my posts + vouchers
create or replace function public.promo_mine()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'vouchers', public._vouchers_left(auth.uid()),
    'next_expiry', (select min(expires_at) from public.entry_vouchers where player_id = auth.uid() and used_reg is null and expires_at > now()),
    'posts', coalesce((select jsonb_agg(jsonb_build_object('url', url, 'platform', platform, 'views', views, 'status', status,
                 'note', note, 'at', created_at) order by created_at desc)
              from (select * from public.promo_posts where player_id = auth.uid() order by created_at desc limit 10) p), '[]'::jsonb))
  where auth.uid() is not null
$$;

-- review queue (staff mods + admin)
create or replace function public.promo_queue()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public._promo_reviewer() then raise exception 'Only JD staff can review promo posts.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'url', p.url, 'platform', p.platform, 'views', p.views,
      'at', p.created_at, 'username', pl.username, 'ign', pl.ff_name,
      'approved_before', (select count(*) from public.promo_posts x where x.player_id = p.player_id and x.status = 'approved'))
      order by p.created_at)
    from public.promo_posts p join public.players pl on pl.id = p.player_id where p.status = 'pending'), '[]'::jsonb);
end $$;

create or replace function public.promo_review(p_id bigint, p_approve boolean, p_note text default null)
returns text language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); p public.promo_posts; v_note text := nullif(left(trim(coalesce(p_note, '')), 200), '');
begin
  if not public._promo_reviewer() then raise exception 'Only JD staff can review promo posts.'; end if;
  select * into p from public.promo_posts where id = p_id for update;
  if p.id is null or p.status <> 'pending' then raise exception 'That post was already checked.'; end if;
  if p.player_id = v_me then raise exception 'You can''t check your own post.'; end if;
  if p_approve then
    perform pg_advisory_xact_lock(hashtext('promo:' || p.player_id));
    if exists(select 1 from public.promo_posts where player_id = p.player_id and status = 'approved'
              and reviewed_at > now() - interval '30 days') then
      raise exception 'This player already got free entries in the last 30 days. Reject this one.';
    end if;
    update public.promo_posts set status = 'approved', note = v_note, reviewed_by = v_me, reviewed_at = now() where id = p.id;
    insert into public.entry_vouchers (player_id, promo_id, expires_at)
      select p.player_id, p.id, now() + interval '30 days' from generate_series(1, 2);
    insert into public.notifications (player_id, title, body) values (p.player_id, '🎟️ 2 free entries unlocked!',
      'Thanks for promoting JD Arena! Your ' || p.platform || ' post earned 2 free-entry vouchers. Join any paid event and pick "Use free entry". They last 30 days.');
    return 'approved';
  end if;
  update public.promo_posts set status = 'rejected', note = v_note, reviewed_by = v_me, reviewed_at = now() where id = p.id;
  insert into public.notifications (player_id, title, body) values (p.player_id, 'Promo post not approved',
    left('Your ' || p.platform || ' post didn''t qualify' || coalesce(': ' || v_note, '') || '. It needs 500+ real views and must tag AyerFire. You can send another post.', 300));
  return 'rejected';
end $$;

-- pay a held (pending) entry with a voucher instead of points
create or replace function public.pay_entry_with_voucher(p_tournament_slug text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_price int; v_start timestamptz; v_reg public.registrations; v_slots int; v_count int; v_v bigint;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  v_price := public.tournament_entry_npr(p_tournament_slug);
  if v_price is null or v_price <= 0 then raise exception 'This event is free, so no voucher is needed.'; end if;
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
    if v_count >= v_slots then raise exception 'All slots are full, so your voucher was not used.'; end if;
  end if;
  select id into v_v from public.entry_vouchers
    where player_id = auth.uid() and used_reg is null and expires_at > now()
    order by expires_at limit 1 for update skip locked;
  if v_v is null then raise exception 'You have no free-entry voucher left.'; end if;
  update public.entry_vouchers set used_reg = v_reg.id, used_slug = p_tournament_slug, used_at = now() where id = v_v;
  update public.registrations set status = 'approved', paid_points = 0 where id = v_reg.id;   -- 0: withdrawing never pays out points
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (auth.uid(), p_tournament_slug, '✅ Entry confirmed: ' || p_tournament_slug,
          'Free-entry voucher used — ' || coalesce(v_reg.squad_name, 'your squad') || ' is confirmed. Room details will be sent here before the match.');
  return jsonb_build_object('status', 'approved', 'vouchers', public._vouchers_left(auth.uid()));
end $$;

-- a voucher-paid registration removed before the start (withdrawn, not confirmed in time, removed by a mod): voucher comes back
create or replace function public._voucher_back()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.entry_vouchers set used_reg = null, used_slug = null, used_at = null
   where used_reg = old.id
     and coalesce(public.tournament_start_at(old.tournament_slug) > now(), true);
  return old;
end $$;
drop trigger if exists registrations_voucher_back on public.registrations;
create trigger registrations_voucher_back after delete on public.registrations
  for each row execute function public._voucher_back();

revoke all on function public.promo_submit(text, int) from public, anon;
revoke all on function public.promo_mine() from public, anon;
revoke all on function public.promo_queue() from public, anon;
revoke all on function public.promo_review(bigint, boolean, text) from public, anon;
revoke all on function public.pay_entry_with_voucher(text) from public, anon;
grant execute on function public.promo_submit(text, int) to authenticated;
grant execute on function public.promo_mine() to authenticated;
grant execute on function public.promo_queue() to authenticated;
grant execute on function public.promo_review(bigint, boolean, text) to authenticated;
grant execute on function public.pay_entry_with_voucher(text) to authenticated;

-- live register_for_tournament (2026-11-02) with one change: a free-entry voucher passes the "no points, no registration" check
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
       and public._vouchers_left(auth.uid()) = 0 then   -- a free-entry voucher (promo_vouchers.sql) also lets them join
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
