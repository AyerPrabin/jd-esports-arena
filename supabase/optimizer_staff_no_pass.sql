-- ── JD-Optimiers: moderators and the admin don't need a Weekly Pass (2026-10-23, owner decision) ──
-- They still need an Optimizer plan. Only the optimizer's pass check changes: prizes, entries and
-- effects work the same as for every player. Staff = an email in public.moderators, or the owner's account.
begin;

create or replace function public._optimizer_pass_ok(p_player uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.weekly_pass_tier(p_player, greatest(now(), timestamptz '2026-10-27 00:00:00+05:45')) is not null
      or exists (select 1 from public.players p
                 where p.id = p_player
                   and (lower(p.email) = 'ayerprabin95@gmail.com'
                        or lower(p.email) in (select lower(email) from public.moderators)))
$$;
revoke all on function public._optimizer_pass_ok(uuid) from public, anon, authenticated;

-- download page: staff without a pass show as 'staff'
create or replace function public.optimizer_can_download()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('pass', public._optimizer_pass_ok(auth.uid()),
                            'pass_tier', coalesce(public.weekly_pass_tier(auth.uid(), greatest(now(), timestamptz '2026-10-27 00:00:00+05:45')),
                                                  case when public._optimizer_pass_ok(auth.uid()) then 'staff' end))
$$;
revoke all on function public.optimizer_can_download() from public, anon;
grant execute on function public.optimizer_can_download() to authenticated;

commit;
