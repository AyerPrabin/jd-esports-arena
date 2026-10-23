-- Moderator roles (2026-10-23): invited scrim hosts get their own, smaller role.
--  * staff : the owner's own mods (everything in /mod/: all events, JD Esports chat, prize payouts)
--  * host  : an invited scrim host. Sees ONLY the events whose "host" field (tournaments.json) is their handle:
--            squads, room codes, notifications to those squads, results (no prize payouts). No JD Esports chat,
--            no "all players" notifications, and they don't get the JD Esports chat alerts.
-- handle = the host's public name used in an event's "host" field (e.g. their TikTok @, without the @).
begin;
alter table public.moderators add column if not exists role text not null default 'staff';
alter table public.moderators add column if not exists handle text;
alter table public.moderators drop constraint if exists moderators_role_check;
alter table public.moderators add constraint moderators_role_check check (role in ('staff', 'host'));
alter table public.moderators drop constraint if exists moderators_host_handle_check;
alter table public.moderators add constraint moderators_host_handle_check check (role <> 'host' or coalesce(handle, '') <> '');
create unique index if not exists moderators_handle_key on public.moderators (lower(handle)) where handle is not null;
commit;
