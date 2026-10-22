-- ── squad slot numbers (2026-10-22) ──
-- Rule: squads sit in the seat matching their slot in the app. Slot = position among the
-- tournament's active squads (confirmed/approved) by registration time — the same order
-- the mod panel numbers them in. Players can't read other squads' rows, so this runs
-- security definer and returns only the caller's own slots.
create or replace function public.my_tournament_slots()
returns table(tournament_slug text, slot int) language sql stable security definer set search_path = public as $$
  select s.tournament_slug, s.slot from (
    select r.tournament_slug, r.player_id,
           row_number() over (partition by r.tournament_slug order by r.created_at)::int as slot
    from public.registrations r
    where r.status in ('confirmed','approved')
      and r.tournament_slug in (select tournament_slug from public.registrations where player_id = auth.uid())
  ) s where s.player_id = auth.uid();
$$;
revoke all on function public.my_tournament_slots() from public, anon;
grant execute on function public.my_tournament_slots() to authenticated;
