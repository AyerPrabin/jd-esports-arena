-- 2026-11-03 Find Teammates: 🔥 Urgent boost (like a sponsored job post). A squad that needs a player pays
-- 25 JD points to pin its post at the top with an "Urgent" badge for 24 hours (stack up to 3 days).
-- Player posts ("I need a squad") are free only for now: no "I'll play for X points" posts.
-- Squads can still offer a fee to the player they pick. Safe to run again.
begin;
alter table public.wallet_ledger drop constraint if exists wallet_ledger_reason_check;
alter table public.wallet_ledger add constraint wallet_ledger_reason_check check (reason = any (array['load','entry','effect','withdraw',
  'withdraw_returned','refund','adjust','prize','challenge_stake','challenge_win','challenge_refund','optimizer','pass','referral',
  'teammate_pay','teammate_paid','lfg_boost']));
alter table public.teammate_posts add column if not exists boost_until timestamptz;

-- existing "I'll play for points" posts become free
update public.teammate_posts set pay = 'free', amount = null where kind = 'player' and pay = 'paid';

create or replace function public.lfg_boost(p_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); p public.teammate_posts; v_until timestamptz; v_bal int; c_price constant int := 25;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  select * into p from public.teammate_posts where id = p_id and player_id = v_me and expires_at > now() for update;
  if p.id is null then raise exception 'Post not found.'; end if;
  if p.kind <> 'squad' then raise exception 'Urgent boost is for squads looking for a player.'; end if;
  v_until := greatest(coalesce(p.boost_until, now()), now()) + interval '24 hours';
  if v_until > now() + interval '72 hours' then raise exception 'Already boosted for the next 2+ days. You can add more later.'; end if;
  perform public._wallet_apply(v_me, -c_price, 'lfg_boost', p.id::text, '🔥 Urgent: squad needs a player (24 h)');
  update public.teammate_posts set boost_until = v_until, expires_at = greatest(expires_at, v_until) where id = p.id;
  select balance into v_bal from public.wallets where player_id = v_me;
  return jsonb_build_object('until', v_until, 'balance', v_bal);
end $$;
revoke all on function public.lfg_boost(bigint) from public, anon;
grant execute on function public.lfg_boost(bigint) to authenticated;

CREATE OR REPLACE FUNCTION public.lfg_post(p_kind text, p_roles text[], p_pay text, p_amount integer, p_tournament text, p_note text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

declare v_me uuid := auth.uid(); v_t text := btrim(coalesce(p_tournament, '')); v_id bigint;

  v_roles text[] := (select array_agg(distinct x) from (select btrim(regexp_replace(r, '[[:cntrl:]]', '', 'g')) x

                      from unnest(coalesce(p_roles, '{}')) r) y where x <> '');

begin

  if v_me is null then raise exception 'Please sign in first.'; end if;

  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;

  if not exists(select 1 from public.players where id = v_me and ff_uid is not null and ff_name is not null) then

    raise exception 'Add your Free Fire UID and in-game name first.';

  end if;

  delete from public.teammate_posts where expires_at < now() - interval '30 days';   -- tidy old posts

  if v_roles is null then raise exception 'Pick at least one role.'; end if;

  if cardinality(v_roles) > 5 or exists(select 1 from unnest(v_roles) r where char_length(r) > 20) then

    raise exception 'Up to 5 roles, 20 characters each.';

  end if;

  if p_kind = 'player' and p_pay = 'paid' then raise exception 'Player posts are free for now. Squads can still offer a fee.'; end if;
  if p_pay = 'paid' and coalesce(p_amount, 0) not between 1 and 5000 then raise exception 'Enter the fee: 1-5000 JD points.'; end if;

  if (select count(*) from public.teammate_posts where player_id = v_me and expires_at > now() and tournament <> v_t) >= 3 then

    raise exception 'You already have 3 live posts. Delete one first.';

  end if;

  insert into public.teammate_posts (player_id, kind, roles, pay, amount, tournament, note)

    values (v_me, p_kind, v_roles, p_pay, case when p_pay = 'paid' then p_amount end, v_t,

            btrim(regexp_replace(coalesce(p_note, ''), '[[:cntrl:]]', ' ', 'g')))

  on conflict (player_id, tournament) do update set kind = excluded.kind, roles = excluded.roles, pay = excluded.pay,

    amount = excluded.amount, note = excluded.note, created_at = now(), expires_at = now() + interval '7 days'

  returning id into v_id;

  return v_id;

end $function$;

create or replace function public.lfg_list(p_tournament text default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x.j order by x.mine desc, x.urgent desc, x.online desc, x.created_at desc), '[]'::jsonb) from (
    select p.created_at, p.player_id = auth.uid() as mine, coalesce(p.boost_until > now(), false) as urgent,
      auth.uid() is not null and coalesce(pl.last_seen_at > now() - interval '3 minutes', false) as online,
      jsonb_build_object(
      'id', p.id, 'player', pl.id, 'username', pl.username, 'logo', pl.squad_logo,
      'ign', pl.ff_name, 'uid', case when auth.uid() is not null then pl.ff_uid end,
      'kind', p.kind, 'roles', p.roles, 'pay', p.pay, 'amount', p.amount, 'tournament', p.tournament,
      'note', p.note, 'at', p.created_at, 'mine', p.player_id = auth.uid(),
      'urgent', coalesce(p.boost_until > now(), false), 'boost_until', case when p.player_id = auth.uid() then p.boost_until end,
      -- presence only for signed-in callers, who always pass the block check above (anonymous callers skip it)
      'online', auth.uid() is not null and coalesce(pl.last_seen_at > now() - interval '3 minutes', false),
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
    order by p.player_id = auth.uid() desc, coalesce(p.boost_until > now(), false) desc, p.created_at desc
    limit 60
  ) x
$$;
commit;
