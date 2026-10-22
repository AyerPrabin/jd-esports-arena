-- ── Private PC reports from JD-Optimiers (v5.5, 2026-10-22) ──
-- After each session (only if the player said yes in the app), the PC's specs + score, the emulator settings and
-- the session's FPS / Stable-FPS go to the player's own JD account through their linked device token.
-- Who can read them: the player (their own rows, RLS) and the JD admin (service role: admin ZULU's snapshot, the
-- optimizer-admin function). Never public, never other players. No files, no mouse / aim numbers.
begin;

create table if not exists public.optimizer_pc_reports (
  device_id uuid primary key references public.optimizer_devices(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  pc jsonb not null default '{}'::jsonb check (pg_column_size(pc) < 4096),
  last_session jsonb not null default '{}'::jsonb check (pg_column_size(last_session) < 4096),
  sessions int not null default 0,
  updated_at timestamptz not null default now()
);
create index if not exists optimizer_pc_reports_player on public.optimizer_pc_reports(player_id);

create table if not exists public.optimizer_pc_history (
  id bigserial primary key,
  device_id uuid not null references public.optimizer_devices(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  data jsonb not null check (pg_column_size(data) < 4096),
  created_at timestamptz not null default now()
);
create index if not exists optimizer_pc_history_dev on public.optimizer_pc_history(device_id, created_at desc);

alter table public.optimizer_pc_reports enable row level security;
alter table public.optimizer_pc_history enable row level security;
drop policy if exists "player reads own pc reports" on public.optimizer_pc_reports;
create policy "player reads own pc reports" on public.optimizer_pc_reports for select using ((select auth.uid()) = player_id);
drop policy if exists "player reads own pc history" on public.optimizer_pc_history;
create policy "player reads own pc history" on public.optimizer_pc_history for select using ((select auth.uid()) = player_id);

-- App -> account. p_data = {"pc": {...specs, score, tier...}, "session": {...fps, stable, settings...}}
create or replace function public.optimizer_pc_report(p_token text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_dev uuid; v_player uuid;
begin
  select id, player_id into v_dev, v_player from public.optimizer_devices
   where token_hash = public._optimizer_hash(p_token) and revoked_at is null;
  if v_dev is null then raise exception 'This PC is not linked.'; end if;
  if jsonb_typeof(p_data) <> 'object' or jsonb_typeof(p_data->'pc') <> 'object' or jsonb_typeof(p_data->'session') <> 'object' then
    raise exception 'Bad report.';
  end if;
  if (select count(*) from public.optimizer_pc_history where device_id = v_dev and created_at > now() - interval '1 day') >= 40 then
    return jsonb_build_object('saved', false, 'reason', 'daily limit');
  end if;
  insert into public.optimizer_pc_reports as r (device_id, player_id, pc, last_session, sessions, updated_at)
  values (v_dev, v_player, p_data->'pc', p_data->'session', 1, now())
  on conflict (device_id) do update set pc = excluded.pc, last_session = excluded.last_session,
    sessions = r.sessions + 1, updated_at = now(), player_id = excluded.player_id;
  insert into public.optimizer_pc_history (device_id, player_id, data) values (v_dev, v_player, p_data->'session');
  delete from public.optimizer_pc_history h where h.device_id = v_dev and h.id not in
    (select id from public.optimizer_pc_history where device_id = v_dev order by created_at desc limit 100);
  return jsonb_build_object('saved', true);
end;
$$;
revoke all on function public.optimizer_pc_report(text, jsonb) from public;
grant execute on function public.optimizer_pc_report(text, jsonb) to anon, authenticated;

-- The signed-in player's own PCs (for ZULU's account note and the profile page).
create or replace function public.my_pc_reports()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('pc', r.pc, 'last', r.last_session, 'sessions', r.sessions, 'updated', r.updated_at)
         order by r.updated_at desc), '[]'::jsonb)
  from public.optimizer_pc_reports r where r.player_id = auth.uid();
$$;
revoke all on function public.my_pc_reports() from public, anon;
grant execute on function public.my_pc_reports() to authenticated;

commit;
