-- ── "Update ready" push for the Android app (2026-10-30) ──
-- app-update-push (every 30 min) pushes app phones older than /download/android.json's versionCode, once per
-- player per version (this log). Server only.
create table if not exists public.app_update_pushes (
  player_id uuid not null references public.players(id) on delete cascade,
  version_code int not null,
  sent_at timestamptz not null default now(),
  primary key (player_id, version_code)
);
alter table public.app_update_pushes enable row level security;   -- no policies: server only

select cron.unschedule('app-update-push') where exists (select 1 from cron.job where jobname = 'app-update-push');
select cron.schedule('app-update-push', '*/30 * * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/app-update-push',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 60000);
$$);
