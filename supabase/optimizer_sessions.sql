-- ── Anonymous FPS stats from JD-Optimiers (v5.0, opt-in) ──
-- A player who turns "Share anonymous FPS stats" on sends one summary per session: FPS numbers, emulator
-- settings and the PC model. No account, name or mouse numbers: rows carry only a random ID made on that PC
-- (anon_id). A valid, linked device token is required so strangers can't flood the table, but the token is
-- NOT stored with the row. 30 rows per anon ID per day. A daily GitHub Action in the private repo
-- AyerPrabin/jd-optimizer-data pulls them through the optimizer-data-export function.
begin;

create table if not exists public.optimizer_sessions (
  id bigserial primary key,
  anon_id text not null check (anon_id ~ '^[0-9a-f]{32}$'),
  data jsonb not null check (pg_column_size(data) < 4096),
  created_at timestamptz not null default now()
);
create index if not exists optimizer_sessions_anon on public.optimizer_sessions(anon_id, created_at desc);
alter table public.optimizer_sessions enable row level security;   -- no policies: only the service role reads

create or replace function public.optimizer_share_session(p_token text, p_anon text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from public.optimizer_devices where token_hash = public._optimizer_hash(p_token) and revoked_at is null) then
    raise exception 'This PC is not linked.';
  end if;
  if p_anon !~ '^[0-9a-f]{32}$' or jsonb_typeof(p_data) <> 'object' then raise exception 'Bad stats.'; end if;
  if (select count(*) from public.optimizer_sessions where anon_id = p_anon and created_at > now() - interval '1 day') >= 30 then
    return jsonb_build_object('saved', false, 'reason', 'daily limit');
  end if;
  insert into public.optimizer_sessions (anon_id, data) values (p_anon, p_data);
  return jsonb_build_object('saved', true);
end;
$$;
revoke all on function public.optimizer_share_session(text, text, jsonb) from public;
grant execute on function public.optimizer_share_session(text, text, jsonb) to anon, authenticated;

commit;
