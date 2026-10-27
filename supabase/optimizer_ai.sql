-- JD-Optimiers v5.9 "AI Doctor" (2026-10-27). One file, safe to run again.
begin;

-- 1. The optimizer-ai edge function logs each check here so one plan can't burn the shared AI quota (6 checks
--    per PC token per day). Only a hash of the token is kept - no report text, no personal data. Service role only.
create table if not exists public.optimizer_ai_uses (
  id bigint generated always as identity primary key,
  token_hash text not null,
  at timestamptz not null default now()
);
create index if not exists optimizer_ai_uses_token_at on public.optimizer_ai_uses (token_hash, at desc);
alter table public.optimizer_ai_uses enable row level security;
revoke all on public.optimizer_ai_uses from anon, authenticated;

-- 2. "My PC" card on /optimizer/: the latest AI Doctor answer per linked PC. The player reads their own rows;
--    only the edge function (service role) writes.
create table if not exists public.optimizer_ai_latest (
  device_id uuid primary key references public.optimizer_devices(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  score int check (score between 0 and 10),
  headline text not null default '' check (length(headline) <= 300),
  advice text not null default '' check (length(advice) <= 4000),
  at timestamptz not null default now()
);
create index if not exists optimizer_ai_latest_player on public.optimizer_ai_latest (player_id);
alter table public.optimizer_ai_latest enable row level security;
drop policy if exists "players read own ai checks" on public.optimizer_ai_latest;
create policy "players read own ai checks" on public.optimizer_ai_latest for select using (auth.uid() = player_id);
revoke insert, update, delete on public.optimizer_ai_latest from anon, authenticated;
grant select on public.optimizer_ai_latest to authenticated;

-- 3. What other players with the same graphics card got (anonymous shared sessions, last 90 days), per renderer +
--    FPS cap. Fed to the AI so its advice is based on real JD numbers. Service role only.
create or replace function public.optimizer_gpu_stats(p_gpus text[])
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(g order by g->>'gpu', (g->>'low1')::numeric desc), '[]'::jsonb) from (
    select jsonb_build_object('gpu', data->>'hw_gpu', 'renderer', data->>'renderer', 'cap', (data->>'cap')::int,
             'sessions', count(*), 'fps', round(avg((data->>'fps')::numeric), 0),
             'low1', round(avg((data->>'low1')::numeric), 0),
             'stutter_min', round(avg((data->>'stutter_min')::numeric), 1)) as g
      from public.optimizer_sessions
     where created_at > now() - interval '90 days' and data->>'hw_gpu' = any(p_gpus)
       and (data->>'fps')::numeric > 0 and (data->>'min')::numeric >= 5
     group by data->>'hw_gpu', data->>'renderer', (data->>'cap')::int
    having count(*) >= 3 and count(distinct anon_id) >= 2) s;   -- never one player's numbers
$$;
revoke all on function public.optimizer_gpu_stats(text[]) from public, anon, authenticated;

-- 4. Owner dashboard (admin > JD-Optimiers > FPS by graphics card): per graphics card, the best renderer + cap by
--    1% low. Admin only, so it also counts the private PC reports (optimizer_pc_history, same session fields), which
--    the admin can already read; "pcs" counts anonymous IDs + linked PCs.
create or replace function public.optimizer_gpu_board()
returns jsonb language sql stable security definer set search_path = public as $$
  with raw as (
    select data, anon_id as pc, created_at from public.optimizer_sessions
    union all
    select data, device_id::text, created_at from public.optimizer_pc_history),
  s as (
    select data->>'hw_gpu' as gpu, data->>'renderer' as renderer, (data->>'cap')::int as cap,
           (data->>'fps')::numeric as fps, (data->>'low1')::numeric as low1, (data->>'stutter_min')::numeric as st,
           pc as anon_id
      from raw
     where created_at > now() - interval '90 days' and data->>'hw_gpu' is not null
       and (data->>'fps')::numeric > 0 and (data->>'min')::numeric >= 5),
  combo as (
    select gpu, renderer, cap, count(*) n, round(avg(fps), 0) fps, round(avg(low1), 0) low1, round(avg(st), 1) st
      from s group by gpu, renderer, cap having count(*) >= 3),
  best as (
    select distinct on (gpu) gpu, renderer, cap, fps, low1, st from combo order by gpu, low1 desc)
  select coalesce(jsonb_agg(jsonb_build_object('gpu', g.gpu, 'sessions', g.n, 'pcs', g.pcs, 'fps', g.fps, 'low1', g.low1,
           'best_renderer', b.renderer, 'best_cap', b.cap, 'best_fps', b.fps, 'best_low1', b.low1, 'best_stutter_min', b.st)
           order by g.n desc), '[]'::jsonb)
    from (select gpu, count(*) n, count(distinct anon_id) pcs, round(avg(fps), 0) fps, round(avg(low1), 0) low1
            from s group by gpu) g
    left join best b on b.gpu = g.gpu;
$$;
revoke all on function public.optimizer_gpu_board() from public, anon, authenticated;

commit;
