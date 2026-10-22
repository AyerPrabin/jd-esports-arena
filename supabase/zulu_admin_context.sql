-- ── Admin ZULU live business snapshot (2026-10-22) ──
-- One call for everything the organiser asks the admin ZULU about: money in/out today and this week, what is
-- waiting (point loads + withdrawals, with their ids so ZULU can propose Approve / Mark paid actions), every
-- upcoming event's seats, Weekly Pass / referral / Optimizer numbers and ZULU usage. Service role only - the
-- zulu-admin-command function calls it after checking the admin.
create or replace function public.zulu_admin_context()
returns jsonb language sql stable security definer set search_path = public as $$
  with day0 as (select date_trunc('day', now() at time zone 'Asia/Kathmandu') at time zone 'Asia/Kathmandu' as t)
  select jsonb_build_object(
    'now_npt', to_char(now() at time zone 'Asia/Kathmandu', 'Dy DD Mon YYYY HH24:MI'),
    'players', jsonb_build_object(
      'total', (select count(*) from public.players),
      'new_today', (select count(*) from public.players, day0 where created_at >= day0.t),
      'new_7d', (select count(*) from public.players where created_at > now() - interval '7 days'),
      'active_today', (select count(*) from public.players, day0 where last_seen_at >= day0.t),
      'app_installed', (select count(*) from public.players where app_installed_at is not null),
      'banned', (select count(*) from public.banned_players)),
    'money_today', (select jsonb_object_agg(reason, jsonb_build_object('n', n, 'points', pts)) from (
      select reason, count(*) n, sum(delta) pts from public.wallet_ledger, day0 where created_at >= day0.t group by reason) x),
    'money_7d', (select jsonb_object_agg(reason, jsonb_build_object('n', n, 'points', pts)) from (
      select reason, count(*) n, sum(delta) pts from public.wallet_ledger where created_at > now() - interval '7 days' group by reason) x),
    'wallets_total_points', (select coalesce(sum(balance), 0) from public.wallets where not coalesce(unlimited, false)),
    'pending_loads', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'player', coalesce(p.username, p.player_tag),
        'amount', l.amount, 'waiting', to_char(now() - l.created_at, 'HH24"h"MI"m"')) order by l.created_at), '[]'::jsonb)
      from public.wallet_load_requests l left join public.players p on p.id = l.player_id where l.status = 'pending'),
    'pending_withdrawals', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'player', coalesce(p.username, p.player_tag),
        'amount', w.amount, 'send_rs', w.payout, 'esewa', w.esewa_id, 'name', w.esewa_name,
        'waiting', to_char(now() - w.created_at, 'HH24"h"MI"m"')) order by w.created_at), '[]'::jsonb)
      from public.withdraw_requests w left join public.players p on p.id = w.player_id where w.status = 'pending'),
    'pending_entry_payments', (select count(*) from public.registrations where status = 'pending'),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('name', t->>'name', 'start', t->>'start', 'status', t->>'status',
        'prize', t->>'prize', 'entry', t->>'entry', 'slots', c.slots,
        'confirmed', (select count(*) from public.registrations r where r.tournament_slug = t->>'name' and r.status in ('confirmed','approved')),
        'playing_confirmed', (select count(*) from public.registrations r where r.tournament_slug = t->>'name' and r.status in ('confirmed','approved') and r.checked_in_at is not null),
        'waitlisted', (select count(*) from public.registrations r where r.tournament_slug = t->>'name' and r.status = 'waitlisted'),
        'pending_pay', (select count(*) from public.registrations r where r.tournament_slug = t->>'name' and r.status = 'pending'))), '[]'::jsonb)
      from public.site_content s, jsonb_array_elements(s.content->'tournaments') t
      left join public.tournament_capacity c on c.tournament_slug = t->>'name'
      where s.key = 'tournaments' and coalesce(t->>'status', 'upcoming') not in ('completed', 'cancelled')
        and coalesce(public.tournament_start_at(t->>'name'), now()) > now() - interval '12 hours'),
    'weekly_pass', jsonb_build_object(
      'active_now', (select count(distinct player_id) from public.weekly_passes where starts_at <= now() and expires_at > now()),
      'bought_upcoming', (select count(distinct player_id) from public.weekly_passes where starts_at > now()),
      'pro', (select count(distinct player_id) from public.weekly_passes where tier = 'pro' and expires_at > now()),
      'sold_7d', (select count(*) from public.weekly_passes where created_at > now() - interval '7 days'),
      'points_7d', (select coalesce(sum(price), 0) from public.weekly_passes where created_at > now() - interval '7 days')),
    'referrals', jsonb_build_object(
      'total', (select count(*) from public.referrals),
      'bonus_paid', (select count(*) from public.referrals where bonus_paid_at is not null),
      'top', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (select coalesce(p.username, p.player_tag) as player, count(*) as invited
              from public.referrals r join public.players p on p.id = r.referrer_id group by 1 order by 2 desc limit 5) x)),
    'optimizer', jsonb_build_object(
      'active_plans', (select count(*) from public.optimizer_plans where expires_at > now()),
      'max', (select count(*) from public.optimizer_plans where expires_at > now() and tier = 'max'),
      'linked_pcs', (select count(*) from public.optimizer_devices where revoked_at is null),
      'shared_sessions_7d', (select count(*) from public.optimizer_sessions where created_at > now() - interval '7 days')),
    'zulu_chats_today', (select count(*) from public.zulu_ai_reply_log, day0 where created_at >= day0.t),
    'no_shows_7d', (select count(*) from public.registrations where status = 'no_show' and created_at > now() - interval '7 days'));
$$;
revoke all on function public.zulu_admin_context() from public, anon, authenticated;
grant execute on function public.zulu_admin_context() to service_role;
