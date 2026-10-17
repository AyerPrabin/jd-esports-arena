-- Moderators: a limited role for the /mod/ panel (2026-10-17).
-- A moderator can: view today's & upcoming tournaments, see each squad's WhatsApp number for reminders,
-- and send push notifications / announcements. They CANNOT touch money, bans, tournaments, plans or the
-- full admin. Access is by their JD Esports Arena sign-in email being listed here (added from /admin/).
-- Only the edge functions (service role) read this table; nothing is exposed to players.
begin;
create table if not exists public.moderators (
  email text primary key,
  note text,
  added_at timestamptz not null default now()
);
alter table public.moderators enable row level security;
-- no policies on purpose: only the service role (mod-panel / admin) touches it
commit;
