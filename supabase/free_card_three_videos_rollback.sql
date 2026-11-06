-- Puts back the wording from before free_card_three_videos.sql
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

    left('Your ' || p.platform || ' post didn''t qualify' || coalesce(': ' || v_note, '') || case when p.kind = 'engage' then '. Follow @ayer_fire and like, repost and comment on our latest video from that account, and write your JD username in the comment. Then send it again.' when p.kind = 'repost' then '. Your video must be about JD Arena and say how to download it. Fix it and send it again.' else '. It needs 1,000+ real views and must tag AyerFire. You can send another post.' end, 300));

  return 'rejected';

end $function$
;

CREATE OR REPLACE FUNCTION public.register_for_tournament(p_tournament_slug text, p_squad_name text, p_squad_logo text, p_status text, p_payment_screenshot text, p_device_type text, p_pay_points boolean DEFAULT false, p_price_seen integer DEFAULT 0)
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
     -- full: the waitlist costs nothing and keeps the card; the place itself costs 20 points (waitlist_buy_slot)
     and coalesce((select count(*) from public.registrations x where x.tournament_slug = p_tournament_slug and x.status in ('confirmed','approved'))
                  < (select c.slots from public.tournament_capacity c where c.tournament_slug = p_tournament_slug), true)
     and not public._free_event_exempt(auth.uid(), greatest(now(), coalesce(v_start, now()))) then
    if p_pay_points then   -- only when the player chose it: an old cached page can never charge anyone
      if p_price_seen is distinct from 15 then   -- an old cached page said 5: never charge more than the player saw
        raise exception 'Free tournaments now cost 15 points. Close and reopen the page, then join again.';
      end if;
      v_pts := 15;
    else
      select id into v_card from public.entry_vouchers
        where player_id = auth.uid() and used_reg is null and expires_at > now()
        order by (tier = 'free') desc nulls last, max_npr asc nulls last, expires_at limit 1 for update skip locked;
      if v_card is null then
        raise exception 'FREE_CARD_NEEDED: Free tournaments need a free card or 15 points. For your first card: follow @ayer_fire and like, comment on and repost our latest video (one time only). After that, make a video about JD Arena. Send it in Wallet > Free entry.';
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
    raise exception 'This event is full, so your 15 points were not taken.';
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

$function$
;
commit;
