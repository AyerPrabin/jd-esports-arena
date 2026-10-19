-- ── no-show final warning (2026-10-20) ──
-- A squad that registered and didn't show up can register again, but the join form shows
-- a final warning. Counts only real no-shows (did_not_show), not the confirm-deadline sweep.
create or replace function public.my_no_show_count()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.jd_no_show_log
  where player_id = auth.uid() and reason = 'did_not_show';
$$;
revoke all on function public.my_no_show_count() from public, anon;
grant execute on function public.my_no_show_count() to authenticated;
