-- ── Fair-Play integrity status from JD-Optimiers Panel scans (v5.9, 2026-10-28) ──
-- After a Panel scan the app sends its verdict to JD Arena through the PC's linked device token (+ machine hash, so a
-- copied token from another PC is refused). Only the verdict, how many apps were flagged and the flagged package names
-- (e.g. "catch_.me_.if_.you_.can_ (GameGuardian)") - never the full app list, files or anything from the game.
-- report_hash is the SHA-256 of the sealed scan report; the optimizer-receipt function signs that same hash
-- (ECDSA P-256), so an organiser holding the report can check it is the scan this row came from.
-- Honest limit: the verdict is computed on the player's own PC. The token + machine hash prove WHICH linked PC sent
-- it, not that the scan was honest - a patched exe can send "clean". Treat it as a signal, not proof.
-- Who can read: the player (own rows, RLS) and the JD admin (service role). Never public.
-- Verdicts (fairplay_verdict in jd_optimiers.c) - switching ADB off must not earn the same badge as a scanned VM:
--   VERIFIED_CLEAN      every PC check clean AND the emulator's installed apps were listed and clean (adb_checked)
--   HOST_CLEAN_ADB_OFF  every PC check clean, ADB off / unreachable: fine for casual, shown to admins for prize events
--   FLAGGED             cheat signs on the PC or root / hooking / cheat apps inside the emulator
--   INCOMPLETE          a PC check could not run (game not running, no admin): scan again
-- warnings = PC-only warning lines (ADB / root access on, macro keys, test-signing); never decide the verdict.
begin;

create table if not exists public.optimizer_fairplay (
  id bigserial primary key,
  device_id uuid not null references public.optimizer_devices(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  app_version text not null check (app_version ~ '^[0-9.]{1,12}$'),
  verdict text not null check (verdict in ('VERIFIED_CLEAN', 'HOST_CLEAN_ADB_OFF', 'FLAGGED', 'INCOMPLETE')),
  adb_checked boolean not null default false,
  flagged int not null default 0 check (flagged between 0 and 999),
  warnings int not null default 0 check (warnings between 0 and 999),
  apps text not null default '' check (length(apps) <= 400),
  report_hash text check (report_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);
create index if not exists optimizer_fairplay_player on public.optimizer_fairplay(player_id, created_at desc);
create index if not exists optimizer_fairplay_dev on public.optimizer_fairplay(device_id, created_at desc);

alter table public.optimizer_fairplay enable row level security;
drop policy if exists "player reads own fairplay" on public.optimizer_fairplay;
create policy "player reads own fairplay" on public.optimizer_fairplay for select using ((select auth.uid()) = player_id);

drop function if exists public.optimizer_fairplay_report(text, text, text, text, boolean, int, text, text);
create or replace function public.optimizer_fairplay_report(p_token text, p_machine text, p_version text, p_verdict text,
  p_adb_checked boolean, p_flagged int, p_warnings int, p_apps text, p_report_hash text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.optimizer_devices%rowtype;
begin
  select * into d from public.optimizer_devices where token_hash = public._optimizer_hash(p_token) and revoked_at is null;
  if d.id is null then raise exception 'This PC is not linked.'; end if;
  if p_machine is null or p_machine !~ '^[0-9a-f]{64}$' or (d.machine_hash is not null and d.machine_hash <> p_machine) then
    raise exception 'This PC is not linked.';
  end if;
  if p_verdict is null or p_verdict not in ('VERIFIED_CLEAN', 'HOST_CLEAN_ADB_OFF', 'FLAGGED', 'INCOMPLETE') then
    raise exception 'Bad verdict.';
  end if;
  -- VERIFIED needs the emulator's app list to have been read; a client claiming otherwise is downgraded, not trusted
  if p_verdict = 'VERIFIED_CLEAN' and not coalesce(p_adb_checked, false) then p_verdict := 'HOST_CLEAN_ADB_OFF'; end if;
  if (select count(*) from public.optimizer_fairplay where device_id = d.id and created_at > now() - interval '1 day') >= 30 then
    return jsonb_build_object('saved', false, 'reason', 'daily limit');
  end if;
  insert into public.optimizer_fairplay (device_id, player_id, app_version, verdict, adb_checked, flagged, warnings, apps, report_hash)
  values (d.id, d.player_id, left(coalesce(p_version, '?'), 12), p_verdict, coalesce(p_adb_checked, false),
          greatest(0, least(coalesce(p_flagged, 0), 999)), greatest(0, least(coalesce(p_warnings, 0), 999)),
          left(coalesce(p_apps, ''), 400),
          case when p_report_hash ~ '^[0-9a-f]{64}$' then p_report_hash end);
  delete from public.optimizer_fairplay f where f.device_id = d.id and f.id not in
    (select id from public.optimizer_fairplay where device_id = d.id order by created_at desc limit 50);
  return jsonb_build_object('saved', true);
end;
$$;
revoke all on function public.optimizer_fairplay_report(text, text, text, text, boolean, int, int, text, text) from public;
grant execute on function public.optimizer_fairplay_report(text, text, text, text, boolean, int, int, text, text) to anon, authenticated;

-- ── "My PC - AI Doctor" card badges (v5.9) ──
-- Structured fields next to the advice text, written by the optimizer-ai function: emulator + temperature sensor
-- come from fixed lines of the app's own report ([Sensors (v5.9)]), bottleneck + settings from the model's
-- BOTTLENECK: / SETTINGS: machine lines (stripped from the advice). The page shows them as badges / pills.
alter table public.optimizer_ai_latest add column if not exists emulator text check (length(emulator) <= 40);
alter table public.optimizer_ai_latest add column if not exists temp_source text check (length(temp_source) <= 60);
alter table public.optimizer_ai_latest add column if not exists temp_c int check (temp_c between 0 and 130);
alter table public.optimizer_ai_latest add column if not exists bottleneck text check (length(bottleneck) <= 160);
alter table public.optimizer_ai_latest add column if not exists settings text check (length(settings) <= 240);

-- ── Room code withheld after a fair-play review (ZULU, src/zulu/arena/fairplay.py) ──
-- Only after the admin says the exact confirmation phrase; tournament-reminders skips these players at the T-5
-- release. Service role only (no RLS policy): players never see or change it.
create table if not exists public.tournament_code_withheld (
  tournament_slug text not null,
  player_id uuid not null references public.players(id) on delete cascade,
  reason text not null check (length(reason) <= 200),
  by text not null default 'admin' check (length(by) <= 80),
  created_at timestamptz not null default now(),
  primary key (tournament_slug, player_id)
);
alter table public.tournament_code_withheld enable row level security;

commit;
