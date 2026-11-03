-- 2026-11-03 Find Teammates v2: each card also shows online now, events played and clash wins, and online players
-- sort first. Only public, low-detail numbers (no last-seen time, no money). Safe to run again.
create or replace function public.lfg_list(p_tournament text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x.j order by x.mine desc, x.online desc, x.created_at desc), '[]'::jsonb) from (
    select p.created_at, p.player_id = auth.uid() as mine,
      coalesce(pl.last_seen_at > now() - interval '3 minutes', false) as online,
      jsonb_build_object(
      'id', p.id, 'player', pl.id, 'username', pl.username, 'logo', pl.squad_logo,
      'ign', pl.ff_name, 'uid', case when auth.uid() is not null then pl.ff_uid end,
      'kind', p.kind, 'roles', p.roles, 'pay', p.pay, 'amount', p.amount, 'tournament', p.tournament,
      'note', p.note, 'at', p.created_at, 'mine', p.player_id = auth.uid(),
      'online', coalesce(pl.last_seen_at > now() - interval '3 minutes', false),
      'events', (select count(*) from public.registrations r where r.player_id = p.player_id and r.status in ('confirmed','approved')),
      'clash_w', (select count(*) from public.challenges c where c.winner = p.player_id and c.status = 'completed'),
      -- you and them, for the card's button: friend | sent (you asked) | received (they asked) | null
      'rel', case when auth.uid() is not null and p.player_id <> auth.uid() then
        (select case when f.status = 'accepted' then 'friend' when f.requester = auth.uid() then 'sent' else 'received' end
           from public.friendships f
          where least(f.requester, f.addressee) = least(auth.uid(), p.player_id)
            and greatest(f.requester, f.addressee) = greatest(auth.uid(), p.player_id) limit 1) end) as j
    from public.teammate_posts p join public.players pl on pl.id = p.player_id
    where p.expires_at > now() and pl.ff_uid is not null
      and (p_tournament is null or p.tournament in ('', p_tournament))
      and not exists(select 1 from public.banned_players b where b.player_id = p.player_id)
      and (auth.uid() is null or not public._blocked_either(auth.uid(), p.player_id))
    order by p.player_id = auth.uid() desc, p.created_at desc
    limit 60
  ) x
$$;
