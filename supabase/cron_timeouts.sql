-- tournament-reminders and cleanup-unverified-registrations timed out at pg_net's default 5 s on busy runs
-- (12 timeouts in 24 h on 2026-10-23), so slow reminder rounds could be cut short. Give them 60 s.
select cron.alter_job(jobid, command := replace(command, E'body := ''{}''::jsonb\n  );', E'body := ''{}''::jsonb,\n    timeout_milliseconds := 60000\n  );'))
from cron.job where jobname in ('tournament-reminders', 'cleanup-unverified-registrations') and command not like '%timeout_milliseconds%';
