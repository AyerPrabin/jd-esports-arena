-- Moderator audit log (2026-10-22): every confirm / unconfirm / remove / single-player message a mod makes from
-- /mod/ (mod-panel edge function, service role). No policies: only the service role and the admin read it.
begin;
create table if not exists public.mod_actions (
  id bigserial primary key,
  mod_email text not null,
  action text not null,
  detail text,
  at timestamptz not null default now()
);
alter table public.mod_actions enable row level security;
create index if not exists mod_actions_at_idx on public.mod_actions(at desc);
commit;
