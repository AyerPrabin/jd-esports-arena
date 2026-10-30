-- ── Reliable push (2026-10-30) ──
-- push-notifications marks each row pushed_at once it is sent; this cron resends rows that never got it (a timeout,
-- a cold start, an FCM hiccup), every 5 min for 30 min. The trigger also waits 60 s instead of pg_net's default 5 s.
alter table public.notifications add column if not exists pushed_at timestamptz;
create index if not exists notifications_unpushed_idx on public.notifications (created_at) where push and pushed_at is null;
-- rows from before this change count as done, so the first sweep doesn't resend old alerts
update public.notifications set pushed_at = created_at where pushed_at is null and created_at < now() - interval '30 minutes';

create or replace function public.notifications_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ids uuid[];
begin
  select array_agg(id) into v_ids from new_rows where push;
  if v_ids is null then return null; end if;
  begin
    perform net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/push-notifications',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
      ),
      body := jsonb_build_object('ids', to_jsonb(v_ids)),
      timeout_milliseconds := 60000
    );
  exception when others then
    raise warning 'notifications_push: %', sqlerrm;
  end;
  return null;
end;
$$;

select cron.unschedule('push-retry-sweep') where exists (select 1 from cron.job where jobname = 'push-retry-sweep');
select cron.schedule('push-retry-sweep', '*/5 * * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/push-notifications',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')),
    body := '{"sweep": true}'::jsonb, timeout_milliseconds := 60000);
$$);
