-- load_speed.sql (10 Nov 2026): how fast point loads are checked, for the trust note on Wallet > Load.
-- Aggregates only (median minutes + count, last 30 days): no player, amount or screenshot ever leaves.
-- Run: npx supabase db query --remote --yes -f supabase/load_speed.sql
create or replace function public.load_speed()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'median_min', round((percentile_cont(0.5) within group (order by extract(epoch from (reviewed_at - created_at)) / 60))::numeric),
    'approved', count(*))
  from public.wallet_load_requests
  where status = 'approved' and reviewed_at is not null and reviewed_at >= created_at
    and created_at > now() - interval '30 days';
$$;
revoke all on function public.load_speed() from public;
grant execute on function public.load_speed() to anon, authenticated;
