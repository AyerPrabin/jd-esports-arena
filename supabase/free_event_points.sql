-- 2026-11-05 owner's rule: a player who doesn't want to repost, comment and post can join a free tournament for
-- 5 points instead. Opt-in only (p_pay_points). Exempt players are never charged. Rollback: free_event_points_rollback.sql
begin;
drop function public.register_for_tournament(text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION public.register_for_tournament(p_tournament_slug text, p_squad_name text, p_squad_logo text, p_status text, p_payment_screenshot text, p_device_type text, p_pay_points boolean DEFAULT false)
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
  v_card bigint;
  v_pts int := 0;

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

  -- 2026-11-05 owner's rule: a free event needs a free-entry card (repost + comment + post, promo_submit_repost)
  if not v_already_registered and coalesce(public.tournament_entry_npr(p_tournament_slug), 0) = 0
     and not public._free_event_exempt(auth.uid(), greatest(now(), coalesce(v_start, now()))) then
    if p_pay_points then   -- only when the player chose it: an old cached page can never charge anyone
      v_pts := 5;
    else
      select id into v_card from public.entry_vouchers
        where player_id = auth.uid() and used_reg is null and expires_at > now()
        order by (tier = 'free') desc nulls last, max_npr asc nulls last, expires_at limit 1 for update skip locked;
      if v_card is null then
        raise exception 'FREE_CARD_NEEDED: Free tournaments need a free card or 5 points. For a card: post about JD Arena, or follow @ayer_fire and like, comment on and repost our latest video. Then send it in Wallet > Free entry.';
      end if;
    end if;
  end if;
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

  if v_pts > 0 and v_effective_status <> 'confirmed' then
    raise exception 'This event is full, so your 5 points were not taken.';
  end if;
  insert into public.registrations (tournament_slug, player_id, squad_name, squad_logo, status, payment_screenshot, device_type)

  values (p_tournament_slug, auth.uid(), trim(v_name), null, v_effective_status, p_payment_screenshot, p_device_type)

  returning * into v_row;
  if v_pts > 0 then   -- paid_points: withdrawing, the confirm sweep and no-show refunds all pay back from this
    perform public._wallet_apply(auth.uid(), -v_pts, 'entry', v_row.id::text, p_tournament_slug);
    update public.registrations set paid_points = v_pts where id = v_row.id returning * into v_row;
  end if;
  if v_card is not null then
    update public.entry_vouchers set used_reg = v_row.id, used_slug = p_tournament_slug, used_at = now() where id = v_card;
  end if;

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
revoke all on function public.register_for_tournament(text, text, text, text, text, text, boolean) from public, anon;
grant execute on function public.register_for_tournament(text, text, text, text, text, text, boolean) to authenticated;
notify pgrst, 'reload schema';

-- 2026-11-05 owner's rule: a card comes from a post about JD Arena OR follow + like + comment + repost on our videos.
-- That second way has no post to link, so the player sends their TikTok username and a mod checks the account.
alter table public.promo_posts drop constraint if exists promo_posts_kind_check;
alter table public.promo_posts add constraint promo_posts_kind_check check (kind in ('views','repost','engage'));
alter table public.promo_posts drop constraint if exists promo_posts_views_check;
alter table public.promo_posts add constraint promo_posts_views_check check (views = 0 and kind in ('repost','engage') or views between 500 and 100000000);

create or replace function public.promo_submit_repost(p_url text)
returns text language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_url text := trim(coalesce(p_url, '')); v_host text; v_path text; v_query text; v_plat text; v_id text;
  v_m text[]; v_key text; v_canon text; v_admin uuid;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  if v_url !~ '^https://[A-Za-z0-9.-]+/[A-Za-z0-9._~:/?#@!$&''()*+,;=%-]+$' or length(v_url) > 300 then
    raise exception 'Paste the full link to your post (starting with https://).';
  end if;
  if v_url ~ '/\.{1,2}(/|\?|#|$)' or v_url ~* '%(2e|2f|5c)' or substring(v_url from 9) ~ '//' then
    raise exception 'That link looks broken. Copy it again with the Share button.';
  end if;
  v_host := lower(substring(v_url from '^https://([A-Za-z0-9.-]+)/'));
  v_path := substring(v_url from '^https://[A-Za-z0-9.-]+(/[^?#]*)');
  v_query := coalesce(substring(v_url from '\?([^#]*)'), '');
  if v_host in ('vm.tiktok.com', 'vt.tiktok.com', 'fb.watch') then
    raise exception 'Short links can''t be checked. Open your post in a browser and copy the full link.';
  elsif v_host in ('tiktok.com', 'www.tiktok.com', 'm.tiktok.com') then
    v_plat := 'tiktok';
    v_m := regexp_match(v_path, '^/@([A-Za-z0-9._-]{1,40})/(video|photo)/([0-9]{6,25})/?$');
    if v_m is not null then v_key := 'tt:' || v_m[3]; v_canon := 'https://www.tiktok.com/@' || v_m[1] || '/' || v_m[2] || '/' || v_m[3]; end if;
  elsif v_host in ('youtube.com', 'www.youtube.com', 'm.youtube.com', 'youtu.be') then
    v_plat := 'youtube';
    if v_host = 'youtu.be' then v_id := substring(v_path from '^/([A-Za-z0-9_-]{11})/?$');
    elsif v_path ~ '^/watch/?$' and (select count(*) from regexp_matches(v_query, '(^|&)v=', 'g')) = 1 then v_id := substring(v_query from '(?:^|&)v=([A-Za-z0-9_-]{11})(?:&|$)');
    else v_id := substring(v_path from '^/(?:shorts|live)/([A-Za-z0-9_-]{11})/?$');
    end if;
    if v_id is not null then v_key := 'yt:' || v_id; v_canon := 'https://www.youtube.com/watch?v=' || v_id; end if;
  elsif v_host in ('instagram.com', 'www.instagram.com') then
    v_plat := 'instagram'; v_id := substring(v_path from '^/(?:[A-Za-z0-9._]{1,30}/)?(?:p|reel|reels)/([A-Za-z0-9_-]{5,40})/?$');
    if v_id is not null then v_key := 'ig:' || v_id; v_canon := 'https://www.instagram.com/p/' || v_id || '/'; end if;
  elsif v_host in ('facebook.com', 'www.facebook.com', 'm.facebook.com', 'web.facebook.com') then
    v_plat := 'facebook';
    v_m := regexp_match(v_path, '^/share/([pvr])/([A-Za-z0-9]{6,30})/?$');
    if v_m is not null then v_key := 'fb:s:' || v_m[2]; v_canon := 'https://www.facebook.com/share/' || v_m[1] || '/' || v_m[2] || '/';
    else
      v_m := regexp_match(v_path, '^/([A-Za-z0-9.]{1,50})/(videos|posts|reel)/([A-Za-z0-9]{6,60})/?$');
      if v_m is not null then v_key := 'fb:' || v_m[3]; v_canon := 'https://www.facebook.com/' || v_m[1] || '/' || v_m[2] || '/' || v_m[3];
      else
        v_id := substring(v_path from '^/reel/([0-9]{6,25})/?$');
        if v_id is not null then v_key := 'fb:' || v_id; v_canon := 'https://www.facebook.com/reel/' || v_id; end if;
      end if;
    end if;
  end if;
  if v_plat is null then raise exception 'Use a TikTok, YouTube, Facebook or Instagram link.'; end if;
  if v_key is null then raise exception 'Use the link to your post itself (tap Share > Copy link).'; end if;
  perform pg_advisory_xact_lock(hashtext('promo:' || v_me));
  if exists(select 1 from public.promo_posts where url_key = v_key and status <> 'rejected') then raise exception 'This post was already sent.'; end if;
  if exists(select 1 from public.promo_posts where player_id = v_me and kind in ('repost','engage') and status = 'pending') then
    raise exception 'Your post is waiting for a check. You''ll get a notification.';
  end if;
  if exists(select 1 from public.entry_vouchers where player_id = v_me and tier = 'free' and used_reg is null and expires_at > now()) then
    raise exception 'You already have a free card. Use it first, then earn the next one.';
  end if;
  if (select count(*) from public.promo_posts where player_id = v_me and created_at > now() - interval '1 day') >= 5 then
    raise exception 'Too many posts today. Try again tomorrow.';
  end if;
  insert into public.promo_posts (player_id, url, url_key, platform, views, kind) values (v_me, v_canon, v_key, v_plat, 0, 'repost');
  select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com' limit 1;
  if v_admin is not null and v_admin <> v_me then
    insert into public.notifications (player_id, title, body)
    values (v_admin, '📣 Free card post to check', public._chat_name(v_me) || ' sent a ' || v_plat || ' post. Check it in the Mod panel > Promo.');
  end if;
  return 'sent';
end $$;

create or replace function public.promo_submit_engage(p_handle text)
returns text language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_h text; v_key text; v_admin uuid;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  v_h := regexp_replace(trim(coalesce(p_handle, '')), '^(https://(www\.|m\.)?tiktok\.com/)?@?', '', 'i');
  v_h := regexp_replace(v_h, '[/?].*$', '');
  if v_h !~ '^[A-Za-z0-9._]{2,24}$' then raise exception 'Type your TikTok username, like @yourname.'; end if;
  -- one account, one card a week: follow counts once, so a new card needs the newest video
  v_key := 'eng:' || lower(v_h) || ':' || to_char(now(), 'IYYY-IW');
  perform pg_advisory_xact_lock(hashtext('promo:' || v_me));
  if exists(select 1 from public.promo_posts where url_key = v_key and status <> 'rejected') then
    raise exception 'This TikTok account was already sent this week.';
  end if;
  if exists(select 1 from public.promo_posts where player_id = v_me and kind in ('repost','engage') and status = 'pending') then
    raise exception 'Yours is waiting for a check. You''ll get a notification.';
  end if;
  if exists(select 1 from public.entry_vouchers where player_id = v_me and tier = 'free' and used_reg is null and expires_at > now()) then
    raise exception 'You already have a free card. Use it first, then earn the next one.';
  end if;
  if (select count(*) from public.promo_posts where player_id = v_me and created_at > now() - interval '1 day') >= 5 then
    raise exception 'Too many tries today. Try again tomorrow.';
  end if;
  insert into public.promo_posts (player_id, url, url_key, platform, views, kind)
    values (v_me, 'https://www.tiktok.com/@' || v_h, v_key, 'tiktok', 0, 'engage');
  select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com' limit 1;
  if v_admin is not null and v_admin <> v_me then
    insert into public.notifications (player_id, title, body)
    values (v_admin, '📣 Free card follow to check', public._chat_name(v_me) || ' sent TikTok @' || v_h || '. Check it in the Mod panel > Promo.');
  end if;
  return 'sent';
end $$;
revoke all on function public.promo_submit_engage(text) from public, anon;
grant execute on function public.promo_submit_engage(text) to authenticated;

CREATE OR REPLACE FUNCTION public.promo_review(p_id bigint, p_approve boolean, p_note text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

declare v_me uuid := auth.uid(); p public.promo_posts; v_note text := nullif(left(trim(coalesce(p_note, '')), 200), '');

        v_tier text; v_val int;

begin

  if not public._promo_reviewer() then raise exception 'Only JD staff can review promo posts.'; end if;

  select * into p from public.promo_posts where id = p_id for update;

  if p.id is null or p.status <> 'pending' then raise exception 'That post was already checked.'; end if;

  if p.player_id = v_me then raise exception 'You can''t check your own post.'; end if;

  if p_approve then

    perform pg_advisory_xact_lock(hashtext('promo:' || p.player_id));

    if p.kind = 'views' and (select count(*) from public.promo_posts where player_id = p.player_id and kind = 'views' and status = 'approved') >= 3 then

      raise exception 'This player already has 3 approved videos (the most allowed). Reject this one.';

    end if;

    update public.promo_posts set status = 'approved', note = v_note, reviewed_by = v_me, reviewed_at = now() where id = p.id;

    if p.kind in ('repost','engage') then   -- max_npr 1: below any paid fee, so this card only opens free events
      insert into public.entry_vouchers (player_id, promo_id, expires_at, tier, max_npr) values (p.player_id, p.id, now() + interval '30 days', 'free', 1);
      insert into public.notifications (player_id, title, body) values (p.player_id, '🎟️ Your free card is ready',
        'A mod checked it. Your card joins one free tournament and lasts 30 days. Join a free event now!');
      return 'free';
    end if;
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

    left('Your ' || p.platform || ' post didn''t qualify' || coalesce(': ' || v_note, '') || case when p.kind = 'engage' then '. Follow @ayer_fire and like, comment on and repost our latest video from that account, then send it again.' when p.kind = 'repost' then '. Your post must be about JD Arena and say how to download it. Fix it and send it again.' else '. It needs 1,000+ real views and must tag AyerFire. You can send another post.' end, 300));

  return 'rejected';

end $function$;

-- correct what players were told earlier today (a re-run sends nothing)
insert into public.notifications (player_id, title, body)
  select p.id, '🎟️ Free card update: now easier', 'Get a free card in one of two ways: post about JD Arena, or follow @ayer_fire and like, comment on and repost our latest video. Send it in Wallet > Free entry. Or pay 5 points when you join. No ads and no Weekly Pass needed.' from public.players p
  where not exists(select 1 from public.banned_players b where b.player_id = p.id)
    and not exists(select 1 from public.notifications n where n.player_id = p.id and n.title = '🎟️ Free card update: now easier');

commit;
