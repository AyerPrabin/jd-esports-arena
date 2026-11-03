-- 2026-11-03 fee direction fix. A squad post with a fee means the SQUAD pays the player it picks, so:
--   lfg_pay (viewer pays the post's owner) refuses squad posts
--   lfg_pay_player: the squad post's owner pays one friend the posted fee (once per player per post per 7 days)
-- Player posts are free only now (teammate_boost.sql), so lfg_pay has nothing to pay until that comes back.
begin;
create or replace function public.lfg_pay(p_id bigint, p_amount int)
returns int language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); p public.teammate_posts;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  select * into p from public.teammate_posts where id = p_id and expires_at > now();
  if p.id is null then raise exception 'That post is no longer up.'; end if;
  if p.kind = 'squad' then raise exception 'This squad pays the player it picks. Nothing to pay here.'; end if;
  raise exception 'Player posts are free for now.';
end $$;

create or replace function public.lfg_pay_player(p_id bigint, p_to text)
returns int language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); p public.teammate_posts; v_to uuid; v_bal int; v_ref text;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  select * into p from public.teammate_posts where id = p_id and player_id = v_me and expires_at > now() for update;
  if p.id is null then raise exception 'Post not found.'; end if;
  if p.kind <> 'squad' or p.pay <> 'paid' or p.amount is null then raise exception 'This post has no fee to pay.'; end if;
  select id into v_to from public.players where lower(username) = lower(regexp_replace(trim(coalesce(p_to, '')), '^@', ''));
  if v_to is null then raise exception 'No player called %.', p_to; end if;
  if v_to = v_me then raise exception 'You can''t pay yourself.'; end if;
  if exists(select 1 from public.banned_players where player_id in (v_me, v_to)) then raise exception 'This payment is not allowed.'; end if;
  if not public._are_friends(v_me, v_to) or public._blocked_either(v_me, v_to) then
    raise exception 'Add them as a friend first: they must accept before you pay.';
  end if;
  if coalesce((select unlimited from public.wallets where player_id = v_me), false) then raise exception 'Staff wallets can''t pay teammates.'; end if;
  v_ref := 'tm:' || p.id || ':' || v_to;
  if exists(select 1 from public.wallet_ledger where player_id = v_me and reason = 'teammate_pay' and ref = v_ref
            and created_at > now() - interval '7 days') then
    raise exception 'You already paid this player for this post.';
  end if;
  if coalesce((select -sum(delta) from public.wallet_ledger where player_id = v_me and reason = 'teammate_pay'
               and created_at > now() - interval '1 day'), 0) + p.amount > 10000 then
    raise exception 'Daily limit: 10000 points to teammates.';
  end if;
  v_bal := public._wallet_apply(v_me, -p.amount, 'teammate_pay', v_ref, 'Paid ' || public._chat_name(v_to));
  perform public._wallet_apply(v_to, p.amount, 'teammate_paid', v_ref, 'From ' || public._chat_name(v_me));
  insert into public.notifications (player_id, title, body) values (v_to, '🪙 +' || p.amount || ' JD points from your squad',
    public._chat_name(v_me) || ' paid you the teammate fee (' || p.amount || ' points). Good luck in the match!');
  return v_bal;
end $$;
revoke all on function public.lfg_pay_player(bigint, text) from public, anon;
grant execute on function public.lfg_pay_player(bigint, text) to authenticated;
commit;
