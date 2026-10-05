-- JD Esports Arena — accounts, registrations & notifications schema.
-- Run this once in Supabase → SQL Editor (a new project's default "public" schema).
-- Safe to re-run: everything is CREATE ... IF NOT EXISTS / OR REPLACE where possible,
-- but the tables themselves will error on a second run if they already exist — that's fine,
-- it means it already worked.

-- ── players ──────────────────────────────────────────────────────────────
-- One row per signed-up player, created automatically when someone verifies
-- their email (see the trigger below). player_tag is the auto-generated
-- "unique player ID"; username is chosen by the player at signup (also
-- unique, case-insensitively — see the index below).
create table public.players (
  id uuid primary key references auth.users(id) on delete cascade,
  player_tag text unique not null,
  username text not null,
  email text,
  created_at timestamptz not null default now(),
  constraint players_username_format check (username ~ '^[A-Za-z0-9_]{3,20}$')
);

-- Case-insensitive uniqueness: "Prabin" and "prabin" collide.
create unique index players_username_lower_idx on public.players (lower(username));

alter table public.players enable row level security;

create policy "players read own row" on public.players
  for select using (auth.uid() = id);

-- Lets the signup form check "is this username taken?" before/without a
-- session (SECURITY DEFINER bypasses RLS internally) while returning only a
-- boolean — never exposes any other player's row data.
create or replace function public.is_username_taken(check_username text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.players where lower(username) = lower(check_username));
$$;

grant execute on function public.is_username_taken(text) to anon, authenticated;

-- Generates a short human-readable unique ID like JD-7F3K2.
create or replace function public.generate_player_tag()
returns text language plpgsql set search_path = public as $$
declare
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- no 0/O/1/I to avoid confusion
  tag text;
  already_taken boolean;
begin
  loop
    tag := 'JD-';
    for i in 1..5 loop
      tag := tag || substr(chars, floor(random() * length(chars) + 1)::int, 1);
    end loop;
    select exists(select 1 from public.players where player_tag = tag) into already_taken;
    exit when not already_taken;
  end loop;
  return tag;
end;
$$;

-- Fires when Supabase Auth creates a new user (i.e. right after signup).
-- The username comes from signUp's options.data.username (jd-arena.html
-- always sends this); the fallback only kicks in for accounts created some
-- other way, e.g. directly in the Supabase dashboard.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.players (id, player_tag, username, email)
  values (
    new.id,
    public.generate_player_tag(),
    coalesce(nullif(new.raw_user_meta_data->>'username', ''), 'player_' || substr(new.id::text, 1, 8)),
    new.email
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Trigger function only, never meant to be called directly via PostgREST RPC (it would
-- error anyway outside trigger context, but tighten it explicitly).
revoke execute on function public.handle_new_user() from public, anon, authenticated;

-- ── registrations ───────────────────────────────────────────────────────
-- Links a player to a tournament. tournament_slug is just the tournament's
-- "name" field from tournaments.json (names are unique in that file).
create table public.registrations (
  id uuid primary key default gen_random_uuid(),
  tournament_slug text not null,
  player_id uuid not null references public.players(id) on delete cascade,
  squad_name text,
  squad_logo text, -- optional, player-uploaded: small base64 data URI (client resizes to ~128px before insert)
  status text not null default 'confirmed', -- 'confirmed' (free tournaments, instant) | 'pending'/'approved'/'rejected' (paid, admin-verified) | 'waitlisted' (free tournament was full at signup — see promote_from_waitlist() below; paid tournaments don't waitlist yet) | 'no_show' (missed the check-in cutoff — see check_in_for_tournament() and tournament-reminders' forfeit sweep)
  payment_screenshot text, -- paid tournaments only: base64 data URI, client resizes before insert
  checked_in_at timestamptz, -- set by check_in_for_tournament() when the player checks in during the pre-match window; never set means they get forfeited by the sweep
  created_at timestamptz not null default now(),
  unique (tournament_slug, player_id),
  constraint registrations_status_check check (status in ('pending','confirmed','approved','rejected','waitlisted','no_show'))
);

alter table public.registrations enable row level security;

-- Deliberately no UPDATE policy for players: the only way a row's status ever
-- becomes 'approved'/'rejected' is the approve-registration Edge Function,
-- which uses the service-role key. A player's own insert can set 'pending' or
-- 'confirmed' honestly (enforced by the jd-arena.html UI, not by RLS — this
-- matches the site's existing soft-trust model elsewhere), but once inserted
-- they can never self-approve since there's nothing here that lets them UPDATE.
--
-- No direct INSERT policy here on purpose — see register_for_tournament()
-- below. A plain "auth.uid() = player_id" insert policy can't enforce the
-- slot cap (nothing stops a duplicate concurrent request, or a raw REST call
-- that skips the client's slot check entirely), so registration inserts only
-- happen through that SECURITY DEFINER function, which checks capacity and
-- inserts inside one advisory-locked transaction.

create policy "players read own registration" on public.registrations
  for select using (auth.uid() = player_id);

create policy "players delete own registration" on public.registrations
  for delete using (auth.uid() = player_id);

-- Public-safe read of the registration roster: only the fields meant to be
-- shown publicly (squad name/logo, which tournament, when), never player_id
-- or payment_screenshot, and only rows that actually count as registered
-- (confirmed/approved — never pending/rejected). SECURITY DEFINER so it can
-- read across all players' rows despite RLS above restricting registrations
-- to "own row only" — safe here because the function's own SELECT list is
-- the access control: it can only ever return these four public-safe
-- columns. Called from jd-arena.html's loadPublicRoster() so the card
-- rosters, slot counts, and hero "Squads Registered" stat are all real
-- instead of hand-typed into tournaments.json.
create or replace function public.get_public_roster()
returns table(tournament_slug text, squad_name text, squad_logo text, registered_at timestamptz)
language sql
security definer
set search_path = public
stable
as $$
  select tournament_slug, squad_name, squad_logo, created_at
  from public.registrations
  where status in ('confirmed', 'approved')
  order by created_at asc;
$$;

grant execute on function public.get_public_roster() to anon, authenticated;

-- ── tournament capacity ─────────────────────────────────────────────────
-- Mirrors each tournament's "slots" field from tournaments.json so the
-- database — not just the jd-arena.html UI — knows the cap. Kept in sync by
-- the publish-tournaments Edge Function every time the admin publishes (see
-- that function's source); a tournament with no row here has no enforced
-- cap, same as slots being unset/0 in tournaments.json today. Never granted
-- to anon/authenticated — only the service-role Edge Function writes it, and
-- only register_for_tournament() below reads it.
create table public.tournament_capacity (
  tournament_slug text primary key,
  slots integer not null check (slots >= 0),
  updated_at timestamptz not null default now()
);

alter table public.tournament_capacity enable row level security;

-- Sole path for creating a registration. Replaces a plain "insert own row"
-- RLS policy so the slot cap can't be raced (concurrent requests for the same
-- tournament serialize on the advisory lock before either one counts/inserts)
-- or bypassed via a raw REST insert (there's no INSERT policy on
-- registrations at all — this SECURITY DEFINER function is the only door).
-- Updated below (see "device declaration + platform enforcement, reports, bans"
-- section near the end of this file) to add p_device_type, ban enforcement, and
-- mobile-only/emulator-only bracket enforcement. Left as CREATE OR REPLACE there
-- since it's the same function — kept in one place chronologically rather than
-- duplicated, so this comment marks where its original form used to be documented.

-- Fires whenever a registration's row changes or disappears (a player self-deleting
-- their own row, or approve-registration rejecting/changing one) — recomputes the real
-- confirmed+approved count and, if that opened a slot, promotes the oldest 'waitlisted'
-- row for that tournament straight to 'confirmed'. Free-tournament-only by construction
-- (see register_for_tournament()'s comments): every promotion increments the very count
-- this trigger just checked, so a re-fired trigger (this IS an update on registrations)
-- naturally finds no more room and stops — no recursion guard needed, unlike a
-- promote-to-'pending' path would require.
create or replace function public.promote_from_waitlist()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tournament text := coalesce(new.tournament_slug, old.tournament_slug);
  v_slots int;
  v_count int;
  v_next public.registrations;
begin
  select slots into v_slots from public.tournament_capacity where tournament_slug = v_tournament;
  if v_slots is null then
    return coalesce(new, old); -- no cap on this tournament, nothing to promote into
  end if;

  select count(*) into v_count from public.registrations
    where tournament_slug = v_tournament and status in ('confirmed', 'approved');
  if v_count >= v_slots then
    return coalesce(new, old); -- still full
  end if;

  select * into v_next from public.registrations
    where tournament_slug = v_tournament and status = 'waitlisted'
    order by created_at asc
    limit 1;
  if not found then
    return coalesce(new, old); -- nobody waiting
  end if;

  update public.registrations set status = 'confirmed' where id = v_next.id;

  insert into public.notifications (player_id, tournament_slug, title, body)
  values (
    v_next.player_id, v_tournament,
    '🎟 Off the waitlist: ' || v_tournament,
    'A slot opened up — you''re confirmed! Check the tournament card for your ticket.'
  );

  return coalesce(new, old);
end;
$$;

create trigger trg_promote_from_waitlist
  after update or delete on public.registrations
  for each row execute function public.promote_from_waitlist();

-- ── match check-in / no-show forfeit ────────────────────────────────────
-- Self-service check-in: sets checked_in_at on the caller's own confirmed/approved
-- registration for a tournament. auth.uid()-scoped so a player can only check
-- themselves in, never anyone else. Idempotent (coalesce) — tapping the button
-- twice, or a retried request, shouldn't error or move the timestamp.
create or replace function public.check_in_for_tournament(p_tournament_slug text)
returns public.registrations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.registrations;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;

  update public.registrations
    set checked_in_at = coalesce(checked_in_at, now())
    where tournament_slug = p_tournament_slug
      and player_id = auth.uid()
      and status in ('confirmed', 'approved')
    returning * into v_row;

  if not found then
    raise exception 'No confirmed registration found for this tournament';
  end if;

  return v_row;
end;
$$;

grant execute on function public.check_in_for_tournament(text) to authenticated;

-- Once-per-tournament marker for tournament-reminders' forfeit sweep. Without
-- this, a sweep re-run on every 15-min cron tick would strip-mine the
-- waitlist: forfeiting a no-show promotes a waitlisted player into 'confirmed'
-- with checked_in_at still null, and the check-in window has already closed
-- for them — the very next tick would see that same "confirmed, no check-in,
-- past cutoff" state and forfeit THEM too, cascading through the whole
-- waitlist one casualty per tick. Inserting into this table (ON CONFLICT DO
-- NOTHING, checked via the insert erroring rather than an explicit query)
-- makes the sweep fire exactly once per tournament. Never granted to
-- anon/authenticated — only the service-role Edge Function touches it.
create table public.tournament_checkin_sweeps (
  tournament_slug text primary key,
  swept_at timestamptz not null default now()
);

alter table public.tournament_checkin_sweeps enable row level security;

-- ── notifications ────────────────────────────────────────────────────────
-- Room IDs/passwords (and anything else) delivered privately to one player.
-- Written by the send-room-code Edge Function using the service_role key,
-- which bypasses RLS — players can only ever read their OWN rows.
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  tournament_slug text,
  title text not null,
  body text,
  room_id text,
  room_pass text,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

alter table public.notifications enable row level security;

create policy "players read own notifications" on public.notifications
  for select using (auth.uid() = player_id);

create policy "players mark own notifications read" on public.notifications
  for update using (auth.uid() = player_id);

-- ── Discord account linking ─────────────────────────────────────────────
-- Lets a player link their Discord account so the bot/send-room-code /
-- publish-results Edge Functions can DM them directly (see zulu_discord.py's
-- !link command). Nullable/unique: most players won't link, and a Discord
-- account can only ever point at one JD Arena player.
alter table public.players add column discord_user_id text unique;
alter table public.players add column discord_username text;

-- One-time codes proving "I'm logged into this JD Arena account right now" —
-- the bot has no other way to know which player a Discord user is. RLS on
-- with NO policies: reachable only through the two SECURITY DEFINER functions
-- below, never a direct select/insert from the browser or the bot.
create table public.discord_link_codes (
  code text primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  expires_at timestamptz not null
);

alter table public.discord_link_codes enable row level security;

-- Called from jd-arena.html while the player is signed in. 128-bit random code
-- (not generate_player_tag()'s ~28M-combination format — that's fine for a
-- permanent memorable ID, too small for something an anon RPC will accept
-- below) , 10-minute expiry, single caller's old codes cleared first so only
-- the newest one is ever valid.
create or replace function public.create_discord_link_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  delete from public.discord_link_codes where player_id = auth.uid();
  v_code := encode(extensions.gen_random_bytes(16), 'hex');
  insert into public.discord_link_codes (code, player_id, expires_at)
  values (v_code, auth.uid(), now() + interval '10 minutes');
  return v_code;
end;
$$;

grant execute on function public.create_discord_link_code() to authenticated;

-- Called by the bot (anon key only — a Discord user has no Supabase session).
-- The code being unguessable (128-bit), single-use, and short-lived IS the
-- security here, same soft-trust posture the rest of this schema already
-- accepts elsewhere. Direction stays safe regardless: a code can only ever be
-- minted by someone already logged into the account it links, so this can
-- link Discord to your OWN account faster than intended at worst — it can
-- never let anyone attach themselves to someone else's account.
create or replace function public.link_discord_account(p_code text, p_discord_user_id text, p_discord_username text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid;
begin
  select player_id into v_player_id from public.discord_link_codes
    where code = p_code and expires_at > now();
  if v_player_id is null then
    raise exception 'That code is invalid or has expired — generate a new one on the site.';
  end if;
  delete from public.discord_link_codes where code = p_code;
  update public.players set discord_user_id = p_discord_user_id, discord_username = p_discord_username
    where id = v_player_id;
end;
$$;

grant execute on function public.link_discord_account(text, text, text) to anon, authenticated;

-- Called from jd-arena.html's own account panel to undo a link.
create or replace function public.unlink_discord_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  update public.players set discord_user_id = null, discord_username = null where id = auth.uid();
end;
$$;

grant execute on function public.unlink_discord_account() to authenticated;

-- ── career stats: archived match results ────────────────────────────────
-- Permanent per-squad, per-tournament final result, written once by the admin
-- via the archive-results Edge Function. This is deliberately separate from
-- tournaments.json's `bo3` field, which only ever holds whichever ONE bracket
-- is currently on display and gets overwritten the next time the admin picks
-- a different tournament to show on the live board — there was previously no
-- permanent history at all. Player career stats/rank are computed from this
-- table, joined against registrations to know which player(s) get credit for
-- a given squad_name's result (see get_player_career_stats() below).
create table public.tournament_results (
  id uuid primary key default gen_random_uuid(),
  tournament_slug text not null,
  squad_name text not null,
  placement int not null,
  kills int not null default 0,
  points int not null default 0,
  prize_won numeric not null default 0, -- admin-entered NPR amount, optional -- 0 if none/unknown
  archived_at timestamptz not null default now(),
  unique (tournament_slug, squad_name)
);

alter table public.tournament_results enable row level security;

-- Public read: these are the same standings already shown on the public
-- leaderboard/results board, just the permanent copy -- nothing sensitive here
-- (no player_id, no payment info), so a plain read-all policy is enough.
create policy "anyone can read tournament results" on public.tournament_results
  for select using (true);

-- No insert/update/delete policy on purpose -- only the service-role
-- archive-results Edge Function writes here, same posture as
-- tournament_capacity.

-- Aggregates one player's career numbers across every tournament_results row
-- their registrations are credited for. "Credited" follows the site's
-- squad-shares-stats model: every player who registered under a given
-- squad_name for a tournament gets that squad's full kills/points/placement
-- for that event (not divided among teammates) -- Free Fire scoring here is
-- tracked per-squad, not per-individual-member, so this is the only way to
-- attribute "individual performance" without a much heavier admin workflow.
-- SECURITY DEFINER + anon/authenticated grant: profiles are meant to be
-- publicly viewable (shareable, like the rest of the site's public roster),
-- and nothing this returns is sensitive.
create or replace function public.get_player_career_stats(p_player_tag text)
returns table(
  player_tag text,
  username text,
  tournaments_played int,
  total_kills bigint,
  total_points bigint,
  booyahs int,
  avg_placement numeric,
  total_prize numeric
)
language sql
security definer
set search_path = public
stable
as $$
  select
    p.player_tag,
    p.username,
    count(distinct tr.tournament_slug)::int,
    coalesce(sum(tr.kills),0)::bigint,
    coalesce(sum(tr.points),0)::bigint,
    coalesce(sum(case when tr.placement = 1 then 1 else 0 end),0)::int,
    coalesce(round(avg(tr.placement),1),0),
    coalesce(sum(tr.prize_won),0)
  from public.players p
  left join public.registrations r on r.player_id = p.id and r.status in ('confirmed','approved')
  left join public.tournament_results tr on tr.tournament_slug = r.tournament_slug and tr.squad_name = r.squad_name
  where lower(p.player_tag) = lower(p_player_tag)
  group by p.player_tag, p.username;
$$;

grant execute on function public.get_player_career_stats(text) to anon, authenticated;

-- ── player-verified reviews ──────────────────────────────────────────────
-- Trust feature: only a player who was actually confirmed/approved for a
-- tournament can review it (enforced in submit_tournament_review() below,
-- not a plain insert policy -- same reasoning as register_for_tournament()),
-- and reviews are public so visitors can see real feedback, not just what
-- the organizer chooses to publish.
create table public.tournament_reviews (
  id uuid primary key default gen_random_uuid(),
  tournament_slug text not null,
  player_id uuid not null references public.players(id) on delete cascade,
  rating int not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now(),
  unique (tournament_slug, player_id)
);

alter table public.tournament_reviews enable row level security;

-- Public read -- this is the whole point of a trust feature: visible to
-- everyone, not gated behind an account.
create policy "anyone can read reviews" on public.tournament_reviews
  for select using (true);

-- A player can remove their own review (e.g. they want to revise it -- see
-- the upsert in submit_tournament_review() below, which also allows editing
-- without deleting first).
create policy "players delete own review" on public.tournament_reviews
  for delete using (auth.uid() = player_id);

-- Sole path for creating/editing a review -- verifies the caller was actually
-- confirmed/approved for the tournament before letting them post, which a
-- plain "auth.uid() = player_id" insert policy could not enforce.
create or replace function public.submit_tournament_review(p_tournament_slug text, p_rating int, p_comment text)
returns public.tournament_reviews
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ok boolean;
  v_row public.tournament_reviews;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  if p_rating < 1 or p_rating > 5 then
    raise exception 'Rating must be between 1 and 5';
  end if;
  select exists(
    select 1 from public.registrations
    where tournament_slug = p_tournament_slug and player_id = auth.uid() and status in ('confirmed','approved')
  ) into v_ok;
  if not v_ok then
    raise exception 'You can only review a tournament you were registered for';
  end if;

  insert into public.tournament_reviews (tournament_slug, player_id, rating, comment)
  values (p_tournament_slug, auth.uid(), p_rating, nullif(trim(p_comment), ''))
  on conflict (tournament_slug, player_id) do update
    set rating = excluded.rating, comment = excluded.comment, created_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.submit_tournament_review(text, int, text) to authenticated;

-- Public-safe read: username + rating + comment, never player_id. Used for
-- the review list shown on a completed tournament's card.
create or replace function public.get_tournament_reviews(p_tournament_slug text)
returns table(username text, rating int, comment text, created_at timestamptz)
language sql
security definer
set search_path = public
stable
as $$
  select p.username, r.rating, r.comment, r.created_at
  from public.tournament_reviews r
  join public.players p on p.id = r.player_id
  where r.tournament_slug = p_tournament_slug
  order by r.created_at desc;
$$;

grant execute on function public.get_tournament_reviews(text) to anon, authenticated;

-- ── device declaration + platform enforcement ────────────────────────────
-- Each squad self-declares mobile vs emulator at registration; each tournament
-- gets a platform_mode admin control synced from tournaments.json (see
-- publish-tournaments Edge Function) so a mobile-only bracket can actually
-- reject an emulator squad server-side, not just by convention/trust.
alter table public.registrations add column if not exists device_type text
  check (device_type in ('mobile','emulator'));

alter table public.tournament_capacity alter column slots drop not null;
alter table public.tournament_capacity add column if not exists platform_mode text not null default 'mixed'
  check (platform_mode in ('mobile','emulator','mixed'));

-- ── player-verified reports (private) + public ban list ─────────────────
-- Reports are NOT public (could name someone falsely before review) -- only
-- the resulting ban, once an admin actually actions one, becomes public.
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  tournament_slug text,
  reporter_player_id uuid not null references public.players(id) on delete cascade,
  reported text not null, -- squad name or player tag/username as typed by the reporter -- admin resolves to a real account when actioning
  evidence_url text,      -- link only (Google Drive/Discord CDN/YouTube clip etc.) -- no file upload infra
  description text not null,
  status text not null default 'pending' check (status in ('pending','actioned','dismissed')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolution_note text
);

alter table public.reports enable row level security;

create policy "players read own reports" on public.reports
  for select using (auth.uid() = reporter_player_id);

-- Sole path for filing a report -- keeps required fields enforced server-side
-- rather than trusting the client.
create or replace function public.submit_report(p_tournament_slug text, p_reported text, p_evidence_url text, p_description text)
returns public.reports
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.reports;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;
  if coalesce(trim(p_reported), '') = '' then
    raise exception 'Who are you reporting?';
  end if;
  if coalesce(trim(p_description), '') = '' then
    raise exception 'Please describe what happened';
  end if;
  insert into public.reports (tournament_slug, reporter_player_id, reported, evidence_url, description)
  values (nullif(trim(p_tournament_slug), ''), auth.uid(), trim(p_reported), nullif(trim(p_evidence_url), ''), trim(p_description))
  returning * into v_row;
  return v_row;
end;
$$;

grant execute on function public.submit_report(text, text, text, text) to authenticated;

-- The public ban list itself -- no direct SELECT policy (RLS default-deny), reachable
-- only through get_public_ban_list() below so player_id is never exposed, matching
-- get_public_roster()'s posture rather than a blanket "anyone can read" table policy.
create table public.banned_players (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null unique references public.players(id) on delete cascade,
  reason text not null,
  banned_at timestamptz not null default now(),
  report_id uuid references public.reports(id) on delete set null
);

alter table public.banned_players enable row level security;
-- No insert/update/delete/select policy on purpose -- only service-role Edge Functions
-- (action-report, unban-player) and the public RPC below touch this table.

create or replace function public.get_public_ban_list()
returns table(player_tag text, username text, reason text, banned_at timestamptz)
language sql
security definer
set search_path = public
stable
as $$
  select p.player_tag, p.username, b.reason, b.banned_at
  from public.banned_players b
  join public.players p on p.id = b.player_id
  order by b.banned_at desc;
$$;

grant execute on function public.get_public_ban_list() to anon, authenticated;

-- ── register_for_tournament(): add device_type + enforce platform_mode + bans ──
-- New parameter changes the function's signature, so CREATE OR REPLACE alone
-- would leave the old 5-arg version behind as dead code -- drop it explicitly first.
drop function if exists public.register_for_tournament(text, text, text, text, text);

create or replace function public.register_for_tournament(
  p_tournament_slug text,
  p_squad_name text,
  p_squad_logo text,
  p_status text,
  p_payment_screenshot text,
  p_device_type text
)
returns public.registrations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_slots int;
  v_count int;
  v_already_registered boolean;
  v_effective_status text := p_status;
  v_platform_mode text;
  v_row public.registrations;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;

  if exists(select 1 from public.banned_players where player_id = auth.uid()) then
    raise exception 'Your account is banned from registering for tournaments.';
  end if;

  if p_device_type not in ('mobile','emulator') then
    raise exception 'Pick a device type: mobile or emulator.';
  end if;

  select platform_mode into v_platform_mode from public.tournament_capacity where tournament_slug = p_tournament_slug;
  v_platform_mode := coalesce(v_platform_mode, 'mixed');
  if v_platform_mode <> 'mixed' and v_platform_mode <> p_device_type then
    raise exception 'This tournament is % only -- you declared %.', v_platform_mode, p_device_type;
  end if;

  -- Serializes concurrent joins for THIS tournament only; released when the
  -- transaction ends. This — not the count check below — is what actually
  -- closes the race: two simultaneous callers can't both read "still room"
  -- and both insert, because the second one blocks here until the first
  -- commits (or rolls back on duplicate/full).
  perform pg_advisory_xact_lock(hashtext(p_tournament_slug));

  -- Checked ahead of capacity so a player re-submitting their own already-taken
  -- slot gets "you're already registered" (via the unique-constraint violation
  -- below), not a confusing "tournament full" — they occupy one of those slots
  -- themselves, so the capacity check would otherwise misfire for them right
  -- when a tournament is exactly full.
  select exists(
    select 1 from public.registrations
    where tournament_slug = p_tournament_slug and player_id = auth.uid()
  ) into v_already_registered;

  if not v_already_registered then
    select slots into v_slots from public.tournament_capacity where tournament_slug = p_tournament_slug;
    if v_slots is not null then
      select count(*) into v_count from public.registrations
        where tournament_slug = p_tournament_slug and status in ('confirmed', 'approved');
      if v_count >= v_slots then
        -- Free tournaments (p_status='confirmed') waitlist instead of being turned away —
        -- promote_from_waitlist() below promotes the oldest one the moment a slot frees up.
        -- Paid tournaments (p_status='pending') still hard-reject when full: a waitlisted
        -- paid entry can't be promoted straight to 'confirmed' the way free ones can (it still
        -- needs payment verification), and that asymmetry is exactly what would make the
        -- promotion trigger's single-promotion-per-freed-slot guarantee break down. Not solved
        -- here on purpose — see schema.sql's notes on promote_from_waitlist().
        if p_status = 'confirmed' then
          v_effective_status := 'waitlisted';
        else
          raise exception 'Tournament full';
        end if;
      end if;
    end if;
  end if;

  insert into public.registrations (tournament_slug, player_id, squad_name, squad_logo, status, payment_screenshot, device_type)
  values (p_tournament_slug, auth.uid(), p_squad_name, p_squad_logo, v_effective_status, p_payment_screenshot, p_device_type)
  returning * into v_row;

  -- Drops the same ticket shown in the registration-success modal into Notification
  -- History too, so it's not a one-time popup — jd-arena.html's loadNotifications()
  -- recognizes the "TICKET::" body prefix and renders it as a styled ticket card
  -- (looking up prize/entry/platform from tournaments.json by tournament_slug) instead
  -- of plain text. Ticket format matches regTicketCode() in jd-arena.html exactly —
  -- same registration id, same 8-char slice — so it's never a different code than
  -- what the player already saw. Uses v_effective_status (what actually got stored),
  -- not p_status (what was asked for) — otherwise a waitlisted player's ticket would
  -- falsely claim they're registered.
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (
    auth.uid(),
    p_tournament_slug,
    '🎫 Registered: ' || p_tournament_slug,
    'TICKET::' || ('JD-' || upper(substr(replace(v_row.id::text, '-', ''), 1, 8))) || '::' || v_effective_status
  );

  return v_row;
end;
$$;

grant execute on function public.register_for_tournament(text, text, text, text, text, text) to authenticated;

-- ── anomaly detection (cheating signal, not auto-enforcement) ────────────
-- Flagged automatically when archive-results (Edge Function) spots a squad's kills
-- spiking well past their own historical average -- never bans/blocks anything by
-- itself, purely a "look at this" signal for admin review. Admin-only, no public
-- or player read at all.
create table public.performance_flags (
  id uuid primary key default gen_random_uuid(),
  tournament_slug text not null,
  squad_name text not null,
  kills int not null,
  historical_avg_kills numeric not null,
  prior_appearances int not null,
  ratio numeric not null,
  reviewed boolean not null default false,
  admin_note text,
  created_at timestamptz not null default now()
);

alter table public.performance_flags enable row level security;
-- No policies on purpose -- only the service-role archive-results (writes) and
-- list-performance-flags/review-flag (admin Edge Functions) touch this table.

-- ── season kill leaders (ZULU: "who's the kill leader this season?") ────
-- Same squad-shares-stats join as get_player_career_stats(), grouped/ranked
-- instead of per-player.
create or replace function public.get_season_kill_leaders(p_limit int default 5)
returns table(player_tag text, username text, total_kills bigint)
language sql
security definer
set search_path = public
stable
as $$
  select p.player_tag, p.username, coalesce(sum(tr.kills), 0)::bigint as total_kills
  from public.players p
  join public.registrations r on r.player_id = p.id and r.status in ('confirmed','approved')
  join public.tournament_results tr on tr.tournament_slug = r.tournament_slug and tr.squad_name = r.squad_name
  group by p.player_tag, p.username
  having coalesce(sum(tr.kills), 0) > 0
  order by total_kills desc
  limit greatest(1, least(p_limit, 25));
$$;

grant execute on function public.get_season_kill_leaders(int) to anon, authenticated;

-- ── performance prediction ────────────────────────────────────────────────
-- Returns each squad currently registered for a tournament, with their season
-- average points/kills/appearances from tournament_results. The win-probability
-- math (softmax over avg_points) is computed client-side in index.html's
-- renderPredictBoard() -- easier to tune the "confidence" constant without a
-- migration each time.
create or replace function public.get_tournament_squad_history(p_tournament_slug text)
returns table(squad_name text, avg_points numeric, avg_kills numeric, appearances int)
language sql
security definer
set search_path = public
stable
as $$
  with squads as (
    select distinct squad_name from public.registrations
    where tournament_slug = p_tournament_slug and status in ('confirmed','approved') and squad_name is not null
  )
  select s.squad_name,
    coalesce(avg(tr.points), 0)::numeric as avg_points,
    coalesce(avg(tr.kills), 0)::numeric as avg_kills,
    coalesce(count(tr.tournament_slug), 0)::int as appearances
  from squads s
  left join public.registrations r on r.squad_name = s.squad_name and r.status in ('confirmed','approved')
  left join public.tournament_results tr on tr.tournament_slug = r.tournament_slug and tr.squad_name = r.squad_name
  group by s.squad_name;
$$;

grant execute on function public.get_tournament_squad_history(text) to anon, authenticated;

-- ── AI recommendations (advisory only, never auto-enforcement) ───────────
-- Written by zulu_server.py's /admin/ai-review (via the submit-ai-recommendation Edge
-- Function) after running council_vote() -- multiple AI model families judging a pending
-- item independently, majority tallied. This table NEVER causes anything to happen by
-- itself: an admin still has to click Confirm in the admin panel, which calls the exact
-- same action functions (approve-registration, action-report, review-flag, or the
-- publish-tournaments flow for cancellations) the admin already uses today. Same
-- philosophy as performance_flags above -- signal for a human, not enforcement.
create table public.ai_recommendations (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('cancel_tournament', 'approve_payment', 'resolve_report', 'review_flag')),
  target_id uuid,          -- registrations.id / reports.id / performance_flags.id, when applicable
  target_slug text,        -- tournament slug, when applicable (cancel_tournament has no target_id)
  recommended_action text not null,
  agreement text not null, -- e.g. "3/4 families" -- distinct MODEL FAMILIES, not raw provider count
  family_votes jsonb not null default '{}'::jsonb, -- {family: {verdict, reason}} -- the audit trail
  context_snapshot jsonb not null default '{}'::jsonb, -- the numbers this was generated from, for the
                                                          -- confirm-time staleness check in the admin panel
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'overridden', 'dismissed', 'stale')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

alter table public.ai_recommendations enable row level security;
-- No policies on purpose -- only the service-role submit-ai-recommendation (writes, from
-- zulu_server.py) and list-ai-recommendations (admin panel reads) Edge Functions touch this.

-- ── Staged room codes (auto-release, advisory staging only) ──────────────
-- Staged room codes for tournament-reminders to auto-release ~5 minutes before
-- start, so the admin only has to type the code once instead of timing a
-- second manual "Send Room Code" click. sent_at is the dedup marker (same
-- pattern as tournament_checkin_sweeps): the update-with-filter-then-check-
-- rowcount in tournament-reminders means only the tick that actually flips
-- sent_at from null proceeds, so a race between ticks can't double-send.
create table public.tournament_room_codes (
  tournament_slug text primary key,
  room_id text not null,
  room_pass text,
  staged_at timestamptz not null default now(),
  sent_at timestamptz
);

alter table public.tournament_room_codes enable row level security;
-- No policies on purpose -- only service-role Edge Functions touch this
-- (stage-room-code writes/reads it, send-room-code marks it sent on a manual
-- send, tournament-reminders reads+claims it for auto-release).

-- ── AI reply rate limiting (protects the shared free Gemini quota) ───────
-- zulu-ai-reply (public, unauthenticated -- every visitor's browser can call it) shares a
-- small daily Gemini quota with generate-match-recap and zulu_server.py's own council
-- calls. Its own code comment already flagged this as unprotected; logging every call here
-- lets the Edge Function enforce both a per-IP burst cap (stop one client hammering it) and
-- a global daily cap (stop the shared quota being exhausted by public chat traffic alone).
create table public.zulu_ai_reply_log (
  id bigint generated by default as identity primary key,
  ip text,
  created_at timestamptz not null default now()
);

create index zulu_ai_reply_log_created_at_idx on public.zulu_ai_reply_log (created_at);
create index zulu_ai_reply_log_ip_created_at_idx on public.zulu_ai_reply_log (ip, created_at);

alter table public.zulu_ai_reply_log enable row level security;
-- No policies on purpose -- only the service-role zulu-ai-reply Edge Function touches this.

-- ── live site content + permanent team verification ─────────────────────
-- site_content: publish-tournaments writes the same tournaments.json it commits to
-- GitHub here too, so the site sees admin changes within one 5s poll instead of
-- waiting for GitHub Pages to rebuild and its CDN cache (up to ~10 min) to expire.
-- Public read only; writes happen exclusively via the service role in that function.
create table if not exists public.site_content (
  key text primary key,
  content jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.site_content enable row level security;
drop policy if exists "public read site content" on public.site_content;
create policy "public read site content" on public.site_content
  for select using (true);

-- verified_at: set by the admin-verify-registration Edge Function when the organiser
-- has checked a squad's ticket code with them. Permanent (DB, not one browser), and
-- players can see it on their own ticket via the existing "read own registration" policy.
alter table public.registrations add column if not exists verified_at timestamptz;

-- ── paid squad effects (Rs 2 per tournament) ────────────────────────────
-- A confirmed squad can buy one cosmetic effect (gold/fire/ice/neon/rainbow)
-- for one tournament: the player uploads an eSewa payment screenshot through
-- request_squad_effect(), the organiser approves it in the admin panel
-- (effect-purchases Edge Function, service role), and only then is
-- registrations.effect set. Players still have no UPDATE policy on
-- registrations, so nobody can give themselves an effect without paying.
-- Idempotent: safe to run more than once.
begin;

alter table public.registrations add column if not exists effect text;
alter table public.registrations drop constraint if exists registrations_effect_check;
alter table public.registrations add constraint registrations_effect_check
  check (effect is null or effect in ('gold','fire','ice','neon','rainbow'));

create table if not exists public.effect_purchases (
  id uuid primary key default gen_random_uuid(),
  -- set null (not cascade) so the payment record survives a squad withdrawing
  registration_id uuid references public.registrations(id) on delete set null,
  player_id uuid not null references public.players(id) on delete cascade,
  tournament_slug text not null,
  squad_name text,
  effect text not null check (effect in ('gold','fire','ice','neon','rainbow')),
  amount_npr integer not null default 2,
  payment_screenshot text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create unique index if not exists effect_purchases_one_pending
  on public.effect_purchases(registration_id) where status = 'pending';
alter table public.effect_purchases enable row level security;
drop policy if exists "players read own effect purchases" on public.effect_purchases;
create policy "players read own effect purchases" on public.effect_purchases
  for select using (auth.uid() = player_id);
-- No insert/update policies: inserts only via request_squad_effect(), reviews only via
-- the service-role effect-purchases Edge Function.

create or replace function public.request_squad_effect(
  p_tournament_slug text,
  p_effect text,
  p_payment_screenshot text
)
returns public.effect_purchases
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reg public.registrations;
  v_row public.effect_purchases;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  if p_effect not in ('gold','fire','ice','neon','rainbow') then
    raise exception 'Unknown effect.';
  end if;
  if p_payment_screenshot is null or p_payment_screenshot not like 'data:image/%' then
    raise exception 'Please attach your payment screenshot.';
  end if;
  if length(p_payment_screenshot) > 600000 then
    raise exception 'The screenshot is too large. Please upload a smaller image.';
  end if;

  select * into v_reg from public.registrations
    where tournament_slug = p_tournament_slug and player_id = auth.uid()
      and status in ('confirmed','approved');
  if v_reg.id is null then
    raise exception 'Only confirmed squads can add an effect.';
  end if;
  if exists(select 1 from public.effect_purchases where registration_id = v_reg.id and status = 'pending') then
    raise exception 'You already have an effect request waiting for approval.';
  end if;

  insert into public.effect_purchases (registration_id, player_id, tournament_slug, squad_name, effect, payment_screenshot)
  values (v_reg.id, auth.uid(), p_tournament_slug, v_reg.squad_name, p_effect, p_payment_screenshot)
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function public.request_squad_effect(text, text, text) from public, anon;
grant execute on function public.request_squad_effect(text, text, text) to authenticated;

-- get_public_roster() now also returns each squad's approved effect. The return type
-- changes, so it has to be dropped and recreated (create or replace can't do that).
drop function if exists public.get_public_roster();
create function public.get_public_roster()
returns table(tournament_slug text, squad_name text, squad_logo text, registered_at timestamptz, effect text)
language sql
security definer
set search_path = public
stable
as $$
  select tournament_slug, squad_name, squad_logo, created_at, effect
  from public.registrations
  where status in ('confirmed', 'approved')
  order by created_at asc;
$$;
grant execute on function public.get_public_roster() to anon, authenticated;

commit;

-- ── payment codes + effect passes ───────────────────────────────────────
-- Replaces the screenshot-upload effect flow (effect_purchases / request_squad_effect,
-- never used) with one code system for everything that costs money:
--   entry         — paid tournament entry, bound to ONE tournament when generated
--   fx_game       — Rs 2: a standard effect for one tournament
--   fx_lite_week  — Rs 5: basic effects, 7 days, every tournament
--   fx_week       — Rs 10: every effect incl. premium, 7 days
--   fx_month      — Rs 30: every effect incl. premium, 30 days
-- The player pays over WhatsApp, the organiser generates a code in the admin panel
-- (payment-codes Edge Function, service role) and sends it back; the player redeems it
-- with redeem_code(). Players can't read this table at all — only the RPC touches it.
-- Idempotent: safe to run more than once.
begin;

drop function if exists public.request_squad_effect(text, text, text);
drop table if exists public.effect_purchases;

alter table public.registrations drop constraint if exists registrations_effect_check;
alter table public.registrations add constraint registrations_effect_check
  check (effect is null or effect in ('glow','steel','gold','fire','ice','neon','rainbow','galaxy','thunder','legend'));

-- which effects each plan unlocks; the site's picker mirrors this, but this is the rule
create or replace function public.fx_tier_ok(p_tier text, p_effect text)
returns boolean language sql immutable as $$
  select case p_tier
    when 'lite' then p_effect in ('glow','steel')
    when 'game' then p_effect in ('gold','fire','ice','neon','rainbow')
    when 'pro'  then p_effect in ('glow','steel','gold','fire','ice','neon','rainbow','galaxy','thunder','legend')
    else false end;
$$;

create table if not exists public.payment_codes (
  code text primary key,
  kind text not null check (kind in ('entry','fx_game','fx_lite_week','fx_week','fx_month')),
  tournament_slug text,
  amount_npr integer,
  note text,
  created_at timestamptz not null default now(),
  redeemed_by uuid references public.players(id) on delete set null,
  redeemed_at timestamptz,
  redeemed_for text,
  constraint payment_codes_entry_needs_tournament check (kind <> 'entry' or tournament_slug is not null)
);
alter table public.payment_codes enable row level security;
-- no policies on purpose

create table if not exists public.effect_passes (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  tier text not null check (tier in ('lite','pro')),
  effect text not null check (effect in ('glow','steel','gold','fire','ice','neon','rainbow','galaxy','thunder','legend')),
  starts_at timestamptz not null default now(),
  expires_at timestamptz not null,
  code text,
  created_at timestamptz not null default now()
);
create index if not exists effect_passes_player_expiry on public.effect_passes(player_id, expires_at);
alter table public.effect_passes enable row level security;
drop policy if exists "players read own passes" on public.effect_passes;
create policy "players read own passes" on public.effect_passes
  for select using (auth.uid() = player_id);

create or replace function public.redeem_code(p_code text, p_tournament_slug text default null, p_effect text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code public.payment_codes;
  v_reg public.registrations;
  v_slots int;
  v_count int;
  v_tier text;
  v_start timestamptz;
  v_pass public.effect_passes;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  p_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9-]', '', 'g'));
  if p_code = '' then
    raise exception 'Enter your code.';
  end if;

  -- Claim the code atomically. Any exception below rolls this back, so a code is only
  -- ever spent when whatever it pays for was actually applied.
  update public.payment_codes set redeemed_by = auth.uid(), redeemed_at = now()
    where code = p_code and redeemed_at is null
    returning * into v_code;
  if v_code.code is null then
    if exists(select 1 from public.payment_codes where code = p_code) then
      raise exception 'This code has already been used.';
    end if;
    raise exception 'Code not recognised. Check it and try again.';
  end if;

  if v_code.kind = 'entry' then
    if p_tournament_slug is distinct from v_code.tournament_slug then
      raise exception 'This code is for %, not this tournament.', v_code.tournament_slug;
    end if;
    -- same lock register_for_tournament() takes, so codes can't overfill a tournament
    perform pg_advisory_xact_lock(hashtext(v_code.tournament_slug));
    select * into v_reg from public.registrations
      where tournament_slug = v_code.tournament_slug and player_id = auth.uid();
    if v_reg.id is null then
      raise exception 'Register for % first, then enter your code.', v_code.tournament_slug;
    end if;
    if v_reg.status in ('confirmed','approved') then
      raise exception 'Your squad is already confirmed for this tournament.';
    end if;
    if v_reg.status = 'no_show' then
      raise exception 'This registration can no longer be confirmed.';
    end if;
    select slots into v_slots from public.tournament_capacity where tournament_slug = v_code.tournament_slug;
    if v_slots is not null then
      select count(*) into v_count from public.registrations
        where tournament_slug = v_code.tournament_slug and status in ('confirmed','approved');
      if v_count >= v_slots then
        raise exception 'All slots are full, so your code was not used. Please contact the organiser on WhatsApp.';
      end if;
    end if;
    update public.registrations set status = 'approved' where id = v_reg.id;
    update public.payment_codes set redeemed_for = v_reg.id::text where code = p_code;
    insert into public.notifications (player_id, tournament_slug, title, body)
    values (auth.uid(), v_code.tournament_slug, '✅ Entry confirmed: ' || v_code.tournament_slug,
            'Your payment code was accepted and ' || coalesce(v_reg.squad_name, 'your squad') || ' is confirmed. Room details will be sent here before the match.');
    return jsonb_build_object('kind', 'entry', 'status', 'approved');

  elsif v_code.kind = 'fx_game' then
    if not public.fx_tier_ok('game', p_effect) then
      raise exception 'Pick one of the standard effects for a single-match code.';
    end if;
    select * into v_reg from public.registrations
      where tournament_slug = p_tournament_slug and player_id = auth.uid() and status in ('confirmed','approved');
    if v_reg.id is null then
      raise exception 'Only confirmed squads can add an effect.';
    end if;
    update public.registrations set effect = p_effect where id = v_reg.id;
    update public.payment_codes set redeemed_for = v_reg.id::text where code = p_code;
    return jsonb_build_object('kind', 'fx_game', 'effect', p_effect);

  else
    v_tier := case when v_code.kind = 'fx_lite_week' then 'lite' else 'pro' end;
    if not public.fx_tier_ok(v_tier, p_effect) then
      raise exception 'That effect is not included in this pass.';
    end if;
    -- a new pass starts when the current one ends, so stacking never wastes days
    select max(expires_at) into v_start from public.effect_passes
      where player_id = auth.uid() and expires_at > now();
    v_start := greatest(coalesce(v_start, now()), now());
    insert into public.effect_passes (player_id, tier, effect, starts_at, expires_at, code)
    values (auth.uid(), v_tier, p_effect, v_start,
            v_start + make_interval(days => case when v_code.kind = 'fx_month' then 30 else 7 end), p_code)
    returning * into v_pass;
    update public.payment_codes set redeemed_for = v_pass.id::text where code = p_code;
    return jsonb_build_object('kind', v_code.kind, 'effect', p_effect, 'starts_at', v_pass.starts_at, 'expires_at', v_pass.expires_at);
  end if;
end;
$$;
revoke all on function public.redeem_code(text, text, text) from public, anon;
grant execute on function public.redeem_code(text, text, text) to authenticated;

-- switch effect during an active pass (within that pass's tier)
create or replace function public.set_pass_effect(p_effect text)
returns public.effect_passes
language plpgsql
security definer
set search_path = public
as $$
declare v_pass public.effect_passes;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  update public.effect_passes set effect = p_effect
    where player_id = auth.uid() and starts_at <= now() and expires_at > now() and public.fx_tier_ok(tier, p_effect)
    returning * into v_pass;
  if v_pass.id is null then
    raise exception 'Your current pass does not include that effect.';
  end if;
  return v_pass;
end;
$$;
revoke all on function public.set_pass_effect(text) from public, anon;
grant execute on function public.set_pass_effect(text) to authenticated;

-- roster effect: the squad's own single-match effect, otherwise the player's active pass
create or replace function public.get_public_roster()
returns table(tournament_slug text, squad_name text, squad_logo text, registered_at timestamptz, effect text)
language sql
security definer
set search_path = public
stable
as $$
  select r.tournament_slug, r.squad_name, r.squad_logo, r.created_at,
    coalesce(r.effect, (
      select ep.effect from public.effect_passes ep
      where ep.player_id = r.player_id and ep.starts_at <= now() and ep.expires_at > now()
      order by ep.expires_at asc limit 1
    ))
  from public.registrations r
  where r.status in ('confirmed', 'approved')
  order by r.created_at asc;
$$;
grant execute on function public.get_public_roster() to anon, authenticated;

commit;

-- ── combat pro effects: bullets + blade ─────────────────────────────────
begin;
alter table public.registrations drop constraint if exists registrations_effect_check;
alter table public.registrations add constraint registrations_effect_check
  check (effect is null or effect in ('glow','steel','gold','fire','ice','neon','rainbow','galaxy','thunder','legend','bullets','blade'));
alter table public.effect_passes drop constraint if exists effect_passes_effect_check;
alter table public.effect_passes add constraint effect_passes_effect_check
  check (effect in ('glow','steel','gold','fire','ice','neon','rainbow','galaxy','thunder','legend','bullets','blade'));
create or replace function public.fx_tier_ok(p_tier text, p_effect text)
returns boolean language sql immutable as $$
  select case p_tier
    when 'lite' then p_effect in ('glow','steel')
    when 'game' then p_effect in ('gold','fire','ice','neon','rainbow')
    when 'pro'  then p_effect in ('glow','steel','gold','fire','ice','neon','rainbow','galaxy','thunder','legend','bullets','blade')
    else false end;
$$;
commit;

-- ── points wallet (1 point = Rs 1) ──────────────────────────────────────
-- Players load points by paying the eSewa QR (username in the remarks, screenshot on
-- WhatsApp); the organiser verifies the payment and credits the points from the admin
-- panel (wallet-admin Edge Function -> admin_wallet_credit). Points pay for paid entries
-- and squad effects, withdrawn paid entries are refunded back as points (full, or 10%
-- within 24h of the start), and players can request a withdrawal to eSewa, which the
-- organiser pays out by hand. Balances only ever change through _wallet_apply(), which
-- players cannot call directly. Idempotent.
begin;

-- ── published tournament facts, read from the same site_content the site polls ──
create or replace function public.tournament_entry_npr(p_slug text)
returns int language sql stable security definer set search_path = public as $$
  select case
    when coalesce(trim(t->>'entry'), '') = '' or lower(trim(t->>'entry')) in ('free', '0') then 0
    else nullif(regexp_replace(t->>'entry', '[^0-9]', '', 'g'), '')::int
  end
  from public.site_content, jsonb_array_elements(content->'tournaments') t
  where key = 'tournaments' and t->>'name' = p_slug
  limit 1;
$$;

create or replace function public.tournament_start_at(p_slug text)
returns timestamptz language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  select t->>'start' into v
  from public.site_content, jsonb_array_elements(content->'tournaments') t
  where key = 'tournaments' and t->>'name' = p_slug limit 1;
  return nullif(v, '')::timestamptz;
exception when others then
  return null;
end;
$$;

-- ── paid tournaments can never self-confirm ──
-- register_for_tournament() used to trust the p_status the browser sent; anything with
-- an entry price above 0 is now forced to 'pending' (a held place) until it's paid.
create or replace function public.register_for_tournament(p_tournament_slug text, p_squad_name text, p_squad_logo text, p_status text, p_payment_screenshot text, p_device_type text)
 returns registrations
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_slots int;
  v_count int;
  v_already_registered boolean;
  v_effective_status text := p_status;
  v_platform_mode text;
  v_row public.registrations;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;

  if p_status not in ('pending','confirmed') then
    raise exception 'Invalid registration status';
  end if;

  if coalesce(public.tournament_entry_npr(p_tournament_slug), 0) > 0 then
    p_status := 'pending';
    v_effective_status := 'pending';
  end if;

  if exists(select 1 from public.banned_players where player_id = auth.uid()) then
    raise exception 'Your account is banned from registering for tournaments.';
  end if;

  if p_device_type not in ('mobile','emulator') then
    raise exception 'Pick a device type: mobile or emulator.';
  end if;

  select platform_mode into v_platform_mode from public.tournament_capacity where tournament_slug = p_tournament_slug;
  v_platform_mode := coalesce(v_platform_mode, 'mixed');
  if v_platform_mode <> 'mixed' and v_platform_mode <> p_device_type then
    raise exception 'This tournament is % only -- you declared %.', v_platform_mode, p_device_type;
  end if;

  perform pg_advisory_xact_lock(hashtext(p_tournament_slug));

  select exists(
    select 1 from public.registrations
    where tournament_slug = p_tournament_slug and player_id = auth.uid()
  ) into v_already_registered;

  if not v_already_registered then
    select slots into v_slots from public.tournament_capacity where tournament_slug = p_tournament_slug;
    if v_slots is not null then
      select count(*) into v_count from public.registrations
        where tournament_slug = p_tournament_slug and status in ('confirmed', 'approved');
      if v_count >= v_slots then
        if p_status = 'confirmed' then
          v_effective_status := 'waitlisted';
        else
          raise exception 'Tournament full';
        end if;
      end if;
    end if;
  end if;

  insert into public.registrations (tournament_slug, player_id, squad_name, squad_logo, status, payment_screenshot, device_type)
  values (p_tournament_slug, auth.uid(), p_squad_name, p_squad_logo, v_effective_status, p_payment_screenshot, p_device_type)
  returning * into v_row;

  insert into public.notifications (player_id, tournament_slug, title, body)
  values (
    auth.uid(),
    p_tournament_slug,
    '🎫 Registered: ' || p_tournament_slug,
    'TICKET::' || ('JD-' || upper(substr(replace(v_row.id::text, '-', ''), 1, 8))) || '::' || v_effective_status
  );

  return v_row;
end;
$function$;

-- ── wallet tables ──
alter table public.registrations add column if not exists paid_points int not null default 0;

create table if not exists public.wallets (
  player_id uuid primary key references public.players(id) on delete cascade,
  balance int not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);
alter table public.wallets enable row level security;
drop policy if exists "players read own wallet" on public.wallets;
create policy "players read own wallet" on public.wallets for select using (auth.uid() = player_id);

create table if not exists public.wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  delta int not null,
  balance_after int not null,
  reason text not null check (reason in ('load','entry','effect','withdraw','withdraw_returned','refund','adjust')),
  ref text,
  note text,
  created_at timestamptz not null default now()
);
-- one credit per eSewa transaction reference, so a resent screenshot can't be credited twice
create unique index if not exists wallet_ledger_load_ref on public.wallet_ledger(ref) where reason = 'load';
create index if not exists wallet_ledger_player on public.wallet_ledger(player_id, created_at desc);
alter table public.wallet_ledger enable row level security;
drop policy if exists "players read own ledger" on public.wallet_ledger;
create policy "players read own ledger" on public.wallet_ledger for select using (auth.uid() = player_id);

create table if not exists public.withdraw_requests (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  amount int not null check (amount > 0),
  esewa_id text not null,
  esewa_name text not null,
  status text not null default 'pending' check (status in ('pending','paid','rejected')),
  payout_ref text,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);
alter table public.withdraw_requests enable row level security;
drop policy if exists "players read own withdrawals" on public.withdraw_requests;
create policy "players read own withdrawals" on public.withdraw_requests for select using (auth.uid() = player_id);

-- ── the only place balances change (internal) ──
create or replace function public._wallet_apply(p_player uuid, p_delta int, p_reason text, p_ref text, p_note text)
returns int language plpgsql security definer set search_path = public as $$
declare v_bal int;
begin
  if p_delta = 0 then
    raise exception 'Nothing to apply.';
  end if;
  insert into public.wallets (player_id) values (p_player) on conflict do nothing;
  if p_delta < 0 then
    update public.wallets set balance = balance + p_delta, updated_at = now()
      where player_id = p_player and balance >= -p_delta
      returning balance into v_bal;
    if v_bal is null then
      raise exception 'Not enough points. Load points from your wallet first.';
    end if;
  else
    update public.wallets set balance = balance + p_delta, updated_at = now()
      where player_id = p_player returning balance into v_bal;
  end if;
  insert into public.wallet_ledger (player_id, delta, balance_after, reason, ref, note)
  values (p_player, p_delta, v_bal, p_reason, p_ref, p_note);
  return v_bal;
end;
$$;

-- ── effect plans (internal), shared by codes and points ──
create or replace function public._apply_effect_plan(p_player uuid, p_kind text, p_effect text, p_slug text, p_ref text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_reg public.registrations;
  v_tier text;
  v_start timestamptz;
  v_pass public.effect_passes;
begin
  if p_kind = 'fx_game' then
    if not public.fx_tier_ok('game', p_effect) then
      raise exception 'Pick one of the standard effects for a single match.';
    end if;
    select * into v_reg from public.registrations
      where tournament_slug = p_slug and player_id = p_player and status in ('confirmed','approved');
    if v_reg.id is null then
      raise exception 'Only confirmed squads can add an effect.';
    end if;
    update public.registrations set effect = p_effect where id = v_reg.id;
    return jsonb_build_object('kind', 'fx_game', 'effect', p_effect, 'ref', v_reg.id);
  elsif p_kind in ('fx_lite_week','fx_week','fx_month') then
    v_tier := case when p_kind = 'fx_lite_week' then 'lite' else 'pro' end;
    if not public.fx_tier_ok(v_tier, p_effect) then
      raise exception 'That effect is not included in this plan.';
    end if;
    select max(expires_at) into v_start from public.effect_passes
      where player_id = p_player and expires_at > now();
    v_start := greatest(coalesce(v_start, now()), now());
    insert into public.effect_passes (player_id, tier, effect, starts_at, expires_at, code)
    values (p_player, v_tier, p_effect, v_start,
            v_start + make_interval(days => case when p_kind = 'fx_month' then 30 else 7 end), p_ref)
    returning * into v_pass;
    return jsonb_build_object('kind', p_kind, 'effect', p_effect, 'starts_at', v_pass.starts_at, 'expires_at', v_pass.expires_at, 'ref', v_pass.id);
  end if;
  raise exception 'Unknown plan.';
end;
$$;

-- redeem_code now shares _apply_effect_plan for its effect branches
create or replace function public.redeem_code(p_code text, p_tournament_slug text default null, p_effect text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code public.payment_codes;
  v_reg public.registrations;
  v_slots int;
  v_count int;
  v_res jsonb;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  p_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9-]', '', 'g'));
  if p_code = '' then
    raise exception 'Enter your code.';
  end if;
  update public.payment_codes set redeemed_by = auth.uid(), redeemed_at = now()
    where code = p_code and redeemed_at is null
    returning * into v_code;
  if v_code.code is null then
    if exists(select 1 from public.payment_codes where code = p_code) then
      raise exception 'This code has already been used.';
    end if;
    raise exception 'Code not recognised. Check it and try again.';
  end if;

  if v_code.kind = 'entry' then
    if p_tournament_slug is distinct from v_code.tournament_slug then
      raise exception 'This code is for %, not this tournament.', v_code.tournament_slug;
    end if;
    perform pg_advisory_xact_lock(hashtext(v_code.tournament_slug));
    select * into v_reg from public.registrations
      where tournament_slug = v_code.tournament_slug and player_id = auth.uid();
    if v_reg.id is null then
      raise exception 'Register for % first, then enter your code.', v_code.tournament_slug;
    end if;
    if v_reg.status in ('confirmed','approved') then
      raise exception 'Your squad is already confirmed for this tournament.';
    end if;
    if v_reg.status = 'no_show' then
      raise exception 'This registration can no longer be confirmed.';
    end if;
    select slots into v_slots from public.tournament_capacity where tournament_slug = v_code.tournament_slug;
    if v_slots is not null then
      select count(*) into v_count from public.registrations
        where tournament_slug = v_code.tournament_slug and status in ('confirmed','approved');
      if v_count >= v_slots then
        raise exception 'All slots are full, so your code was not used. Please contact the organiser on WhatsApp.';
      end if;
    end if;
    update public.registrations set status = 'approved' where id = v_reg.id;
    update public.payment_codes set redeemed_for = v_reg.id::text where code = p_code;
    insert into public.notifications (player_id, tournament_slug, title, body)
    values (auth.uid(), v_code.tournament_slug, '✅ Entry confirmed: ' || v_code.tournament_slug,
            'Your payment code was accepted and ' || coalesce(v_reg.squad_name, 'your squad') || ' is confirmed. Room details will be sent here before the match.');
    return jsonb_build_object('kind', 'entry', 'status', 'approved');
  end if;

  v_res := public._apply_effect_plan(auth.uid(), v_code.kind, p_effect, p_tournament_slug, p_code);
  update public.payment_codes set redeemed_for = v_res->>'ref' where code = p_code;
  return v_res;
end;
$$;

-- ── player actions ──
create or replace function public.pay_entry_with_points(p_tournament_slug text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_price int;
  v_start timestamptz;
  v_reg public.registrations;
  v_slots int;
  v_count int;
  v_bal int;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  v_price := public.tournament_entry_npr(p_tournament_slug);
  if v_price is null or v_price <= 0 then
    raise exception 'This tournament has no entry fee to pay.';
  end if;
  v_start := public.tournament_start_at(p_tournament_slug);
  if v_start is not null and v_start <= now() then
    raise exception 'This match has already started.';
  end if;
  perform pg_advisory_xact_lock(hashtext(p_tournament_slug));
  select * into v_reg from public.registrations
    where tournament_slug = p_tournament_slug and player_id = auth.uid();
  if v_reg.id is null then
    raise exception 'Register for this tournament first.';
  end if;
  if v_reg.status <> 'pending' then
    raise exception 'This registration does not need a payment.';
  end if;
  select slots into v_slots from public.tournament_capacity where tournament_slug = p_tournament_slug;
  if v_slots is not null then
    select count(*) into v_count from public.registrations
      where tournament_slug = p_tournament_slug and status in ('confirmed','approved');
    if v_count >= v_slots then
      raise exception 'All slots are full, so no points were taken.';
    end if;
  end if;
  v_bal := public._wallet_apply(auth.uid(), -v_price, 'entry', v_reg.id::text, p_tournament_slug);
  update public.registrations set status = 'approved', paid_points = v_price where id = v_reg.id;
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (auth.uid(), p_tournament_slug, '✅ Entry confirmed: ' || p_tournament_slug,
          v_price || ' points paid — ' || coalesce(v_reg.squad_name, 'your squad') || ' is confirmed. Room details will be sent here before the match.');
  return jsonb_build_object('status', 'approved', 'paid', v_price, 'balance', v_bal);
end;
$$;

create or replace function public.buy_effect_with_points(p_kind text, p_effect text, p_tournament_slug text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_price int;
  v_res jsonb;
  v_bal int;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  v_price := case p_kind when 'fx_game' then 2 when 'fx_lite_week' then 5 when 'fx_week' then 10 when 'fx_month' then 30 end;
  if v_price is null then
    raise exception 'Unknown plan.';
  end if;
  v_res := public._apply_effect_plan(auth.uid(), p_kind, p_effect, p_tournament_slug, 'points');
  v_bal := public._wallet_apply(auth.uid(), -v_price, 'effect', v_res->>'ref', p_kind || ':' || p_effect);
  return v_res || jsonb_build_object('paid', v_price, 'balance', v_bal);
end;
$$;

create or replace function public.request_withdrawal(p_amount int, p_esewa_id text, p_esewa_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_req public.withdraw_requests;
  v_bal int;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  if p_amount is null or p_amount < 1 then
    raise exception 'Enter how many points to withdraw.';
  end if;
  p_esewa_id := trim(coalesce(p_esewa_id, ''));
  p_esewa_name := trim(coalesce(p_esewa_name, ''));
  if length(p_esewa_id) < 5 or length(p_esewa_id) > 40 then
    raise exception 'Enter your eSewa ID (the phone number or email on your eSewa account).';
  end if;
  if length(p_esewa_name) < 2 or length(p_esewa_name) > 60 then
    raise exception 'Enter the name on your eSewa account.';
  end if;
  insert into public.withdraw_requests (player_id, amount, esewa_id, esewa_name)
  values (auth.uid(), p_amount, p_esewa_id, p_esewa_name) returning * into v_req;
  v_bal := public._wallet_apply(auth.uid(), -p_amount, 'withdraw', v_req.id::text, null);
  return jsonb_build_object('id', v_req.id, 'amount', p_amount, 'balance', v_bal);
end;
$$;

create or replace function public.withdraw_registration(p_tournament_slug text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_reg public.registrations;
  v_start timestamptz;
  v_late boolean := false;
  v_refund int := 0;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  select * into v_reg from public.registrations
    where tournament_slug = p_tournament_slug and player_id = auth.uid();
  if v_reg.id is null then
    raise exception 'You are not registered for this tournament.';
  end if;
  v_start := public.tournament_start_at(p_tournament_slug);
  if v_start is not null and v_start <= now() then
    raise exception 'This match has already started, so squads can no longer withdraw.';
  end if;
  if exists(select 1 from public.tournament_room_codes where tournament_slug = p_tournament_slug and sent_at is not null) then
    raise exception 'The room details have been released, so squads can no longer withdraw.';
  end if;
  v_late := v_start is not null and v_start - now() < interval '24 hours';
  if v_reg.paid_points > 0 then
    v_refund := case when v_late then floor(v_reg.paid_points * 0.1)::int else v_reg.paid_points end;
  end if;
  delete from public.registrations where id = v_reg.id;
  if v_refund > 0 then
    perform public._wallet_apply(auth.uid(), v_refund, 'refund', v_reg.id::text, p_tournament_slug);
  end if;
  return jsonb_build_object('refund', v_refund, 'late', v_late, 'paid_points', v_reg.paid_points);
end;
$$;

-- ── admin (service role only, via the wallet-admin Edge Function) ──
create or replace function public.admin_wallet_credit(p_player uuid, p_amount int, p_ref text, p_note text)
returns int language plpgsql security definer set search_path = public as $$
declare v_bal int;
begin
  if p_amount is null or p_amount < 1 then
    raise exception 'Enter how many points to add.';
  end if;
  p_ref := upper(trim(coalesce(p_ref, '')));
  if p_ref = '' then
    raise exception 'Enter the eSewa transaction ID so the same payment cannot be credited twice.';
  end if;
  begin
    v_bal := public._wallet_apply(p_player, p_amount, 'load', p_ref, p_note);
  exception when unique_violation then
    raise exception 'This eSewa transaction (%) has already been credited.', p_ref;
  end;
  insert into public.notifications (player_id, title, body)
  values (p_player, '🪙 ' || p_amount || ' points added',
          'Your payment was verified and ' || p_amount || ' points were added to your wallet. Balance: ' || v_bal || ' points.');
  return v_bal;
end;
$$;

create or replace function public.admin_resolve_withdrawal(p_id uuid, p_paid boolean, p_payout_ref text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_req public.withdraw_requests;
begin
  update public.withdraw_requests
    set status = case when p_paid then 'paid' else 'rejected' end, processed_at = now(), payout_ref = nullif(trim(coalesce(p_payout_ref, '')), '')
    where id = p_id and status = 'pending'
    returning * into v_req;
  if v_req.id is null then
    raise exception 'This withdrawal was already processed.';
  end if;
  if p_paid then
    insert into public.notifications (player_id, title, body)
    values (v_req.player_id, '💸 Withdrawal sent: Rs ' || v_req.amount,
            'Rs ' || v_req.amount || ' was sent to your eSewa (' || v_req.esewa_id || ')' || coalesce(' · ref ' || v_req.payout_ref, '') || '.');
  else
    perform public._wallet_apply(v_req.player_id, v_req.amount, 'withdraw_returned', v_req.id::text, null);
    insert into public.notifications (player_id, title, body)
    values (v_req.player_id, 'Withdrawal not processed',
            'Your withdrawal of ' || v_req.amount || ' points could not be sent, so the points were returned to your wallet. Please check your eSewa details or contact us on WhatsApp.');
  end if;
  return jsonb_build_object('id', v_req.id, 'status', v_req.status);
end;
$$;

-- ── who can call what ──
revoke all on function public._wallet_apply(uuid, int, text, text, text) from public, anon, authenticated;
revoke all on function public._apply_effect_plan(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.admin_wallet_credit(uuid, int, text, text) from public, anon, authenticated;
revoke all on function public.admin_resolve_withdrawal(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public._wallet_apply(uuid, int, text, text, text) to service_role;
grant execute on function public._apply_effect_plan(uuid, text, text, text, text) to service_role;
grant execute on function public.admin_wallet_credit(uuid, int, text, text) to service_role;
grant execute on function public.admin_resolve_withdrawal(uuid, boolean, text) to service_role;
revoke all on function public.pay_entry_with_points(text) from public, anon;
revoke all on function public.buy_effect_with_points(text, text, text) from public, anon;
revoke all on function public.request_withdrawal(int, text, text) from public, anon;
revoke all on function public.withdraw_registration(text) from public, anon;
grant execute on function public.pay_entry_with_points(text) to authenticated;
grant execute on function public.buy_effect_with_points(text, text, text) to authenticated;
grant execute on function public.request_withdrawal(int, text, text) to authenticated;
grant execute on function public.withdraw_registration(text) to authenticated;

commit;

-- ── unlimited admin wallet ──────────────────────────────────────────────
-- The organiser's own account (ayerprabin95@gmail.com) spends points without the balance
-- going down, so they can test paid entries/effects freely. Flag lives on the wallet row;
-- players can't change it (no insert/update policies on wallets). An unlimited wallet
-- can't request withdrawals — there's no real money behind it.
begin;
alter table public.wallets add column if not exists unlimited boolean not null default false;
insert into public.wallets (player_id, unlimited)
  select id, true from public.players where lower(email) = 'ayerprabin95@gmail.com'
  on conflict (player_id) do update set unlimited = true;

create or replace function public._wallet_apply(p_player uuid, p_delta int, p_reason text, p_ref text, p_note text)
returns int language plpgsql security definer set search_path = public as $$
declare v_bal int; v_unl boolean;
begin
  if p_delta = 0 then
    raise exception 'Nothing to apply.';
  end if;
  insert into public.wallets (player_id) values (p_player) on conflict do nothing;
  select unlimited into v_unl from public.wallets where player_id = p_player for update;
  if p_delta < 0 and v_unl then
    select balance into v_bal from public.wallets where player_id = p_player;
  elsif p_delta < 0 then
    update public.wallets set balance = balance + p_delta, updated_at = now()
      where player_id = p_player and balance >= -p_delta
      returning balance into v_bal;
    if v_bal is null then
      raise exception 'Not enough points. Load points from your wallet first.';
    end if;
  else
    update public.wallets set balance = balance + p_delta, updated_at = now()
      where player_id = p_player returning balance into v_bal;
  end if;
  insert into public.wallet_ledger (player_id, delta, balance_after, reason, ref, note)
  values (p_player, p_delta, v_bal, p_reason, p_ref, p_note);
  return v_bal;
end;
$$;
revoke all on function public._wallet_apply(uuid, int, text, text, text) from public, anon, authenticated;
grant execute on function public._wallet_apply(uuid, int, text, text, text) to service_role;

create or replace function public.request_withdrawal(p_amount int, p_esewa_id text, p_esewa_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_req public.withdraw_requests;
  v_bal int;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  if exists(select 1 from public.wallets where player_id = auth.uid() and unlimited) then
    raise exception 'The admin wallet has unlimited points, so it can''t be withdrawn.';
  end if;
  if p_amount is null or p_amount < 1 then
    raise exception 'Enter how many points to withdraw.';
  end if;
  p_esewa_id := trim(coalesce(p_esewa_id, ''));
  p_esewa_name := trim(coalesce(p_esewa_name, ''));
  if length(p_esewa_id) < 5 or length(p_esewa_id) > 40 then
    raise exception 'Enter your eSewa ID (the phone number or email on your eSewa account).';
  end if;
  if length(p_esewa_name) < 2 or length(p_esewa_name) > 60 then
    raise exception 'Enter the name on your eSewa account.';
  end if;
  insert into public.withdraw_requests (player_id, amount, esewa_id, esewa_name)
  values (auth.uid(), p_amount, p_esewa_id, p_esewa_name) returning * into v_req;
  v_bal := public._wallet_apply(auth.uid(), -p_amount, 'withdraw', v_req.id::text, null);
  return jsonb_build_object('id', v_req.id, 'amount', p_amount, 'balance', v_bal);
end;
$$;
revoke all on function public.request_withdrawal(int, text, text) from public, anon;
grant execute on function public.request_withdrawal(int, text, text) to authenticated;

create or replace function public.admin_wallet_credit(p_player uuid, p_amount int, p_ref text, p_note text)
returns int language plpgsql security definer set search_path = public as $$
declare v_bal int;
begin
  if p_amount is null or p_amount < 1 then
    raise exception 'Enter how many points to add.';
  end if;
  p_ref := upper(trim(coalesce(p_ref, '')));
  if p_ref = '' then
    raise exception 'Enter the eSewa transaction ID so the same payment cannot be credited twice.';
  end if;
  begin
    v_bal := public._wallet_apply(p_player, p_amount, 'load', p_ref, p_note);
  exception when unique_violation then
    raise exception 'This eSewa transaction (%) has already been credited.', p_ref;
  end;
  insert into public.notifications (player_id, title, body)
  values (p_player, '+' || p_amount || ' JD points added',
          'Your payment was verified and ' || p_amount || ' points were added to your wallet. Balance: ' || v_bal || ' points.');
  return v_bal;
end;
$$;
revoke all on function public.admin_wallet_credit(uuid, int, text, text) from public, anon, authenticated;
grant execute on function public.admin_wallet_credit(uuid, int, text, text) to service_role;
commit;

-- ── automatic prize payouts as points ───────────────────────────────────
-- award_prizes() pays tournament prizes into winners' wallets the moment results are
-- announced. It is called by publish-tournaments (every publish) and archive-results,
-- and can be re-run safely: each squad's prize for a tournament is paid at most once
-- (unique ledger ref 'prize:<tournament>:<squad>'). Prize amounts, in priority order:
--   1. archived results (tournament_results.prize_won > 0) for that tournament
--   2. the published Best-of-3 board (bo3.published, teams[].prize_won > 0)
--   3. the tournament's `winner` field -> the whole posted prize (first number in `prize`)
-- The points go to the player who registered that squad in-app (confirmed/approved).
-- Squads that only registered over WhatsApp can't be matched and are reported back.
begin;

alter table public.wallet_ledger drop constraint if exists wallet_ledger_reason_check;
alter table public.wallet_ledger add constraint wallet_ledger_reason_check
  check (reason in ('load','entry','effect','withdraw','withdraw_returned','refund','adjust','prize'));
create unique index if not exists wallet_ledger_prize_ref on public.wallet_ledger(ref) where reason = 'prize';

create or replace function public._award_one(p_slug text, p_squad text, p_amount int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_player uuid;
  v_ref text := 'prize:' || p_slug || ':' || lower(trim(p_squad));
  v_bal int;
begin
  if p_amount is null or p_amount < 1 then
    return jsonb_build_object('squad', p_squad, 'status', 'no_amount');
  end if;
  if exists(select 1 from public.wallet_ledger where reason = 'prize' and ref = v_ref) then
    return jsonb_build_object('squad', p_squad, 'status', 'already_paid');
  end if;
  select player_id into v_player from public.registrations
    where tournament_slug = p_slug and lower(trim(squad_name)) = lower(trim(p_squad))
      and status in ('confirmed','approved')
    order by created_at asc limit 1;
  if v_player is null then
    return jsonb_build_object('squad', p_squad, 'status', 'unmatched', 'amount', p_amount);
  end if;
  v_bal := public._wallet_apply(v_player, p_amount, 'prize', v_ref, p_slug);
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (v_player, p_slug, '🏆 Prize: +' || p_amount || ' JD points',
          'Congratulations! ' || p_squad || '''s prize for ' || p_slug || ' (' || p_amount || ' points) is in your wallet. Balance: ' || v_bal || ' points. You can use it for entries or withdraw it to eSewa.');
  return jsonb_build_object('squad', p_squad, 'status', 'paid', 'amount', p_amount, 'player_id', v_player);
end;
$$;

create or replace function public.award_prizes(p_slug text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_doc jsonb;
  t jsonb;
  v_slug text;
  v_out jsonb := '[]'::jsonb;
  r record;
  v_amt int;
begin
  select content into v_doc from public.site_content where key = 'tournaments';
  if v_doc is null then
    return v_out;
  end if;
  for t in select value from jsonb_array_elements(coalesce(v_doc->'tournaments', '[]'::jsonb)) loop
    v_slug := t->>'name';
    continue when v_slug is null or (p_slug is not null and v_slug <> p_slug);
    perform pg_advisory_xact_lock(hashtext('prize:' || v_slug));
    if exists(select 1 from public.tournament_results where tournament_slug = v_slug and prize_won > 0) then
      for r in select squad_name, floor(prize_won)::int amt from public.tournament_results
               where tournament_slug = v_slug and prize_won > 0 loop
        v_out := v_out || jsonb_build_array(public._award_one(v_slug, r.squad_name, r.amt) || jsonb_build_object('tournament', v_slug));
      end loop;
    elsif v_doc->'bo3'->>'tournament' = v_slug and coalesce((v_doc->'bo3'->>'published')::boolean, false)
          and exists(select 1 from jsonb_array_elements(coalesce(v_doc->'bo3'->'teams','[]'::jsonb)) x
                     where coalesce(nullif(regexp_replace(x->>'prize_won','[^0-9.]','','g'),''),'0')::numeric > 0) then
      for r in select x->>'team' squad, floor(nullif(regexp_replace(x->>'prize_won','[^0-9.]','','g'),'')::numeric)::int amt
               from jsonb_array_elements(v_doc->'bo3'->'teams') x
               where coalesce(nullif(regexp_replace(x->>'prize_won','[^0-9.]','','g'),''),'0')::numeric > 0 loop
        v_out := v_out || jsonb_build_array(public._award_one(v_slug, r.squad, r.amt) || jsonb_build_object('tournament', v_slug));
      end loop;
    elsif coalesce(trim(t->>'winner'), '') <> '' then
      v_amt := nullif(replace(substring(coalesce(t->>'prize', '') from '[0-9][0-9,]*'), ',', ''), '')::int;
      if v_amt is not null and v_amt > 0 then
        v_out := v_out || jsonb_build_array(public._award_one(v_slug, trim(t->>'winner'), v_amt) || jsonb_build_object('tournament', v_slug));
      end if;
    end if;
  end loop;
  return v_out;
end;
$$;

revoke all on function public._award_one(text, text, int) from public, anon, authenticated;
revoke all on function public.award_prizes(text) from public, anon, authenticated;
grant execute on function public._award_one(text, text, int) to service_role;
grant execute on function public.award_prizes(text) to service_role;
commit;

-- ── security hardening + automatic lockdown ─────────────────────────────
-- 1. system_state.locked = the kill switch. While locked, every points movement
--    (_wallet_apply: entries, effects, refunds, prizes, credits, withdrawals) and every
--    code redemption is refused. Free registration and check-in keep working, so a lock
--    can never cancel a free tournament.
-- 2. security_sweep() runs every 5 minutes (pg_cron). It locks the system only on
--    things a normal player cannot cause: a wallet whose balance doesn't equal the sum
--    of its ledger (someone changed a balance outside _wallet_apply). The admin is
--    notified and unlocks from the admin panel once it's fixed.
-- 3. Tamper-proofing: ledger rows can't be edited, or deleted while their player
--    exists; a wallet balance can only change in the same transaction as a matching
--    ledger row (deferred check), so even a leaked service key can't quietly mint points.
-- 4. Per-player withdrawal rate limit (spam is rejected for that player, never a site lock).
-- 5. Players can only mark notifications read (read_at), and can no longer delete
--    registrations directly (withdraw_registration() applies the refund rules).
begin;

create table if not exists public.system_state (
  id int primary key default 1 check (id = 1),
  locked boolean not null default false,
  reason text,
  locked_at timestamptz,
  unlocked_at timestamptz
);
insert into public.system_state (id) values (1) on conflict do nothing;
alter table public.system_state enable row level security;
drop policy if exists "public read system state" on public.system_state;
create policy "public read system state" on public.system_state for select using (true);

create or replace function public._assert_open()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if exists(select 1 from public.system_state where id = 1 and locked) then
    raise exception 'Payments are paused for a security check. Your points are safe — please try again later.';
  end if;
end;
$$;

create or replace function public._wallet_apply(p_player uuid, p_delta int, p_reason text, p_ref text, p_note text)
returns int language plpgsql security definer set search_path = public as $$
declare v_bal int; v_unl boolean;
begin
  perform public._assert_open();
  if p_delta = 0 then
    raise exception 'Nothing to apply.';
  end if;
  insert into public.wallets (player_id) values (p_player) on conflict do nothing;
  select unlimited into v_unl from public.wallets where player_id = p_player for update;
  if p_delta < 0 and v_unl then
    select balance into v_bal from public.wallets where player_id = p_player;
  elsif p_delta < 0 then
    update public.wallets set balance = balance + p_delta, updated_at = now()
      where player_id = p_player and balance >= -p_delta
      returning balance into v_bal;
    if v_bal is null then
      raise exception 'Not enough points. Load points from your wallet first.';
    end if;
  else
    update public.wallets set balance = balance + p_delta, updated_at = now()
      where player_id = p_player returning balance into v_bal;
  end if;
  insert into public.wallet_ledger (player_id, delta, balance_after, reason, ref, note)
  values (p_player, p_delta, v_bal, p_reason, p_ref, p_note);
  return v_bal;
end;
$$;

-- redeem_code: refuse while locked (entry codes don't move points but do confirm paid slots)
do $$
declare d text;
begin
  select pg_get_functiondef('public.redeem_code(text,text,text)'::regprocedure) into d;
  if position('_assert_open' in d) = 0 then
    d := regexp_replace(d, E'\\nbegin\\n', E'\nbegin\n  perform public._assert_open();\n');
    execute d;
  end if;
end $$;

-- per-player withdrawal rate limit: at most 3 requests per hour
create or replace function public.request_withdrawal(p_amount int, p_esewa_id text, p_esewa_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_req public.withdraw_requests;
  v_bal int;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  perform public._assert_open();
  if exists(select 1 from public.wallets where player_id = auth.uid() and unlimited) then
    raise exception 'The admin wallet has unlimited points, so it can''t be withdrawn.';
  end if;
  if (select count(*) from public.withdraw_requests where player_id = auth.uid() and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Too many withdrawal requests — please wait an hour and try again.';
  end if;
  if p_amount is null or p_amount < 1 then
    raise exception 'Enter how many points to withdraw.';
  end if;
  p_esewa_id := trim(coalesce(p_esewa_id, ''));
  p_esewa_name := trim(coalesce(p_esewa_name, ''));
  if length(p_esewa_id) < 5 or length(p_esewa_id) > 40 then
    raise exception 'Enter your eSewa ID (the phone number or email on your eSewa account).';
  end if;
  if length(p_esewa_name) < 2 or length(p_esewa_name) > 60 then
    raise exception 'Enter the name on your eSewa account.';
  end if;
  insert into public.withdraw_requests (player_id, amount, esewa_id, esewa_name)
  values (auth.uid(), p_amount, p_esewa_id, p_esewa_name) returning * into v_req;
  v_bal := public._wallet_apply(auth.uid(), -p_amount, 'withdraw', v_req.id::text, null);
  return jsonb_build_object('id', v_req.id, 'amount', p_amount, 'balance', v_bal);
end;
$$;

-- ledger is append-only (deletes allowed only as part of deleting the whole account)
create or replace function public._ledger_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    raise exception 'Wallet history cannot be edited.';
  end if;
  if exists(select 1 from public.players where id = old.player_id) then
    raise exception 'Wallet history cannot be deleted.';
  end if;
  return old;
end;
$$;
drop trigger if exists wallet_ledger_guard on public.wallet_ledger;
create trigger wallet_ledger_guard before update or delete on public.wallet_ledger
  for each row execute function public._ledger_guard();

-- a balance may only change alongside a matching ledger row in the same transaction
create or replace function public._wallet_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.balance is distinct from old.balance and not new.unlimited
     and not exists(select 1 from public.wallet_ledger
                    where player_id = new.player_id and created_at = now() and balance_after = new.balance) then
    raise exception 'Wallet balances can only change through a recorded transaction.';
  end if;
  return null;
end;
$$;
drop trigger if exists wallets_balance_guard on public.wallets;
create constraint trigger wallets_balance_guard after update on public.wallets
  deferrable initially deferred for each row execute function public._wallet_guard();

-- the sweep: p_apply=false only reports
create or replace function public.security_sweep(p_apply boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_issues jsonb := '[]'::jsonb;
  r record;
  v_admin uuid;
begin
  for r in
    select w.player_id, w.balance, coalesce(sum(l.delta), 0)::int as ledger_sum
    from public.wallets w left join public.wallet_ledger l on l.player_id = w.player_id
    where not w.unlimited
    group by w.player_id, w.balance
    having w.balance <> coalesce(sum(l.delta), 0)
  loop
    v_issues := v_issues || jsonb_build_array(jsonb_build_object('type', 'balance_mismatch', 'player_id', r.player_id, 'balance', r.balance, 'ledger_sum', r.ledger_sum));
  end loop;

  if p_apply and jsonb_array_length(v_issues) > 0
     and not exists(select 1 from public.system_state where id = 1 and locked) then
    update public.system_state set locked = true, locked_at = now(),
      reason = 'Automatic lock: ' || jsonb_array_length(v_issues) || ' wallet(s) whose balance does not match their history.'
      where id = 1;
    select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com';
    if v_admin is not null then
      insert into public.notifications (player_id, title, body)
      values (v_admin, '🚨 JD Arena auto-locked',
              'The security sweep found ' || jsonb_array_length(v_issues) || ' wallet(s) whose balance does not match their history, so all payments are paused. Open Admin → Security to review and unlock.');
    end if;
  end if;
  return jsonb_build_object('issues', v_issues, 'locked', (select locked from public.system_state where id = 1));
end;
$$;

create or replace function public.admin_set_lock(p_locked boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  update public.system_state set locked = p_locked,
    reason = case when p_locked then coalesce(nullif(trim(p_reason), ''), 'Locked by admin') else reason end,
    locked_at = case when p_locked then now() else locked_at end,
    unlocked_at = case when p_locked then unlocked_at else now() end
    where id = 1;
  return (select to_jsonb(s) from public.system_state s where id = 1);
end;
$$;

revoke all on function public._assert_open() from public, anon, authenticated;
revoke all on function public._ledger_guard() from public, anon, authenticated;
revoke all on function public._wallet_guard() from public, anon, authenticated;
revoke all on function public.security_sweep(boolean) from public, anon, authenticated;
revoke all on function public.admin_set_lock(boolean, text) from public, anon, authenticated;
revoke all on function public._wallet_apply(uuid, int, text, text, text) from public, anon, authenticated;
grant execute on function public._wallet_apply(uuid, int, text, text, text) to service_role;
grant execute on function public.security_sweep(boolean) to service_role;
grant execute on function public.admin_set_lock(boolean, text) to service_role;
revoke all on function public.request_withdrawal(int, text, text) from public, anon;
grant execute on function public.request_withdrawal(int, text, text) to authenticated;

-- players: withdraw only through withdraw_registration(); mark notifications read only
drop policy if exists "players delete own registration" on public.registrations;
revoke update on public.notifications from authenticated, anon;
grant update (read_at) on public.notifications to authenticated;

commit;

-- ── security follow-ups ─────────────────────────────────────────────────
-- * balance guard skips a wallet that's being deleted with its account (cascade)
-- * register_for_tournament(): squad logo must be a real base64 image (<= 200 KB) and the
--   squad name a sane length — this is what stops a crafted "logo" from carrying script
--   into pages that display it
-- * security sweep scheduled every 5 minutes
begin;

create or replace function public._wallet_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from public.wallets where player_id = new.player_id) then
    return null; -- wallet deleted with its account
  end if;
  if new.balance is distinct from old.balance and not new.unlimited
     and not exists(select 1 from public.wallet_ledger
                    where player_id = new.player_id and created_at = now() and balance_after = new.balance) then
    raise exception 'Wallet balances can only change through a recorded transaction.';
  end if;
  return null;
end;
$$;
revoke all on function public._wallet_guard() from public, anon, authenticated;

do $$
declare d text;
begin
  select pg_get_functiondef('public.register_for_tournament(text,text,text,text,text,text)'::regprocedure) into d;
  if position('squad logo must be' in lower(d)) = 0 then
    d := regexp_replace(d, E'\\n  if p_status not in \\(''pending'',''confirmed''\\) then',
      E'\n  if p_squad_logo is not null and (length(p_squad_logo) > 200000 or p_squad_logo !~ ''^data:image/(png|jpe?g|webp|gif);base64,[A-Za-z0-9+/=]+$'') then\n    raise exception ''Squad logo must be a PNG, JPG, WEBP or GIF image under 200 KB.'';\n  end if;\n  if p_squad_name is not null and length(trim(p_squad_name)) > 40 then\n    raise exception ''Squad name must be 40 characters or fewer.'';\n  end if;\n  if p_status not in (''pending'',''confirmed'') then');
    execute d;
  end if;
end $$;

select cron.unschedule(jobid) from cron.job where jobname = 'security-sweep';
select cron.schedule('security-sweep', '*/5 * * * *', 'select public.security_sweep(true)');

commit;

-- ── saved squad (name + logo on the profile) ─────────────────────────────
-- One squad name + logo per player, stored once on players instead of copied into every
-- registration. Changing the logo overwrites the old image. Rosters fall back to it.
-- Backup of the per-registration logos cleared here: supabase/.temp/logo_backup_2026-09-28.json
begin;
alter table public.players add column if not exists squad_name text;
alter table public.players add column if not exists squad_logo text;

-- backfill from each player's latest registration
update public.players p set
  squad_name = coalesce(p.squad_name, x.squad_name),
  squad_logo = coalesce(p.squad_logo, x.squad_logo)
from (
  select distinct on (player_id) player_id, squad_name,
    (select r2.squad_logo from public.registrations r2 where r2.player_id = r.player_id and r2.squad_logo is not null order by r2.created_at desc limit 1) squad_logo
  from public.registrations r order by player_id, created_at desc
) x where x.player_id = p.id;
update public.registrations set squad_logo = null where squad_logo is not null;

CREATE OR REPLACE FUNCTION public.register_for_tournament(p_tournament_slug text, p_squad_name text, p_squad_logo text, p_status text, p_payment_screenshot text, p_device_type text)
 RETURNS registrations
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_slots int;
  v_count int;
  v_already_registered boolean;
  v_effective_status text := p_status;
  v_platform_mode text;
  v_row public.registrations;
  v_name text;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;

  if p_squad_logo is not null and (length(p_squad_logo) > 200000 or p_squad_logo !~ '^data:image/(png|jpe?g|webp|gif);base64,[A-Za-z0-9+/=]+$') then
    raise exception 'Squad logo must be a PNG, JPG, WEBP or GIF image under 200 KB.';
  end if;
  if p_squad_name is not null and length(trim(p_squad_name)) > 40 then
    raise exception 'Squad name must be 40 characters or fewer.';
  end if;
  -- Saved squad: a player's squad name/logo live on their profile (players.squad_name /
  -- squad_logo). A new logo passed here replaces the saved one (the old image is gone,
  -- nothing is duplicated per registration); a missing name falls back to the saved name.
  v_name := coalesce(nullif(trim(p_squad_name), ''), (select squad_name from public.players where id = auth.uid()));
  if v_name is null or length(trim(v_name)) < 2 then
    raise exception 'Enter your squad name (at least 2 characters).';
  end if;
  update public.players set squad_name = trim(v_name),
    squad_logo = coalesce(p_squad_logo, squad_logo)
    where id = auth.uid();
  if p_status not in ('pending','confirmed') then
    raise exception 'Invalid registration status';
  end if;

  if coalesce(public.tournament_entry_npr(p_tournament_slug), 0) > 0 then
    p_status := 'pending';
    v_effective_status := 'pending';
  end if;

  if exists(select 1 from public.banned_players where player_id = auth.uid()) then
    raise exception 'Your account is banned from registering for tournaments.';
  end if;

  if p_device_type not in ('mobile','emulator') then
    raise exception 'Pick a device type: mobile or emulator.';
  end if;

  select platform_mode into v_platform_mode from public.tournament_capacity where tournament_slug = p_tournament_slug;
  v_platform_mode := coalesce(v_platform_mode, 'mixed');
  if v_platform_mode <> 'mixed' and v_platform_mode <> p_device_type then
    raise exception 'This tournament is % only -- you declared %.', v_platform_mode, p_device_type;
  end if;

  perform pg_advisory_xact_lock(hashtext(p_tournament_slug));

  select exists(
    select 1 from public.registrations
    where tournament_slug = p_tournament_slug and player_id = auth.uid()
  ) into v_already_registered;

  if not v_already_registered then
    select slots into v_slots from public.tournament_capacity where tournament_slug = p_tournament_slug;
    if v_slots is not null then
      select count(*) into v_count from public.registrations
        where tournament_slug = p_tournament_slug and status in ('confirmed', 'approved');
      if v_count >= v_slots then
        if p_status = 'confirmed' then
          v_effective_status := 'waitlisted';
        else
          raise exception 'Tournament full';
        end if;
      end if;
    end if;
  end if;

  insert into public.registrations (tournament_slug, player_id, squad_name, squad_logo, status, payment_screenshot, device_type)
  values (p_tournament_slug, auth.uid(), trim(v_name), null, v_effective_status, p_payment_screenshot, p_device_type)
  returning * into v_row;

  insert into public.notifications (player_id, tournament_slug, title, body)
  values (
    auth.uid(),
    p_tournament_slug,
    '🎫 Registered: ' || p_tournament_slug,
    'TICKET::' || ('JD-' || upper(substr(replace(v_row.id::text, '-', ''), 1, 8))) || '::' || v_effective_status
  );

  return v_row;
end;
$function$;

create or replace function public.set_my_squad(p_name text, p_logo text default null, p_clear_logo boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  if p_name is not null and (length(trim(p_name)) < 2 or length(trim(p_name)) > 40) then
    raise exception 'Squad name must be 2-40 characters.';
  end if;
  if p_logo is not null and (length(p_logo) > 200000 or p_logo !~ '^data:image/(png|jpe?g|webp|gif);base64,[A-Za-z0-9+/=]+$') then
    raise exception 'Squad logo must be a PNG, JPG, WEBP or GIF image under 200 KB.';
  end if;
  update public.players set
    squad_name = coalesce(nullif(trim(p_name), ''), squad_name),
    squad_logo = case when p_clear_logo then null else coalesce(p_logo, squad_logo) end
  where id = auth.uid();
  return (select jsonb_build_object('squad_name', squad_name, 'has_logo', squad_logo is not null) from public.players where id = auth.uid());
end;
$$;
revoke all on function public.set_my_squad(text, text, boolean) from public, anon;
grant execute on function public.set_my_squad(text, text, boolean) to authenticated;

create or replace function public.get_public_roster()
returns table(tournament_slug text, squad_name text, squad_logo text, registered_at timestamptz, effect text)
language sql security definer set search_path = public stable as $$
  select r.tournament_slug, r.squad_name, coalesce(r.squad_logo, p.squad_logo), r.created_at,
    coalesce(r.effect, (
      select ep.effect from public.effect_passes ep
      where ep.player_id = r.player_id and ep.starts_at <= now() and ep.expires_at > now()
      order by ep.expires_at asc limit 1
    ))
  from public.registrations r left join public.players p on p.id = r.player_id
  where r.status in ('confirmed', 'approved')
  order by r.created_at asc;
$$;
grant execute on function public.get_public_roster() to anon, authenticated;
commit;

-- admin_wallet_credit: eSewa transaction ID is optional (manual loads). When given, the
-- same transaction still can't be credited twice; when blank, a unique MANUAL-… ref is used.
begin;
create or replace function public.admin_wallet_credit(p_player uuid, p_amount int, p_ref text, p_note text)
returns int language plpgsql security definer set search_path = public as $$
declare v_bal int;
begin
  if p_amount is null or p_amount < 1 then
    raise exception 'Enter how many points to add.';
  end if;
  p_ref := upper(trim(coalesce(p_ref, '')));
  if p_ref = '' then
    p_ref := 'MANUAL-' || replace(gen_random_uuid()::text, '-', '');
  end if;
  begin
    v_bal := public._wallet_apply(p_player, p_amount, 'load', p_ref, p_note);
  exception when unique_violation then
    raise exception 'This eSewa transaction (%) has already been credited.', p_ref;
  end;
  insert into public.notifications (player_id, title, body)
  values (p_player, '+' || p_amount || ' JD points added',
          'Your payment was verified and ' || p_amount || ' points were added to your wallet. Balance: ' || v_bal || ' points.');
  return v_bal;
end;
$$;
revoke all on function public.admin_wallet_credit(uuid, int, text, text) from public, anon, authenticated;
grant execute on function public.admin_wallet_credit(uuid, int, text, text) to service_role;
commit;

-- ── player-vs-player Clash Squad challenges (points escrow) ──────────────
-- A player creates a challenge (1v1/2v2/3v3/4v4 Clash Squad) with a stake; the stake is
-- taken from their wallet straight away (escrow). An opponent accepts and their stake is
-- taken too. The winner receives the pot: 2 × stake, minus challenge_fee_pct() (0 today).
-- Rules (also shown on /challenges/ and in the terms):
--   * "We lost" pays the other side immediately.
--   * Both say "we won" (or both "we lost") -> disputed -> the admin decides.
--   * One side says "we won" and the other doesn't answer within 2 hours -> claimant wins.
--   * An open challenge nobody accepts expires after 24 hours -> stake refunded.
--   * An accepted challenge nobody reports within 12 hours -> both stakes refunded.
--   * The creator can cancel while it's still open (full refund).
-- Safeguards: 18+ confirmation, 10-500 point stakes, max 3 open challenges per player,
-- banned players and unlimited (admin) wallets can't play, room details and chat are only
-- visible to the two players. All points move through _wallet_apply, so the security
-- lock and sweep cover challenges too. Idempotent.
begin;

alter table public.wallet_ledger drop constraint if exists wallet_ledger_reason_check;
alter table public.wallet_ledger add constraint wallet_ledger_reason_check
  check (reason in ('load','entry','effect','withdraw','withdraw_returned','refund','adjust','prize','challenge_stake','challenge_win','challenge_refund'));

alter table public.players add column if not exists adult_confirmed_at timestamptz;

create table if not exists public.challenges (
  id uuid primary key default gen_random_uuid(),
  creator uuid not null references public.players(id) on delete cascade,
  opponent uuid references public.players(id) on delete set null,
  invited uuid references public.players(id) on delete set null,
  mode text not null check (mode in ('1v1','2v2','3v3','4v4')),
  stake int not null check (stake between 10 and 500),
  note text check (note is null or length(note) <= 120),
  status text not null default 'open' check (status in ('open','accepted','disputed','completed','cancelled','expired','refunded')),
  room_id text check (room_id is null or length(room_id) <= 30),
  room_pass text check (room_pass is null or length(room_pass) <= 30),
  creator_claim text check (creator_claim in ('won','lost')),
  opponent_claim text check (opponent_claim in ('won','lost')),
  claim_at timestamptz,
  winner uuid references public.players(id) on delete set null,
  resolution text,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  resolved_at timestamptz
);
create index if not exists challenges_status_idx on public.challenges(status, created_at desc);
create index if not exists challenges_creator_idx on public.challenges(creator);
create index if not exists challenges_opponent_idx on public.challenges(opponent);
alter table public.challenges enable row level security;
drop policy if exists "participants read own challenges" on public.challenges;
create policy "participants read own challenges" on public.challenges
  for select using (auth.uid() in (creator, opponent, invited));

create table if not exists public.challenge_messages (
  id bigserial primary key,
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  sender uuid references public.players(id) on delete set null,
  body text not null check (length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index if not exists challenge_messages_idx on public.challenge_messages(challenge_id, id);
alter table public.challenge_messages enable row level security;
drop policy if exists "participants read challenge chat" on public.challenge_messages;
create policy "participants read challenge chat" on public.challenge_messages
  for select using (exists(select 1 from public.challenges c where c.id = challenge_id and auth.uid() in (c.creator, c.opponent)));

create or replace function public.challenge_fee_pct() returns int language sql immutable as $$ select 0 $$;

-- ── internal helpers (service role only) ──
create or replace function public._challenge_player_ok(p_player uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select adult_confirmed_at from public.players where id = p_player) is null then
    raise exception 'Challenges are 18+. Please confirm your age first.';
  end if;
  if exists(select 1 from public.banned_players where player_id = p_player) then
    raise exception 'Your account is banned.';
  end if;
  if exists(select 1 from public.wallets where player_id = p_player and unlimited) then
    raise exception 'The admin wallet can''t be used for challenges.';
  end if;
end;
$$;

create or replace function public._challenge_name(p_player uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce('@' || username, player_tag, 'a player') from public.players where id = p_player
$$;

create or replace function public._challenge_payout(p_id uuid, p_winner uuid, p_resolution text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.challenges; v_pot int; v_loser uuid;
begin
  update public.challenges set status = 'completed', winner = p_winner, resolution = p_resolution, resolved_at = now()
    where id = p_id and status in ('accepted','disputed') and p_winner in (creator, opponent)
    returning * into c;
  if c.id is null then
    raise exception 'This challenge is already settled.';
  end if;
  v_pot := floor(c.stake * 2 * (100 - public.challenge_fee_pct()) / 100.0)::int;
  perform public._wallet_apply(p_winner, v_pot, 'challenge_win', c.id::text, c.mode || ' challenge');
  v_loser := case when p_winner = c.creator then c.opponent else c.creator end;
  insert into public.notifications (player_id, title, body) values
    (p_winner, '🏆 Challenge won: +' || v_pot || ' JD points', 'You won the ' || c.mode || ' challenge against ' || public._challenge_name(v_loser) || '. ' || v_pot || ' points are in your wallet.'),
    (v_loser, 'Challenge result: lost', 'The ' || c.mode || ' challenge against ' || public._challenge_name(p_winner) || ' went to them. Better luck next time!');
end;
$$;

create or replace function public._challenge_refund(p_id uuid, p_new_status text, p_resolution text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.challenges;
begin
  update public.challenges set status = p_new_status, resolution = p_resolution, resolved_at = now()
    where id = p_id and status in ('open','accepted','disputed')
    returning * into c;
  if c.id is null then
    raise exception 'This challenge is already settled.';
  end if;
  perform public._wallet_apply(c.creator, c.stake, 'challenge_refund', c.id::text, c.mode || ' challenge');
  insert into public.notifications (player_id, title, body) values (c.creator, 'Challenge refunded: +' || c.stake || ' points', 'Your ' || c.mode || ' challenge stake was returned (' || p_resolution || ').');
  if c.opponent is not null and c.accepted_at is not null then
    perform public._wallet_apply(c.opponent, c.stake, 'challenge_refund', c.id::text, c.mode || ' challenge');
    insert into public.notifications (player_id, title, body) values (c.opponent, 'Challenge refunded: +' || c.stake || ' points', 'Your ' || c.mode || ' challenge stake was returned (' || p_resolution || ').');
  end if;
end;
$$;

-- ── player actions ──
create or replace function public.confirm_adult()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  update public.players set adult_confirmed_at = coalesce(adult_confirmed_at, now()) where id = auth.uid();
end;
$$;

create or replace function public.get_open_challenges()
returns table(id uuid, mode text, stake int, note text, creator_name text, created_at timestamptz, for_me boolean, mine boolean)
language sql stable security definer set search_path = public as $$
  select c.id, c.mode, c.stake, c.note, public._challenge_name(c.creator), c.created_at,
         c.invited is not null and c.invited = auth.uid(), c.creator = auth.uid()
  from public.challenges c
  where c.status = 'open' and (c.invited is null or c.invited = auth.uid() or c.creator = auth.uid())
  order by (c.invited = auth.uid()) desc nulls last, c.created_at desc
  limit 60
$$;

create or replace function public.create_challenge(p_mode text, p_stake int, p_invite text default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_inv uuid; v_id uuid;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform public._challenge_player_ok(auth.uid());
  if p_mode not in ('1v1','2v2','3v3','4v4') then raise exception 'Pick a mode: 1v1, 2v2, 3v3 or 4v4.'; end if;
  if p_stake is null or p_stake < 10 or p_stake > 500 then raise exception 'Stake must be between 10 and 500 points.'; end if;
  if (select count(*) from public.challenges where creator = auth.uid() and status = 'open') >= 3 then
    raise exception 'You already have 3 open challenges. Cancel one or wait for them to be accepted.';
  end if;
  p_invite := nullif(trim(regexp_replace(coalesce(p_invite, ''), '^@', '')), '');
  if p_invite is not null then
    select id into v_inv from public.players where lower(username) = lower(p_invite) or upper(player_tag) = upper(p_invite) limit 1;
    if v_inv is null then raise exception 'No player called %.', p_invite; end if;
    if v_inv = auth.uid() then raise exception 'You can''t challenge yourself.'; end if;
  end if;
  insert into public.challenges (creator, invited, mode, stake, note)
  values (auth.uid(), v_inv, p_mode, p_stake, nullif(trim(coalesce(p_note, '')), ''))
  returning id into v_id;
  perform public._wallet_apply(auth.uid(), -p_stake, 'challenge_stake', v_id::text, p_mode || ' challenge');
  if v_inv is not null then
    insert into public.notifications (player_id, title, body)
    values (v_inv, '⚔️ ' || public._challenge_name(auth.uid()) || ' challenged you', p_mode || ' Clash Squad for ' || p_stake || ' points each — winner takes ' || p_stake * 2 || '. Open Challenges to accept.');
  end if;
  return v_id;
end;
$$;

create or replace function public.accept_challenge(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c public.challenges;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform public._challenge_player_ok(auth.uid());
  update public.challenges set opponent = auth.uid(), status = 'accepted', accepted_at = now()
    where id = p_id and status = 'open' and creator <> auth.uid() and (invited is null or invited = auth.uid())
    returning * into c;
  if c.id is null then
    raise exception 'This challenge is no longer available.';
  end if;
  perform public._wallet_apply(auth.uid(), -c.stake, 'challenge_stake', c.id::text, c.mode || ' challenge');
  insert into public.notifications (player_id, title, body)
  values (c.creator, '⚔️ Challenge accepted', public._challenge_name(auth.uid()) || ' accepted your ' || c.mode || ' challenge (' || c.stake * 2 || ' points pot). Open Challenges to share the room and chat.');
end;
$$;

create or replace function public.cancel_challenge(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if not exists(select 1 from public.challenges where id = p_id and creator = auth.uid() and status = 'open') then
    raise exception 'Only an open challenge you created can be cancelled.';
  end if;
  perform public._challenge_refund(p_id, 'cancelled', 'cancelled by creator');
end;
$$;

create or replace function public.set_challenge_room(p_id uuid, p_room_id text, p_room_pass text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.challenges set room_id = nullif(trim(p_room_id), ''), room_pass = nullif(trim(p_room_pass), '')
    where id = p_id and status = 'accepted' and auth.uid() in (creator, opponent);
  if not found then raise exception 'You can only set the room for an accepted challenge you''re in.'; end if;
end;
$$;

create or replace function public.report_challenge(p_id uuid, p_result text)
returns text language plpgsql security definer set search_path = public as $$
declare c public.challenges; v_me_creator boolean; v_other uuid; v_mine text; v_theirs text;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_result not in ('won','lost') then raise exception 'Report won or lost.'; end if;
  select * into c from public.challenges where id = p_id for update;
  if c.id is null or auth.uid() not in (c.creator, c.opponent) then raise exception 'Challenge not found.'; end if;
  if c.status <> 'accepted' then raise exception 'This challenge isn''t waiting for a result.'; end if;
  v_me_creator := auth.uid() = c.creator;
  v_other := case when v_me_creator then c.opponent else c.creator end;
  if (v_me_creator and c.creator_claim is not null) or (not v_me_creator and c.opponent_claim is not null) then
    raise exception 'You already reported this result.';
  end if;
  if v_me_creator then
    update public.challenges set creator_claim = p_result, claim_at = coalesce(claim_at, now()) where id = p_id returning * into c;
  else
    update public.challenges set opponent_claim = p_result, claim_at = coalesce(claim_at, now()) where id = p_id returning * into c;
  end if;
  v_mine := p_result;
  v_theirs := case when v_me_creator then c.opponent_claim else c.creator_claim end;

  if v_mine = 'lost' and (v_theirs is null or v_theirs = 'won') then
    perform public._challenge_payout(p_id, v_other, 'loser confirmed');
    return 'completed';
  end if;
  if v_mine = 'won' and v_theirs = 'lost' then
    perform public._challenge_payout(p_id, auth.uid(), 'both agreed');
    return 'completed';
  end if;
  if v_theirs is not null then
    update public.challenges set status = 'disputed' where id = p_id;
    insert into public.notifications (player_id, title, body)
    select id, '⚖️ Challenge disputed', 'Both sides reported the same result on a ' || c.mode || ' challenge (' || c.stake * 2 || ' pts). Review it in Admin → Challenges.'
    from public.players where lower(email) = 'ayerprabin95@gmail.com';
    insert into public.notifications (player_id, title, body) values
      (c.creator, 'Challenge under review', 'The results don''t match, so the admin will decide. Keep your screenshots and share them in the challenge chat.'),
      (c.opponent, 'Challenge under review', 'The results don''t match, so the admin will decide. Keep your screenshots and share them in the challenge chat.');
    return 'disputed';
  end if;
  insert into public.notifications (player_id, title, body)
  values (v_other, '⚔️ Confirm your challenge result', public._challenge_name(auth.uid()) || ' says they won the ' || c.mode || ' challenge. Confirm or dispute within 2 hours — after that they win automatically.');
  return 'waiting';
end;
$$;

create or replace function public.send_challenge_message(p_id uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  p_body := trim(coalesce(p_body, ''));
  if length(p_body) < 1 or length(p_body) > 300 then raise exception 'Messages must be 1-300 characters.'; end if;
  if not exists(select 1 from public.challenges where id = p_id and auth.uid() in (creator, opponent) and status in ('accepted','disputed','completed')) then
    raise exception 'Chat opens once the challenge is accepted.';
  end if;
  if (select count(*) from public.challenge_messages where sender = auth.uid() and created_at > now() - interval '10 seconds') >= 5 then
    raise exception 'Slow down a little.';
  end if;
  insert into public.challenge_messages (challenge_id, sender, body) values (p_id, auth.uid(), p_body);
end;
$$;

-- ── timeouts (cron every 5 min) ──
create or replace function public.challenge_sweep()
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; n_exp int := 0; n_claim int := 0; n_ref int := 0;
begin
  if exists(select 1 from public.system_state where id = 1 and locked) then
    return jsonb_build_object('skipped', 'locked');
  end if;
  for r in select id from public.challenges where status = 'open' and created_at < now() - interval '24 hours' loop
    perform public._challenge_refund(r.id, 'expired', 'nobody accepted within 24 hours'); n_exp := n_exp + 1;
  end loop;
  for r in select id, creator, opponent, creator_claim, opponent_claim from public.challenges
           where status = 'accepted' and claim_at < now() - interval '2 hours'
             and ((creator_claim = 'won' and opponent_claim is null) or (opponent_claim = 'won' and creator_claim is null)) loop
    perform public._challenge_payout(r.id, case when r.creator_claim = 'won' then r.creator else r.opponent end, 'no response within 2 hours'); n_claim := n_claim + 1;
  end loop;
  for r in select id from public.challenges where status = 'accepted' and claim_at is null and accepted_at < now() - interval '12 hours' loop
    perform public._challenge_refund(r.id, 'refunded', 'no result reported within 12 hours'); n_ref := n_ref + 1;
  end loop;
  return jsonb_build_object('expired', n_exp, 'claims_paid', n_claim, 'refunded', n_ref);
end;
$$;

create or replace function public.admin_resolve_challenge(p_id uuid, p_outcome text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.challenges;
begin
  select * into c from public.challenges where id = p_id;
  if c.id is null then raise exception 'Challenge not found.'; end if;
  if p_outcome = 'creator' then perform public._challenge_payout(p_id, c.creator, 'decided by admin');
  elsif p_outcome = 'opponent' then perform public._challenge_payout(p_id, c.opponent, 'decided by admin');
  elsif p_outcome = 'refund' then perform public._challenge_refund(p_id, 'refunded', 'refunded by admin');
  else raise exception 'Outcome must be creator, opponent or refund.';
  end if;
end;
$$;

-- ── who can call what ──
revoke all on function public._challenge_player_ok(uuid) from public, anon, authenticated;
revoke all on function public._challenge_name(uuid) from public, anon, authenticated;
revoke all on function public._challenge_payout(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public._challenge_refund(uuid, text, text) from public, anon, authenticated;
revoke all on function public.challenge_sweep() from public, anon, authenticated;
revoke all on function public.admin_resolve_challenge(uuid, text) from public, anon, authenticated;
grant execute on function public.challenge_sweep() to service_role;
grant execute on function public.admin_resolve_challenge(uuid, text) to service_role;
revoke all on function public.confirm_adult() from public, anon;
revoke all on function public.get_open_challenges() from public, anon;
revoke all on function public.create_challenge(text, int, text, text) from public, anon;
revoke all on function public.accept_challenge(uuid) from public, anon;
revoke all on function public.cancel_challenge(uuid) from public, anon;
revoke all on function public.set_challenge_room(uuid, text, text) from public, anon;
revoke all on function public.report_challenge(uuid, text) from public, anon;
revoke all on function public.send_challenge_message(uuid, text) from public, anon;
grant execute on function public.confirm_adult() to authenticated;
grant execute on function public.get_open_challenges() to authenticated;
grant execute on function public.create_challenge(text, int, text, text) to authenticated;
grant execute on function public.accept_challenge(uuid) to authenticated;
grant execute on function public.cancel_challenge(uuid) to authenticated;
grant execute on function public.set_challenge_room(uuid, text, text) to authenticated;
grant execute on function public.report_challenge(uuid, text) to authenticated;
grant execute on function public.send_challenge_message(uuid, text) to authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'challenge-sweep';
select cron.schedule('challenge-sweep', '*/5 * * * *', 'select public.challenge_sweep()');
commit;

-- display names for the other players in your own challenges (nothing else)
begin;
create or replace function public.get_challenge_names(p_ids uuid[])
returns table(id uuid, name text) language sql stable security definer set search_path = public as $$
  select p.id, coalesce('@' || p.username, p.player_tag, 'Player')
  from public.players p
  where p.id = any(p_ids)
    and exists(select 1 from public.challenges c
               where auth.uid() in (c.creator, c.opponent, c.invited)
                 and p.id in (c.creator, c.opponent, c.invited))
$$;
revoke all on function public.get_challenge_names(uuid[]) from public, anon;
grant execute on function public.get_challenge_names(uuid[]) to authenticated;
commit;

-- ── challenges: flat 1-point platform fee per player + effects in the lobby/room ──
-- The pot a winner receives is 2 × stake − 2 × challenge_fee_per_player() (1 point from
-- each player). The fee only applies to a match that is actually settled — cancelled,
-- expired and refunded challenges return the full stakes.
begin;
create or replace function public.challenge_fee_per_player() returns int language sql immutable as $$ select 1 $$;
drop function if exists public.challenge_fee_pct();

create or replace function public._challenge_payout(p_id uuid, p_winner uuid, p_resolution text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.challenges; v_pot int; v_loser uuid;
begin
  update public.challenges set status = 'completed', winner = p_winner, resolution = p_resolution, resolved_at = now()
    where id = p_id and status in ('accepted','disputed') and p_winner in (creator, opponent)
    returning * into c;
  if c.id is null then
    raise exception 'This challenge is already settled.';
  end if;
  v_pot := c.stake * 2 - 2 * public.challenge_fee_per_player();
  perform public._wallet_apply(p_winner, v_pot, 'challenge_win', c.id::text, c.mode || ' challenge');
  v_loser := case when p_winner = c.creator then c.opponent else c.creator end;
  insert into public.notifications (player_id, title, body) values
    (p_winner, '🏆 Challenge won: +' || v_pot || ' JD points', 'You won the ' || c.mode || ' challenge against ' || public._challenge_name(v_loser) || '. ' || v_pot || ' points are in your wallet.'),
    (v_loser, 'Challenge result: lost', 'The ' || c.mode || ' challenge against ' || public._challenge_name(p_winner) || ' went to them. Better luck next time!');
end;
$$;
revoke all on function public._challenge_payout(uuid, uuid, text) from public, anon, authenticated;

-- a player's active squad effect (from their pass), for showing on challenge cards
create or replace function public._active_effect(p_player uuid)
returns text language sql stable security definer set search_path = public as $$
  select effect from public.effect_passes
  where player_id = p_player and starts_at <= now() and expires_at > now()
  order by expires_at asc limit 1
$$;
revoke all on function public._active_effect(uuid) from public, anon, authenticated;

drop function if exists public.get_open_challenges();
create function public.get_open_challenges()
returns table(id uuid, mode text, stake int, note text, creator_name text, created_at timestamptz, for_me boolean, mine boolean, creator_effect text)
language sql stable security definer set search_path = public as $$
  select c.id, c.mode, c.stake, c.note, public._challenge_name(c.creator), c.created_at,
         c.invited is not null and c.invited = auth.uid(), c.creator = auth.uid(), public._active_effect(c.creator)
  from public.challenges c
  where c.status = 'open' and (c.invited is null or c.invited = auth.uid() or c.creator = auth.uid())
  order by (c.invited = auth.uid()) desc nulls last, c.created_at desc
  limit 60
$$;
revoke all on function public.get_open_challenges() from public, anon;
grant execute on function public.get_open_challenges() to authenticated;

drop function if exists public.get_challenge_names(uuid[]);
create function public.get_challenge_names(p_ids uuid[])
returns table(id uuid, name text, effect text) language sql stable security definer set search_path = public as $$
  select p.id, coalesce('@' || p.username, p.player_tag, 'Player'), public._active_effect(p.id)
  from public.players p
  where p.id = any(p_ids)
    and exists(select 1 from public.challenges c
               where auth.uid() in (c.creator, c.opponent, c.invited)
                 and p.id in (c.creator, c.opponent, c.invited))
$$;
revoke all on function public.get_challenge_names(uuid[]) from public, anon;
grant execute on function public.get_challenge_names(uuid[]) to authenticated;
commit;

-- challenge-broadcast: records that a new open challenge was announced to everyone (once)
alter table public.challenges add column if not exists broadcast_at timestamptz;

-- one "new tournament" announcement per tournament (sent by publish-tournaments)
begin;
create table if not exists public.tournament_announcements (
  tournament_slug text primary key,
  announced_at timestamptz not null default now()
);
alter table public.tournament_announcements enable row level security; -- service role only
-- everything already published counts as announced, so nothing is re-sent now
insert into public.tournament_announcements (tournament_slug)
select t->>'name' from public.site_content, jsonb_array_elements(content->'tournaments') t
where key = 'tournaments' and t->>'name' is not null
on conflict do nothing;
commit;

-- ── native Web Push (VAPID) subscriptions ────────────────────────────────
-- One row per browser/device. Players never read this table; they save or remove their
-- own device through the RPCs below. Senders use the service role (_shared/push.ts).
begin;
create table if not exists public.push_subscriptions (
  endpoint text primary key,
  player_id uuid not null references public.players(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_ok_at timestamptz
);
create index if not exists push_subscriptions_player on public.push_subscriptions(player_id);
alter table public.push_subscriptions enable row level security; -- no policies: RPC/service role only

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_ua text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or length(coalesce(p_p256dh,'')) not between 40 and 200 or length(coalesce(p_auth,'')) not between 10 and 100 then
    raise exception 'Invalid push subscription.';
  end if;
  -- upsert on endpoint: the same device signing in as someone else moves to that player
  insert into public.push_subscriptions (endpoint, player_id, p256dh, auth, user_agent)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth, left(p_ua, 200))
  on conflict (endpoint) do update set player_id = excluded.player_id, p256dh = excluded.p256dh, auth = excluded.auth, user_agent = excluded.user_agent;
  -- keep at most 10 devices per player
  delete from public.push_subscriptions where player_id = auth.uid() and endpoint not in
    (select endpoint from public.push_subscriptions where player_id = auth.uid() order by created_at desc limit 10);
end;
$$;

create or replace function public.delete_push_subscription(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and player_id = auth.uid()
$$;

create or replace function public.my_push_devices() returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.push_subscriptions where player_id = auth.uid()
$$;

revoke all on function public.save_push_subscription(text, text, text, text) from public, anon;
revoke all on function public.delete_push_subscription(text) from public, anon;
revoke all on function public.my_push_devices() from public, anon;
grant execute on function public.save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.delete_push_subscription(text) to authenticated;
grant execute on function public.my_push_devices() to authenticated;
commit;

-- ── push every saved notification ─────────────────────────────────────────
-- Notifications written by SQL (tickets, entry confirmations, wallet credits, prizes,
-- challenge invites/results, waitlist, security alerts) used to appear only inside the app.
-- This trigger hands each new row to the push-notifications Edge Function (pg_net, same
-- vault secrets as the cron jobs), which sends it as a Web Push so it shows on the device
-- even when JD Arena is closed. Edge Functions that push their own alert (room codes,
-- results, reminders, announcements, challenge broadcasts) insert with push = false.
-- A failed hand-off never blocks the insert — the row still lands in Notification History.
begin;
alter table public.notifications add column if not exists push boolean not null default true;

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
      body := jsonb_build_object('ids', to_jsonb(v_ids))
    );
  exception when others then
    raise warning 'notifications_push: %', sqlerrm;
  end;
  return null;
end;
$$;
revoke all on function public.notifications_push() from public, anon, authenticated;

drop trigger if exists notifications_push on public.notifications;
create trigger notifications_push after insert on public.notifications
  referencing new table as new_rows for each statement execute function public.notifications_push();
commit;

-- ── challenges: Clash Squad room settings + daily challenge reminder ──────────
-- The creator picks the custom-room rules both sides must use: character skills on/off,
-- gun attributes (weapon-skin stat bonuses) on/off, limited/unlimited ammo, rounds and
-- map. They're shown on the lobby card, in the room and in the broadcast alert, so the
-- opponent knows exactly what they're accepting. New create_challenge parameters all have
-- defaults, so older copies of the page keep working. Idempotent.
begin;
alter table public.challenges add column if not exists char_skill boolean not null default true;
alter table public.challenges add column if not exists gun_attr boolean not null default false;
alter table public.challenges add column if not exists ammo text not null default 'limited';
alter table public.challenges add column if not exists rounds int not null default 7;
alter table public.challenges add column if not exists map text;
alter table public.challenges drop constraint if exists challenges_ammo_check;
alter table public.challenges add constraint challenges_ammo_check check (ammo in ('limited','unlimited'));
alter table public.challenges drop constraint if exists challenges_rounds_check;
alter table public.challenges add constraint challenges_rounds_check check (rounds in (7,13));
alter table public.challenges drop constraint if exists challenges_map_check;
alter table public.challenges add constraint challenges_map_check check (map is null or map in ('Bermuda','Purgatory','Kalahari','Alpine','NeXTerra'));

-- one-line summary of a challenge's room rules, used in notifications
create or replace function public._challenge_rules(c public.challenges)
returns text language sql immutable as $$
  select 'Skills ' || case when c.char_skill then 'on' else 'off' end
      || ' · Gun attributes ' || case when c.gun_attr then 'on' else 'off' end
      || ' · ' || case when c.ammo = 'unlimited' then 'Unlimited' else 'Limited' end || ' ammo'
      || ' · ' || case when c.rounds = 13 then 'First to 7' else 'First to 4' end
      || coalesce(' · ' || c.map, '')
$$;
revoke all on function public._challenge_rules(public.challenges) from public, anon, authenticated;

drop function if exists public.create_challenge(text, int, text, text);
create or replace function public.create_challenge(p_mode text, p_stake int, p_invite text default null, p_note text default null,
  p_char_skill boolean default true, p_gun_attr boolean default false, p_ammo text default 'limited', p_rounds int default 7, p_map text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_inv uuid; c public.challenges;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform public._challenge_player_ok(auth.uid());
  if p_mode not in ('1v1','2v2','3v3','4v4') then raise exception 'Pick a mode: 1v1, 2v2, 3v3 or 4v4.'; end if;
  if p_stake is null or p_stake < 10 or p_stake > 500 then raise exception 'Stake must be between 10 and 500 points.'; end if;
  if coalesce(p_ammo, 'limited') not in ('limited','unlimited') then raise exception 'Ammo must be limited or unlimited.'; end if;
  if coalesce(p_rounds, 7) not in (7, 13) then raise exception 'Rounds must be first to 4 or first to 7.'; end if;
  p_map := nullif(trim(coalesce(p_map, '')), '');
  if p_map is not null and p_map not in ('Bermuda','Purgatory','Kalahari','Alpine','NeXTerra') then raise exception 'Unknown map.'; end if;
  if (select count(*) from public.challenges where creator = auth.uid() and status = 'open') >= 3 then
    raise exception 'You already have 3 open challenges. Cancel one or wait for them to be accepted.';
  end if;
  p_invite := nullif(trim(regexp_replace(coalesce(p_invite, ''), '^@', '')), '');
  if p_invite is not null then
    select id into v_inv from public.players where lower(username) = lower(p_invite) or upper(player_tag) = upper(p_invite) limit 1;
    if v_inv is null then raise exception 'No player called %.', p_invite; end if;
    if v_inv = auth.uid() then raise exception 'You can''t challenge yourself.'; end if;
  end if;
  insert into public.challenges (creator, invited, mode, stake, note, char_skill, gun_attr, ammo, rounds, map)
  values (auth.uid(), v_inv, p_mode, p_stake, nullif(trim(coalesce(p_note, '')), ''),
          coalesce(p_char_skill, true), coalesce(p_gun_attr, false), coalesce(p_ammo, 'limited'), coalesce(p_rounds, 7), p_map)
  returning * into c;
  perform public._wallet_apply(auth.uid(), -p_stake, 'challenge_stake', c.id::text, p_mode || ' challenge');
  if v_inv is not null then
    insert into public.notifications (player_id, title, body)
    values (v_inv, '⚔️ ' || public._challenge_name(auth.uid()) || ' challenged you',
      p_mode || ' Clash Squad for ' || p_stake || ' points each — winner takes ' || (p_stake * 2 - 2 * public.challenge_fee_per_player()) || '. ' || public._challenge_rules(c) || '. Open Challenges to accept.');
  end if;
  return c.id;
end;
$$;
revoke all on function public.create_challenge(text, int, text, text, boolean, boolean, text, int, text) from public, anon;
grant execute on function public.create_challenge(text, int, text, text, boolean, boolean, text, int, text) to authenticated;

drop function if exists public.get_open_challenges();
create function public.get_open_challenges()
returns table(id uuid, mode text, stake int, note text, creator_name text, created_at timestamptz, for_me boolean, mine boolean, creator_effect text,
              char_skill boolean, gun_attr boolean, ammo text, rounds int, map text)
language sql stable security definer set search_path = public as $$
  select c.id, c.mode, c.stake, c.note, public._challenge_name(c.creator), c.created_at,
         c.invited is not null and c.invited = auth.uid(), c.creator = auth.uid(), public._active_effect(c.creator),
         c.char_skill, c.gun_attr, c.ammo, c.rounds, c.map
  from public.challenges c
  where c.status = 'open' and (c.invited is null or c.invited = auth.uid() or c.creator = auth.uid())
  order by (c.invited = auth.uid()) desc nulls last, c.created_at desc
  limit 60
$$;
revoke all on function public.get_open_challenges() from public, anon;
grant execute on function public.get_open_challenges() to authenticated;

-- ── daily challenge reminder ──
-- Once a day (18:00 Nepal time) every 18+-confirmed player who hasn't turned it off and hasn't already
-- played a challenge today gets one short alert — a notification row with push = true,
-- so the notifications_push trigger also sends it to their phone/desktop. The title says
-- "challenge", so tapping it opens /challenges/. challenge_daily_log makes it once-per-day
-- even if the job is re-run or triggered by hand.
alter table public.players add column if not exists daily_challenge_alert boolean not null default true;

create table if not exists public.challenge_daily_log (
  day date primary key,
  sent int not null default 0,
  sent_at timestamptz not null default now()
);
alter table public.challenge_daily_log enable row level security; -- service role only

create or replace function public.challenge_daily_reminder()
returns int language plpgsql security definer set search_path = public as $$
declare v_day date := (now() at time zone 'Asia/Kathmandu')::date; v_open int; v_top int; v_pot int; v_body text; v_n int;
begin
  insert into public.challenge_daily_log (day) values (v_day) on conflict do nothing;
  if not found then return 0; end if; -- already sent today
  select count(*), coalesce(max(stake), 0) into v_open, v_top from public.challenges where status = 'open' and invited is null;
  v_pot := v_top * 2 - 2 * public.challenge_fee_per_player();
  v_body := case
    when v_open = 1 then '1 open Clash Squad challenge is waiting — winner takes ' || v_pot || ' points. Tap to accept it.'
    when v_open > 1 then v_open || ' open Clash Squad challenges are waiting — biggest pot ' || v_pot || ' points. Tap to pick one.'
    else 'The lobby is empty — post a 1v1 and be the first. You pick skills, gun attributes and ammo; winner takes the pot.'
  end;
  insert into public.notifications (player_id, title, body)
  select p.id, '⚔️ Daily challenge time', v_body from public.players p
  where p.daily_challenge_alert
    and p.adult_confirmed_at is not null -- challenges are 18+: never nudge anyone who hasn't confirmed
    and not exists(select 1 from public.banned_players b where b.player_id = p.id)
    and not exists(select 1 from public.challenges c where p.id in (c.creator, c.opponent)
                   and c.created_at >= (v_day::timestamp at time zone 'Asia/Kathmandu'));
  get diagnostics v_n = row_count;
  update public.challenge_daily_log set sent = v_n where day = v_day;
  return v_n;
end;
$$;
revoke all on function public.challenge_daily_reminder() from public, anon, authenticated;

create or replace function public.set_daily_challenge_alert(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  update public.players set daily_challenge_alert = coalesce(p_on, true) where id = auth.uid();
end;
$$;
revoke all on function public.set_daily_challenge_alert(boolean) from public, anon;
grant execute on function public.set_daily_challenge_alert(boolean) to authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'challenge-daily-reminder';
select cron.schedule('challenge-daily-reminder', '15 12 * * *', 'select public.challenge_daily_reminder()'); -- 12:15 UTC = 18:00 Nepal
commit;

-- ── challenges: gloo wall room setting ────────────────────────────────────────
-- The creator also picks limited or unlimited gloo walls. Shown with the other room
-- rules (lobby card, room, notifications). create_challenge gets a p_gloo parameter with
-- a default, so older copies of the page keep working. Idempotent.
begin;
alter table public.challenges add column if not exists gloo_wall text not null default 'limited';
alter table public.challenges drop constraint if exists challenges_gloo_wall_check;
alter table public.challenges add constraint challenges_gloo_wall_check check (gloo_wall in ('limited','unlimited'));

create or replace function public._challenge_rules(c public.challenges)
returns text language sql immutable as $$
  select 'Skills ' || case when c.char_skill then 'on' else 'off' end
      || ' · Gun attributes ' || case when c.gun_attr then 'on' else 'off' end
      || ' · ' || case when c.ammo = 'unlimited' then 'Unlimited' else 'Limited' end || ' ammo'
      || ' · ' || case when c.gloo_wall = 'unlimited' then 'Unlimited' else 'Limited' end || ' gloo walls'
      || ' · ' || case when c.rounds = 13 then 'First to 7' else 'First to 4' end
      || coalesce(' · ' || c.map, '')
$$;
revoke all on function public._challenge_rules(public.challenges) from public, anon, authenticated;

drop function if exists public.create_challenge(text, int, text, text, boolean, boolean, text, int, text);
create or replace function public.create_challenge(p_mode text, p_stake int, p_invite text default null, p_note text default null,
  p_char_skill boolean default true, p_gun_attr boolean default false, p_ammo text default 'limited', p_rounds int default 7, p_map text default null,
  p_gloo text default 'limited')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_inv uuid; c public.challenges;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform public._challenge_player_ok(auth.uid());
  if p_mode not in ('1v1','2v2','3v3','4v4') then raise exception 'Pick a mode: 1v1, 2v2, 3v3 or 4v4.'; end if;
  if p_stake is null or p_stake < 10 or p_stake > 500 then raise exception 'Stake must be between 10 and 500 points.'; end if;
  if coalesce(p_ammo, 'limited') not in ('limited','unlimited') then raise exception 'Ammo must be limited or unlimited.'; end if;
  if coalesce(p_gloo, 'limited') not in ('limited','unlimited') then raise exception 'Gloo walls must be limited or unlimited.'; end if;
  if coalesce(p_rounds, 7) not in (7, 13) then raise exception 'Rounds must be first to 4 or first to 7.'; end if;
  p_map := nullif(trim(coalesce(p_map, '')), '');
  if p_map is not null and p_map not in ('Bermuda','Purgatory','Kalahari','Alpine','NeXTerra') then raise exception 'Unknown map.'; end if;
  if (select count(*) from public.challenges where creator = auth.uid() and status = 'open') >= 3 then
    raise exception 'You already have 3 open challenges. Cancel one or wait for them to be accepted.';
  end if;
  p_invite := nullif(trim(regexp_replace(coalesce(p_invite, ''), '^@', '')), '');
  if p_invite is not null then
    select id into v_inv from public.players where lower(username) = lower(p_invite) or upper(player_tag) = upper(p_invite) limit 1;
    if v_inv is null then raise exception 'No player called %.', p_invite; end if;
    if v_inv = auth.uid() then raise exception 'You can''t challenge yourself.'; end if;
  end if;
  insert into public.challenges (creator, invited, mode, stake, note, char_skill, gun_attr, ammo, rounds, map, gloo_wall)
  values (auth.uid(), v_inv, p_mode, p_stake, nullif(trim(coalesce(p_note, '')), ''),
          coalesce(p_char_skill, true), coalesce(p_gun_attr, false), coalesce(p_ammo, 'limited'), coalesce(p_rounds, 7), p_map,
          coalesce(p_gloo, 'limited'))
  returning * into c;
  perform public._wallet_apply(auth.uid(), -p_stake, 'challenge_stake', c.id::text, p_mode || ' challenge');
  if v_inv is not null then
    insert into public.notifications (player_id, title, body)
    values (v_inv, '⚔️ ' || public._challenge_name(auth.uid()) || ' challenged you',
      p_mode || ' Clash Squad for ' || p_stake || ' points each — winner takes ' || (p_stake * 2 - 2 * public.challenge_fee_per_player()) || '. ' || public._challenge_rules(c) || '. Open Challenges to accept.');
  end if;
  return c.id;
end;
$$;
revoke all on function public.create_challenge(text, int, text, text, boolean, boolean, text, int, text, text) from public, anon;
grant execute on function public.create_challenge(text, int, text, text, boolean, boolean, text, int, text, text) to authenticated;

drop function if exists public.get_open_challenges();
create function public.get_open_challenges()
returns table(id uuid, mode text, stake int, note text, creator_name text, created_at timestamptz, for_me boolean, mine boolean, creator_effect text,
              char_skill boolean, gun_attr boolean, ammo text, rounds int, map text, gloo_wall text)
language sql stable security definer set search_path = public as $$
  select c.id, c.mode, c.stake, c.note, public._challenge_name(c.creator), c.created_at,
         c.invited is not null and c.invited = auth.uid(), c.creator = auth.uid(), public._active_effect(c.creator),
         c.char_skill, c.gun_attr, c.ammo, c.rounds, c.map, c.gloo_wall
  from public.challenges c
  where c.status = 'open' and (c.invited is null or c.invited = auth.uid() or c.creator = auth.uid())
  order by (c.invited = auth.uid()) desc nulls last, c.created_at desc
  limit 60
$$;
revoke all on function public.get_open_challenges() from public, anon;
grant execute on function public.get_open_challenges() to authenticated;
commit;

-- ── all-time homepage counters ───────────────────────────────────────────────
-- The "Tournaments" and "Squads Registered" stats used to count only what's in
-- tournaments.json right now, so they dropped every time an old event was removed.
-- get_arena_totals() gives every event ever seen (registrations + archived results)
-- with how many squads signed up for it (confirmed, approved or no-show — rejected,
-- pending and waitlisted don't count). Only slugs and counts, nothing personal. Idempotent.
begin;
create or replace function public.get_arena_totals()
returns table(tournament_slug text, squads int)
language sql stable security definer set search_path = public as $$
  select s.slug, coalesce(r.n, 0)::int
  from (select tournament_slug slug from public.registrations
        union select tournament_slug from public.tournament_results) s
  left join (select tournament_slug, count(*) n from public.registrations
             where status in ('confirmed','approved','no_show') group by tournament_slug) r
    on r.tournament_slug = s.slug
$$;
revoke all on function public.get_arena_totals() from public;
grant execute on function public.get_arena_totals() to anon, authenticated;
commit;

-- ── homepage: players + challenges played counters ───────────────────────────
-- Two more all-time numbers for the hero stats card, next to get_arena_totals().
-- Counts only, nothing personal; readable by visitors who aren't signed in. Idempotent.
begin;
create or replace function public.get_arena_stats()
returns table(players int, challenges int)
language sql stable security definer set search_path = public as $$
  select (select count(*) from public.players)::int,
         (select count(*) from public.challenges where status = 'completed')::int
$$;
revoke all on function public.get_arena_stats() from public;
grant execute on function public.get_arena_stats() to anon, authenticated;
commit;

-- Optional WhatsApp number per registration, for a reminder text before the match.
-- Per registration (not the profile): players opt in for that one event. Only the owner
-- (players read own registration) and the admin (list-registrations, service role) see it —
-- get_public_roster() never returns it.
begin;
alter table public.registrations add column if not exists whatsapp text;
create or replace function public.set_registration_whatsapp(p_reg_id uuid, p_whatsapp text)
returns text language plpgsql security definer set search_path = public as $$
declare v text := regexp_replace(coalesce(p_whatsapp, ''), '[\s\-().]', '', 'g');
begin
  if v = '' then v := null;
  elsif v !~ '^\+?[0-9]{7,15}$' then
    raise exception 'Enter a valid WhatsApp number with country code, e.g. +977 98XXXXXXXX.';
  end if;
  update public.registrations set whatsapp = v where id = p_reg_id and player_id = auth.uid();
  if not found then raise exception 'Registration not found.'; end if;
  return v;
end;
$$;
revoke all on function public.set_registration_whatsapp(uuid, text) from public, anon;
grant execute on function public.set_registration_whatsapp(uuid, text) to authenticated;
commit;
