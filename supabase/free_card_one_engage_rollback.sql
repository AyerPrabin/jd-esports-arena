-- Puts back the free-card functions as they were before free_card_one_engage.sql
begin;
CREATE OR REPLACE FUNCTION public.promo_mine()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

  select jsonb_build_object(

    'vouchers', public._vouchers_left(auth.uid()),
    'free_ok', public._free_event_exempt(auth.uid(), now()) or public._vouchers_left(auth.uid()) > 0,

    'next_expiry', (select min(expires_at) from public.entry_vouchers where player_id = auth.uid() and used_reg is null and expires_at > now()),

    'cards', coalesce((select jsonb_agg(jsonb_build_object('tier', coalesce(tier, 'any'), 'max_npr', max_npr, 'expires_at', expires_at) order by expires_at)

              from public.entry_vouchers where player_id = auth.uid() and used_reg is null and expires_at > now()), '[]'::jsonb),

    'posts', coalesce((select jsonb_agg(jsonb_build_object('url', url, 'kind', kind, 'platform', platform, 'views', views, 'status', status,

                 'note', note, 'at', created_at) order by created_at desc)

              from (select * from public.promo_posts where player_id = auth.uid() order by created_at desc limit 10) p), '[]'::jsonb))

  where auth.uid() is not null

$function$
;

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

end $function$
;

CREATE OR REPLACE FUNCTION public.promo_submit_engage(p_handle text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.promo_submit_repost(p_url text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$
;
commit;
