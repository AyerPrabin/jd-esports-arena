-- ── ZULU sees more of what was announced (2026-10-20) ──
-- 7 days instead of 3, broadcasts to 3+ players (results go to just the squads that played),
-- up to 12. Same privacy filter: no room codes, tickets, wallet/prize/withdraw messages, and
-- per-squad messages (warnings name the squad, so each body is unique and never qualifies).
create or replace function public.recent_announcements()
returns table(title text, body text)
language sql stable security definer set search_path = public as $$
  select title, body from (
    select n.title, n.body, count(distinct n.player_id) as recips, max(n.created_at) as last_at
    from public.notifications n
    where n.created_at > now() - interval '7 days'
      and n.room_id is null and n.room_pass is null
      and n.title not like 'Room code%'
      and coalesce(n.body,'') not like 'TICKET::%'
      and n.title !~* 'withdraw|prize|wallet|points|🪙|💸'
      and coalesce(n.body,'') !~* 'wallet|withdraw|esewa|prize for|points were added'
    group by n.title, n.body
    having count(distinct n.player_id) >= 3
    order by max(n.created_at) desc
    limit 12
  ) x;
$$;
revoke all on function public.recent_announcements() from public, anon, authenticated;
grant execute on function public.recent_announcements() to service_role;
