-- App push diagnostics (2026-10-27): push_fcm_tokens stayed empty after app 2.0 shipped and every client-side
-- failure was silent. home.js ensurePushSubscribed() now reports why a phone couldn't save its Firebase token
-- (one row per player, latest error wins) so the admin can see it. Safe to run again.
begin;

create table if not exists public.app_push_errors (
  player_id uuid primary key references public.players(id) on delete cascade,
  error text not null,
  app_version int,
  permission text,
  at timestamptz not null default now()
);
alter table public.app_push_errors enable row level security;
revoke all on public.app_push_errors from anon, authenticated;

create or replace function public.log_app_push_error(p_error text, p_app_version int default null, p_perm text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.app_push_errors (player_id, error, app_version, permission)
  values (auth.uid(), left(coalesce(p_error, ''), 300), p_app_version, left(p_perm, 20))
  on conflict (player_id) do update set error = excluded.error, app_version = excluded.app_version,
    permission = excluded.permission, at = now();
end $$;

-- a token saved = that phone works now
create or replace function public._clear_app_push_error() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.app_push_errors where player_id = new.player_id;
  return null;
end $$;
drop trigger if exists push_fcm_tokens_clear_error on public.push_fcm_tokens;
create trigger push_fcm_tokens_clear_error after insert or update on public.push_fcm_tokens
  for each row execute function public._clear_app_push_error();

revoke all on function public.log_app_push_error(text, int, text) from public, anon;
grant execute on function public.log_app_push_error(text, int, text) to authenticated;
revoke all on function public._clear_app_push_error() from public, anon, authenticated;
commit;
