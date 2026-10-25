-- ── Waitlist slots that open late (2026-10-25) ──
-- A squad moved up from the waitlist after the confirm window closed (24h before start) could never tap
-- "Confirm you're playing": its ticket said "your seat may be released" and the mod panel's "Replace unconfirmed"
-- would have thrown it out again. Now:
--   promoted_at          set when the waitlist (trigger) or a mod (give_slot) gives the squad a slot
--   confirm_attendance   a promoted squad can confirm right up to the start
--   the slot notification tells the squad exactly that, and its push opens the ticket (push-notifications)
-- Order stays as before: Pro pass holders first, then sign-up time.
begin;

alter table public.registrations add column if not exists promoted_at timestamptz;

create or replace function public.promote_from_waitlist()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_tournament text := coalesce(new.tournament_slug, old.tournament_slug);
  v_slots int; v_count int; v_next public.registrations; v_start timestamptz;
begin
  select slots into v_slots from public.tournament_capacity where tournament_slug = v_tournament;
  if v_slots is null then return coalesce(new, old); end if;
  select count(*) into v_count from public.registrations
    where tournament_slug = v_tournament and status in ('confirmed', 'approved');
  if v_count >= v_slots then return coalesce(new, old); end if;
  select * into v_next from public.registrations
    where tournament_slug = v_tournament and status = 'waitlisted'
    order by (public.weekly_pass_tier(player_id) = 'pro') desc nulls last, created_at asc
    limit 1;
  if not found then return coalesce(new, old); end if;
  update public.registrations set status = 'confirmed', promoted_at = now() where id = v_next.id;
  v_start := public.tournament_start_at(v_tournament);
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (
    v_next.player_id, v_tournament,
    '🎟 Off the waitlist: ' || v_tournament,
    'A slot opened up and your squad "' || coalesce(v_next.squad_name, 'your squad') || '" is in! ' ||
    case when v_start is not null and now() >= v_start - interval '48 hours'
      then 'Open your ticket now and tap "Confirm you''re playing" so the slot stays yours.'
      else 'Open your ticket - you can confirm from 48 hours before the start.' end
  );
  return coalesce(new, old);
end;
$$;

create or replace function public.confirm_attendance(p_slug text)
returns public.registrations language plpgsql security definer set search_path = public as $$
declare v_row public.registrations; v_start timestamptz; v_promoted timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  v_start := public.tournament_start_at(p_slug);
  select promoted_at into v_promoted from public.registrations where tournament_slug = p_slug and player_id = auth.uid();
  if v_start is not null then
    if now() < v_start - interval '48 hours' then
      raise exception 'Confirmation opens 48 hours before the match (at % NPT).',
        to_char((v_start - interval '48 hours') at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM');
    end if;
    -- squads that got their slot from the waitlist can confirm until the start
    if now() >= v_start - interval '24 hours' and (v_promoted is null or now() >= v_start) then
      raise exception 'Confirmation has closed (it closes 24 hours before start).';
    end if;
  end if;
  update public.registrations set checked_in_at = coalesce(checked_in_at, now())
    where tournament_slug = p_slug and player_id = auth.uid() and status in ('confirmed','approved')
    returning * into v_row;
  if not found then raise exception 'No confirmed registration found for this tournament.'; end if;
  return v_row;
end; $$;

commit;
notify pgrst, 'reload schema';
