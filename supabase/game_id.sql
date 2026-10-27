-- Free Fire UID + in-game name on the player's account (2026-10-27). Asked at sign-up (email and Google) and
-- editable from the account panel (home.js "Game UID & name"); admins use it to check who actually played.
-- Players read their own row (existing "players read own" policy); only set_my_game_id() writes it. Safe to run again.
begin;

alter table public.players add column if not exists ff_uid text;
alter table public.players add column if not exists ff_name text;
alter table public.players drop constraint if exists players_ff_uid_format;
alter table public.players add constraint players_ff_uid_format check (ff_uid is null or ff_uid ~ '^[0-9]{6,13}$');
alter table public.players drop constraint if exists players_ff_name_len;
alter table public.players add constraint players_ff_name_len check (ff_name is null or char_length(ff_name) between 1 and 30);

create or replace function public.set_my_game_id(p_uid text, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid text := regexp_replace(coalesce(p_uid, ''), '\s', '', 'g');
  -- in-game names use fancy Unicode, so only control characters are removed
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '[[:cntrl:]]', '', 'g'));
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if v_uid !~ '^[0-9]{6,13}$' then raise exception 'Free Fire UID must be 6-13 numbers (Free Fire > your profile > UID).'; end if;
  if char_length(v_name) < 1 or char_length(v_name) > 30 then raise exception 'Enter your in-game name (up to 30 characters).'; end if;
  update public.players set ff_uid = v_uid, ff_name = v_name where id = auth.uid();
end $$;

revoke all on function public.set_my_game_id(text, text) from public, anon;
grant execute on function public.set_my_game_id(text, text) to authenticated;
commit;
