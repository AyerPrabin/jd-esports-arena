-- ── Late squads can confirm (2026-10-25) ──
-- jd_confirm_sweep() removes squads that didn't confirm by 24h before start; the waitlist then moves up AT THAT MOMENT,
-- and the "Seats open" alert invites new sign-ups. All of those squads arrived after the deadline, so they could never
-- confirm (Open #4: 10 of 12 slots). A squad can now confirm right up to the start when it
--   * got its slot from the waitlist (promoted_at), or
--   * signed up after the deadline, or
--   * is still unconfirmed after that event's sweep ran (everyone unconfirmed at the deadline was removed by it).
-- Backfill: squads moved up by past sweeps get promoted_at = the sweep time, so tickets and the mod panel show it.
begin;

create or replace function public.confirm_attendance(p_slug text)
returns public.registrations language plpgsql security definer set search_path = public as $$
declare v_row public.registrations; v_start timestamptz; v_reg public.registrations; v_late boolean;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  v_start := public.tournament_start_at(p_slug);
  select * into v_reg from public.registrations where tournament_slug = p_slug and player_id = auth.uid();
  if v_start is not null then
    if now() < v_start - interval '48 hours' then
      raise exception 'Confirmation opens 48 hours before the match (at % NPT).',
        to_char((v_start - interval '48 hours') at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM');
    end if;
    v_late := v_reg.promoted_at is not null or v_reg.created_at >= v_start - interval '24 hours'
              or exists (select 1 from public.jd_confirm_sweeps s where s.tournament_slug = p_slug);
    if now() >= v_start or (now() >= v_start - interval '24 hours' and not v_late) then
      raise exception 'Confirmation has closed (it closes 24 hours before start).';
    end if;
  end if;
  update public.registrations set checked_in_at = coalesce(checked_in_at, now())
    where tournament_slug = p_slug and player_id = auth.uid() and status in ('confirmed','approved')
    returning * into v_row;
  if not found then raise exception 'No confirmed registration found for this tournament.'; end if;
  return v_row;
end; $$;

update public.registrations r set promoted_at = s.swept_at
  from public.jd_confirm_sweeps s
 where r.tournament_slug = s.tournament_slug and r.status in ('confirmed','approved')
   and r.checked_in_at is null and r.promoted_at is null and r.created_at < s.swept_at;

commit;
notify pgrst, 'reload schema';
