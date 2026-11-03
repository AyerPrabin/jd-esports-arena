-- 2026-11-03 Wallet alerts the payment-in function could not use (no amount, not a "received" alert).
-- Lets the admin see what eSewa / Khalti actually said so the parser can be fixed. Kept 14 days. Service role only.
begin;
create table if not exists public.payments_in_skipped (
  id bigserial primary key,
  app text,
  why text not null,
  raw text not null check (length(raw) <= 600),
  created_at timestamptz not null default now()
);
alter table public.payments_in_skipped enable row level security;   -- no policies: service role only
create index if not exists payments_in_skipped_at on public.payments_in_skipped (created_at desc);
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'payments_in_skipped_prune';
    perform cron.schedule('payments_in_skipped_prune', '17 3 * * *', $c$delete from public.payments_in_skipped where created_at < now() - interval '14 days'$c$);
  end if;
end $$;
commit;
