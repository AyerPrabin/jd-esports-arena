-- JD Arena app 2.0 (2026-10-27): the app is now a real Android app (WebView), not a browser tab, so it can't use
-- Web Push. It gets a Firebase Cloud Messaging token instead; the site saves it here (save_fcm_token) and
-- _shared/push.ts sends to these tokens as well as the web-push subscriptions. Safe to run again.
begin;

create table if not exists public.push_fcm_tokens (
  token text primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  app_version int,
  created_at timestamptz not null default now(),
  last_ok_at timestamptz
);
create index if not exists push_fcm_tokens_player on public.push_fcm_tokens (player_id);
alter table public.push_fcm_tokens enable row level security;
revoke all on public.push_fcm_tokens from anon, authenticated;

create or replace function public.save_fcm_token(p_token text, p_app_version int default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_token is null or p_token !~ '^[A-Za-z0-9_:.-]{20,400}$' then raise exception 'Invalid app token.'; end if;
  -- the same phone signing in as someone else moves to that player
  insert into public.push_fcm_tokens (token, player_id, app_version) values (p_token, auth.uid(), p_app_version)
  on conflict (token) do update set player_id = excluded.player_id, app_version = excluded.app_version;
  delete from public.push_fcm_tokens where player_id = auth.uid() and token not in
    (select token from public.push_fcm_tokens where player_id = auth.uid() order by created_at desc limit 5);
end $$;

create or replace function public.delete_fcm_token(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from public.push_fcm_tokens where token = p_token and player_id = auth.uid();
$$;

revoke all on function public.save_fcm_token(text, int) from public, anon;
revoke all on function public.delete_fcm_token(text) from public, anon;
grant execute on function public.save_fcm_token(text, int) to authenticated;
grant execute on function public.delete_fcm_token(text) to authenticated;
commit;
