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
