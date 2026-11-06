-- 2026-11-06 owner's rule: a forgotten PIN is reset by proving the Google account (or a Gmail link).
-- The proof is a sign-in NEWER than the reset request, read from the login token's amr claim. The token is signed, and a
-- refresh keeps the original sign-in time, so an old stolen session can't pass. Rollback: wallet_pin_reset_rollback.sql
begin;
alter table public.wallet_pins add column reset_started timestamptz;

create function public._wallet_pin_fresh_proof(p_since timestamptz) returns boolean
language sql stable set search_path = public as $$
  select p_since is not null and p_since > now() - interval '15 minutes' and exists(
    select 1 from jsonb_array_elements(coalesce(auth.jwt()->'amr', '[]'::jsonb)) a
    where a->>'method' in ('oauth', 'otp', 'magiclink') and (a->>'timestamp')::numeric > extract(epoch from p_since));
$$;

create or replace function public.wallet_pin_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('has_pin', p.player_id is not null, 'reset_ready', coalesce(public._wallet_pin_fresh_proof(p.reset_started), false))
  from (select auth.uid() u) x left join public.wallet_pins p on p.player_id = x.u;
$$;

create function public.wallet_pin_reset_start() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  update public.wallet_pins set reset_started = now() where player_id = auth.uid();
  return jsonb_build_object('ok', true);
end $$;

create function public.wallet_pin_reset_finish(p_new text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_row public.wallet_pins;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform public._wallet_pin_check_new(p_new);
  select * into v_row from public.wallet_pins where player_id = auth.uid() for update;
  if v_row.player_id is null or not public._wallet_pin_fresh_proof(v_row.reset_started) then
    raise exception 'Please verify with Google again, then pick your new PIN within 15 minutes.';
  end if;
  update public.wallet_pins set pin_hash = extensions.crypt(p_new, extensions.gen_salt('bf', 10)), failed = 0, locked_until = null,
    token_hash = null, token_expires = null, reset_started = null, updated_at = now() where player_id = auth.uid();
  insert into public.notifications (player_id, title, body) values (auth.uid(), '🔒 Wallet PIN reset',
    'Your wallet PIN was reset after verifying your account. If this was not you, contact JD support now: +977 986-8813682.');
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public._wallet_pin_fresh_proof(timestamptz) from public, anon, authenticated;
revoke all on function public.wallet_pin_reset_start() from public, anon;
revoke all on function public.wallet_pin_reset_finish(text) from public, anon;
revoke all on function public.wallet_pin_status() from public, anon;
grant execute on function public.wallet_pin_reset_start() to authenticated;
grant execute on function public.wallet_pin_reset_finish(text) to authenticated;
grant execute on function public.wallet_pin_status() to authenticated;
notify pgrst, 'reload schema';
commit;
