-- JD-Optimiers v5.9 "AI Doctor": the optimizer-ai edge function logs each check here so one plan can't
-- burn the shared AI quota (6 checks per PC token per day). Only a hash of the token is kept - no report
-- text, no personal data. Service role only (RLS on, no policies).
create table if not exists public.optimizer_ai_uses (
  id bigint generated always as identity primary key,
  token_hash text not null,
  at timestamptz not null default now()
);
create index if not exists optimizer_ai_uses_token_at on public.optimizer_ai_uses (token_hash, at desc);
alter table public.optimizer_ai_uses enable row level security;
revoke all on public.optimizer_ai_uses from anon, authenticated;
