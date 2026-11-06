-- 2026-11-06: two mods approving the same TikTok account at once can't both give a card.
begin;
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

    if p.kind = 'engage' and exists(select 1 from public.promo_posts where player_id = p.player_id and kind = 'engage' and status = 'approved') then
      raise exception 'This player already got their one follow and repost card. Reject this one: they need to make a video about JD Arena.';
    end if;
    if p.kind = 'engage' then perform pg_advisory_xact_lock(hashtext('promo-handle:' || lower(p.url))); end if;
    if p.kind = 'engage' and exists(select 1 from public.promo_posts where kind = 'engage' and status = 'approved' and id <> p.id and lower(url) = lower(p.url)) then
      raise exception 'This TikTok account already earned a card for another player. Reject this one.';
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

    left('Your ' || p.platform || ' post didn''t qualify' || coalesce(': ' || v_note, '') || case when p.kind = 'engage' then '. From that account, follow @ayer_fire, then comment on and repost 3 of our videos, with your JD username in each comment. Then send it again.' when p.kind = 'repost' then '. Your video must be about JD Arena and say how to download it. Fix it and send it again.' else '. It needs 1,000+ real views and must tag AyerFire. You can send another post.' end, 300));

  return 'rejected';

end $function$
;
commit;
