-- invite_first_play.sql (10 Nov 2026): the invite card now comes when the invited friend PLAYS their
-- first event (was: only when their squad won its first prize, which almost never happened).
-- Never points. Rules, all checked here:
--   * the friend saved a Free Fire UID that no older account uses, and not the inviter's UID;
--   * the friend was in a confirmed squad that tapped "Confirm you're playing" (as captain, or by UID in the
--     verified line-up of a squad the inviter doesn't captain), the event started 2+ hours ago, still exists and isn't cancelled, and the squad
--     wasn't removed as a no-show;
--   * once per friend (referrals.bonus_paid_at), at most 3 friends per inviter (set_referrer already caps
--     invites at 3; checked again here), inviter not banned.
-- The old prize path (_award_one) still pays if a prize comes first: bonus_paid_at keeps it to one card.
-- Runs every 10 minutes from pg_cron (one indexed query over unpaid referrals, a handful of rows).
-- Run: npx supabase db query --remote --yes -f supabase/invite_first_play.sql
-- Undo: select cron.unschedule('invite-first-play'); drop function public.invite_first_play_sweep();

create or replace function public.invite_first_play_sweep()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select rf.referred_id, rf.referrer_id, coalesce(f.username, f.player_tag, 'Your invited friend') as friend
    from public.referrals rf
    join public.players f on f.id = rf.referred_id
    where rf.bonus_paid_at is null
      and coalesce(trim(f.ff_uid), '') <> ''
      and not public._referral_same_account(rf.referred_id, rf.referrer_id)
      and not exists (select 1 from public.players o where o.id <> f.id and trim(o.ff_uid) = trim(f.ff_uid) and o.created_at < f.created_at)
      and not exists (select 1 from public.banned_players b where b.player_id = rf.referrer_id)
      and (select count(*) from public.referrals x where x.referrer_id = rf.referrer_id and x.bonus_paid_at is not null) < 3
      and exists (
        select 1 from public.registrations g
        where (g.player_id = f.id or (g.player_id <> rf.referrer_id and g.lineup @> jsonb_build_array(jsonb_build_object('uid', trim(f.ff_uid)))))
          and g.status in ('confirmed', 'approved') and g.checked_in_at is not null
          and public.tournament_start_at(g.tournament_slug) between f.created_at and now() - interval '2 hours'
          and exists (select 1 from public.site_content s, jsonb_array_elements(s.content->'tournaments') t
                      where s.key = 'tournaments' and t->>'name' = g.tournament_slug and coalesce(t->>'status', '') <> 'cancelled')
          and not exists (select 1 from public.jd_no_show_log ns
                          where ns.tournament_slug = g.tournament_slug and ns.player_id = g.player_id and ns.restored_at is null))
    order by rf.created_at
  loop
    perform pg_advisory_xact_lock(hashtext('ref:' || r.referrer_id::text));
    update public.referrals set bonus_paid_at = now()
      where referred_id = r.referred_id and bonus_paid_at is null
        and (select count(*) from public.referrals x where x.referrer_id = r.referrer_id and x.bonus_paid_at is not null) < 3;
    if found then
      insert into public.entry_vouchers (player_id, expires_at, tier, max_npr) values (r.referrer_id, now() + interval '30 days', 'free', 1);
      insert into public.notifications (player_id, title, body) values (r.referrer_id, 'Free entry card: your friend played',
        r.friend || ' played their first JD event, so you got a free entry card. It joins one free event and lasts 30 days.');
      n := n + 1;
    end if;
  end loop;
  return n;
end;
$$;
revoke all on function public.invite_first_play_sweep() from public, anon, authenticated;

-- the inviter's alert when a friend uses their code: new wording (rest is the live definition, unchanged)
create or replace function public.set_referrer(p_code text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_code text := upper(regexp_replace(trim(coalesce(p_code, '')), '^@', ''));
  v_ref uuid;
  v_name text;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.referrals where referred_id = auth.uid()) then
    raise exception 'You already joined with a friend''s invite code.';
  end if;
  if (select created_at from public.players where id = auth.uid()) < now() - interval '14 days' then
    raise exception 'Invite codes work in your first 14 days on JD Arena.';
  end if;
  if exists(select 1 from public.wallet_ledger where player_id = auth.uid() and reason = 'prize') then
    raise exception 'Invite codes are for new players who haven''t won a prize yet.';
  end if;
  if v_code = '' then raise exception 'Enter your friend''s JD tag or username.'; end if;
  select id, coalesce(username, player_tag) into v_ref, v_name from public.players
    where upper(player_tag) = v_code or upper(player_tag) = 'JD-' || v_code or upper(username) = v_code limit 1;
  if v_ref is null then raise exception 'No player with that JD tag or username.'; end if;
  if v_ref = auth.uid() then raise exception 'You can''t use your own code.'; end if;
  if exists(select 1 from public.referrals where referred_id = v_ref and referrer_id = auth.uid()) then
    raise exception 'You invited this player - you can''t use their code too.';
  end if;
  if public._referral_same_account(auth.uid(), v_ref) then raise exception 'That code can''t be used.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_ref) then raise exception 'That code can''t be used.'; end if;
  perform pg_advisory_xact_lock(hashtext('ref:' || v_ref::text));
  if (select count(*) from public.referrals where referrer_id = v_ref) >= 3 then
    raise exception '% already invited 3 friends, the most allowed. Ask another friend for their code.', v_name;
  end if;
  insert into public.referrals (referred_id, referrer_id) values (auth.uid(), v_ref);
  insert into public.notifications (player_id, title, body) values (v_ref, 'A friend joined with your code',
    coalesce((select coalesce(username, player_tag) from public.players where id = auth.uid()), 'A new player') ||
    ' signed up with your invite. When they play their first event, you get a free entry card.');
  return jsonb_build_object('inviter', v_name);
end;
$function$;

-- 'played' = friends who earned the inviter a card (same as 'won'/'cards', kept for old app pages)
create or replace function public.my_referrals()
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    'code', (select player_tag from public.players where id = auth.uid()),
    'invited', (select count(*) from public.referrals where referrer_id = auth.uid()),
    'won', (select count(*) from public.referrals where referrer_id = auth.uid() and bonus_paid_at is not null),
    'played', (select count(*) from public.referrals where referrer_id = auth.uid() and bonus_paid_at is not null),
    'cards', (select count(*) from public.referrals where referrer_id = auth.uid() and bonus_paid_at is not null),
    'inviter', (select coalesce(p.username, p.player_tag) from public.referrals r join public.players p on p.id = r.referrer_id
                where r.referred_id = auth.uid()),
    'inviter_bonus_paid', (select bonus_paid_at is not null from public.referrals where referred_id = auth.uid()),
    'can_enter', (select created_at > now() - interval '14 days' from public.players where id = auth.uid())
                 and not exists(select 1 from public.referrals where referred_id = auth.uid())
                 and not exists(select 1 from public.wallet_ledger where player_id = auth.uid() and reason = 'prize'));
$function$;

select cron.unschedule('invite-first-play') where exists (select 1 from cron.job where jobname = 'invite-first-play');
select cron.schedule('invite-first-play', '*/10 * * * *', $$select public.invite_first_play_sweep()$$);
