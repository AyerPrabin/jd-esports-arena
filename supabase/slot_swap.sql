-- ── Admin can swap two squads' slot numbers (2026-10-30) ──
-- A squad's slot = its position among the tournament's active squads, ordered by slot_key. slot_key is the
-- registration time unless an admin swapped it (slot_at), so swapping two squads just swaps their keys and
-- every other squad keeps its slot. Everything that numbers slots orders by slot_key: get_public_roster (the
-- homepage roster), my_tournament_slots (the ticket), _shared/slots.ts (room-code alerts, reminders),
-- list-registrations (admin) and mod-panel.
begin;

alter table public.registrations add column if not exists slot_at timestamptz;
alter table public.registrations add column if not exists slot_key timestamptz
  generated always as (coalesce(slot_at, created_at)) stored;
create index if not exists registrations_slot_key_idx on public.registrations (tournament_slug, slot_key);

-- swap two squads of the same tournament; returns both new slot numbers (null if not an active squad)
create or replace function public.admin_swap_slots(p_a uuid, p_b uuid)
returns table(a_slot int, b_slot int)
language plpgsql security definer set search_path = public as $$
declare ka timestamptz; kb timestamptz; sa text; sb text;
begin
  if p_a = p_b then raise exception 'pick two different squads'; end if;
  select slot_key, tournament_slug into ka, sa from public.registrations where id = p_a for update;
  select slot_key, tournament_slug into kb, sb from public.registrations where id = p_b for update;
  if sa is null or sb is null then raise exception 'registration not found'; end if;
  if sa <> sb then raise exception 'both squads must be in the same tournament'; end if;
  update public.registrations set slot_at = case when id = p_a then kb else ka end where id in (p_a, p_b);
  return query
    select (select s.n from (select id, row_number() over (order by slot_key)::int n from public.registrations
             where tournament_slug = sa and status in ('confirmed', 'approved')) s where s.id = p_a),
           (select s.n from (select id, row_number() over (order by slot_key)::int n from public.registrations
             where tournament_slug = sa and status in ('confirmed', 'approved')) s where s.id = p_b);
end;
$$;
revoke all on function public.admin_swap_slots(uuid, uuid) from public, anon, authenticated;

create or replace function public.my_tournament_slots()
returns table(tournament_slug text, slot integer)
language sql stable security definer set search_path = public as $$
  select s.tournament_slug, s.slot from (
    select r.tournament_slug, r.player_id,
           row_number() over (partition by r.tournament_slug order by r.slot_key)::int as slot
    from public.registrations r
    where r.status in ('confirmed','approved')
      and r.tournament_slug in (select tournament_slug from public.registrations where player_id = auth.uid())
  ) s where s.player_id = auth.uid();
$$;

-- registered_at now carries slot_key, so public_roster_version() changes when two squads swap
create or replace function public.get_public_roster()
returns table(tournament_slug text, squad_name text, squad_logo text, registered_at timestamptz, effect text, pass_tier text)
language sql stable security definer set search_path = public as $$
  select r.tournament_slug, r.squad_name,
    case when exists (select 1 from public.mega_events m where m.slug = r.tournament_slug) then null else coalesce(r.squad_logo, p.squad_logo) end,
    r.slot_key,
    coalesce(r.effect, (
      select ep.effect from public.effect_passes ep
      where ep.player_id = r.player_id and ep.starts_at <= now() and ep.expires_at > now()
      order by ep.expires_at asc limit 1
    )),
    public.weekly_pass_tier(r.player_id)
  from public.registrations r left join public.players p on p.id = r.player_id
  where r.status in ('confirmed', 'approved')
  order by r.slot_key asc;
$$;

commit;
