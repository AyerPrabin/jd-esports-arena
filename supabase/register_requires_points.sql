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
                   and (w.unlimited or w.balance >= public.tournament_entry_npr(p_tournament_slug))) then
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

      raise exception 'That squad name is already taken for this event â€” please pick a different name.';

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

    'ðŸŽ« Registered: ' || p_tournament_slug,

    'TICKET::' || ('JD-' || upper(substr(replace(v_row.id::text, '-', ''), 1, 8))) || '::' || v_effective_status

  );



  return v_row;

end;

$function$;
