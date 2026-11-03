-- 2026-11-03: up to 3 rewarded promo videos per player (replaces the one-per-30-days rule). Same bodies as promo_vouchers.sql.

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
  if p_views is null or p_views < 1000 then raise exception 'The post needs at least 1,000 views first.'; end if;
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
  -- up to 3 rewarded videos per player, ever (2026-11-02, owner's rule); pending ones count so a 4th can't queue
  if (select count(*) from public.promo_posts where player_id = v_me and status in ('approved', 'pending')) >= 3 then
    raise exception 'You have used all 3 promo videos. Each player can earn free entries from up to 3 videos.';
  end if;
  insert into public.promo_posts (player_id, url, url_key, platform, views) values (v_me, v_url, v_key, v_plat, p_views);
  select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com' limit 1;
  if v_admin is not null and v_admin <> v_me then
    insert into public.notifications (player_id, title, body)
    values (v_admin, '📣 Promo post to check', public._chat_name(v_me) || ' sent a ' || v_plat || ' post (' || p_views || ' views). Check it in the Mod panel → Promo.');
  end if;
  return 'sent';
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
    if (select count(*) from public.promo_posts where player_id = p.player_id and status = 'approved') >= 3 then
      raise exception 'This player already has 3 approved videos (the most allowed). Reject this one.';
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
    left('Your ' || p.platform || ' post didn''t qualify' || coalesce(': ' || v_note, '') || '. It needs 1,000+ real views and must tag AyerFire. You can send another post.', 300));
  return 'rejected';
end $$;
