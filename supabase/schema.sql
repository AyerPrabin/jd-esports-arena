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

-- ── AI review: online, every 30 minutes ───────────────────────────────────────
-- Calls the ai-review Edge Function (advisory recommendations only; see its header).
-- It is deployed with JWT verification on, so the call carries the service-role JWT
-- stored in Vault as 'service_role_key' (plus cron_secret, which the function checks).
-- timeout 150s: a run stops starting new council votes after ~85s by itself.
begin;
create or replace function public.ai_review_sweep()
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/ai-review',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key'),
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000
  ) into v_id;
  return v_id;
end;
$$;
revoke all on function public.ai_review_sweep() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'ai-review-sweep';
select cron.schedule('ai-review-sweep', '7,37 * * * *', 'select public.ai_review_sweep()');
commit;

-- ── check-in opens 12 hours before start; points loads need a screenshot ──
-- * check_in_for_tournament(): refuses a check-in earlier than 12 hours before the start
--   (no start time published -> allowed, as before).
-- * wallet_load_requests: a player asks for points by uploading the eSewa screenshot on
--   /wallet/ (request_wallet_load). The admin approves it in Admin -> Points (wallet-admin
--   resolve_load -> admin_wallet_credit with ref LOAD-<id>, so one request can only ever be
--   credited once) or rejects it. Replaces "send the screenshot on WhatsApp".
begin;

create or replace function public.check_in_for_tournament(p_tournament_slug text)
returns public.registrations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.registrations;
  v_start timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Not signed in';
  end if;

  v_start := public.tournament_start_at(p_tournament_slug);
  if v_start is not null and v_start - now() > interval '12 hours' then
    raise exception 'Check-in opens 12 hours before the match starts.';
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

create table if not exists public.wallet_load_requests (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  amount int not null check (amount between 1 and 100000),
  screenshot text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz
);
create index if not exists wallet_load_requests_player on public.wallet_load_requests(player_id, created_at desc);
create index if not exists wallet_load_requests_pending on public.wallet_load_requests(created_at) where status = 'pending';
alter table public.wallet_load_requests enable row level security;
drop policy if exists "players read own load requests" on public.wallet_load_requests;
create policy "players read own load requests" on public.wallet_load_requests
  for select using (auth.uid() = player_id);
-- no insert/update policies: inserts only via request_wallet_load(), reviews only via wallet-admin

create or replace function public.request_wallet_load(p_amount int, p_screenshot text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  perform public._assert_open();
  if p_amount is null or p_amount < 1 or p_amount > 100000 then
    raise exception 'Enter the amount you paid (1 to 100000).';
  end if;
  if p_screenshot is null or p_screenshot !~ '^data:image/(png|jpe?g|webp);base64,[A-Za-z0-9+/=]+$' then
    raise exception 'Please attach your eSewa payment screenshot.';
  end if;
  if length(p_screenshot) > 600000 then
    raise exception 'The screenshot is too large. Please upload a smaller image.';
  end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then
    raise exception 'Your account is banned.';
  end if;
  if (select count(*) from public.wallet_load_requests where player_id = auth.uid() and status = 'pending') >= 3 then
    raise exception 'You already have 3 payments waiting to be checked. Please wait for them first.';
  end if;
  insert into public.wallet_load_requests (player_id, amount, screenshot)
  values (auth.uid(), p_amount, p_screenshot)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'status', 'pending');
end;
$$;
revoke all on function public.request_wallet_load(int, text) from public, anon;
grant execute on function public.request_wallet_load(int, text) to authenticated;

-- admin: approve (credits points once) or reject a load request
create or replace function public.admin_resolve_load(p_id uuid, p_approve boolean, p_amount int default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_req public.wallet_load_requests;
  v_amount int;
  v_bal int;
begin
  select * into v_req from public.wallet_load_requests where id = p_id for update;
  if v_req.id is null then
    raise exception 'Request not found.';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'This request was already %.', v_req.status;
  end if;
  if p_approve then
    v_amount := coalesce(p_amount, v_req.amount);
    v_bal := public.admin_wallet_credit(v_req.player_id, v_amount, 'LOAD-' || v_req.id::text, coalesce(nullif(trim(p_note), ''), 'eSewa screenshot verified'));
    update public.wallet_load_requests set status = 'approved', amount = v_amount, note = nullif(trim(p_note), ''), reviewed_at = now() where id = p_id;
    return jsonb_build_object('status', 'approved', 'player_id', v_req.player_id, 'amount', v_amount, 'balance', v_bal);
  end if;
  update public.wallet_load_requests set status = 'rejected', note = nullif(trim(p_note), ''), reviewed_at = now() where id = p_id;
  insert into public.notifications (player_id, title, body)
  values (v_req.player_id, 'Points not added',
          'We could not verify your payment of Rs ' || v_req.amount || '.' ||
          coalesce(' Reason: ' || nullif(trim(p_note), ''), '') ||
          ' Check the screenshot and try again, or ask on Discord.');
  return jsonb_build_object('status', 'rejected', 'player_id', v_req.player_id, 'amount', v_req.amount);
end;
$$;
revoke all on function public.admin_resolve_load(uuid, boolean, int, text) from public, anon, authenticated;
grant execute on function public.admin_resolve_load(uuid, boolean, int, text) to service_role;

commit;

-- ── entries are points-only; admin is alerted to new payment screenshots ──
-- * redeem_code(): entry codes are refused (the raise rolls the code back to unused).
--   Effect codes keep working.
-- * request_wallet_load(): notifies the organiser's account (push via notifications_push)
--   so a screenshot waiting in Admin -> Points doesn't go unnoticed.
begin;

do $$
declare d text;
begin
  select pg_get_functiondef('public.redeem_code(text,text,text)'::regprocedure) into d;
  if position('paid with points only' in d) = 0 then
    d := replace(d, E'  if v_code.kind = ''entry'' then\n',
      E'  if v_code.kind = ''entry'' then\n    raise exception ''Entry codes are no longer used — tournaments are paid with points only. Load points in your wallet.'';\n');
    if position('paid with points only' in d) = 0 then
      raise exception 'redeem_code patch did not apply';
    end if;
    execute d;
  end if;
end $$;

create or replace function public.request_wallet_load(p_amount int, p_screenshot text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_admin uuid; v_who text;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  perform public._assert_open();
  if p_amount is null or p_amount < 1 or p_amount > 100000 then
    raise exception 'Enter the amount you paid (1 to 100000).';
  end if;
  if p_screenshot is null or p_screenshot !~ '^data:image/(png|jpe?g|webp);base64,[A-Za-z0-9+/=]+$' then
    raise exception 'Please attach your eSewa payment screenshot.';
  end if;
  if length(p_screenshot) > 600000 then
    raise exception 'The screenshot is too large. Please upload a smaller image.';
  end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then
    raise exception 'Your account is banned.';
  end if;
  if (select count(*) from public.wallet_load_requests where player_id = auth.uid() and status = 'pending') >= 3 then
    raise exception 'You already have 3 payments waiting to be checked. Please wait for them first.';
  end if;
  insert into public.wallet_load_requests (player_id, amount, screenshot)
  values (auth.uid(), p_amount, p_screenshot)
  returning id into v_id;

  select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com';
  if v_admin is not null then
    select coalesce('@' || username, player_tag, 'A player') into v_who from public.players where id = auth.uid();
    insert into public.notifications (player_id, title, body)
    values (v_admin, '🧾 Payment screenshot to check',
            coalesce(v_who, 'A player') || ' sent a Rs ' || p_amount || ' eSewa screenshot. Open Admin → Points to approve or reject it.');
  end if;
  return jsonb_build_object('id', v_id, 'status', 'pending');
end;
$$;
revoke all on function public.request_wallet_load(int, text) from public, anon;
grant execute on function public.request_wallet_load(int, text) to authenticated;

commit;
-- ── privacy: email opt-out + data retention ──────────────────────────────
-- * players.email_opt_out: set by the email-unsubscribe link; the optional emails
--   (24h reminder, results, announcements) skip these players.
-- * purge_old_personal_data() runs daily (pg_cron 'privacy-purge'):
--     - points-load payment screenshots 30 days after review
--     - registration payment screenshots 30 days after the registration
--     - the optional WhatsApp reminder number 2 days after the tournament starts
--       (the registration form promises it isn't kept for future events)
--   These periods are the ones stated on /privacy/.
begin;

alter table public.players add column if not exists email_opt_out boolean not null default false;

alter table public.wallet_load_requests alter column screenshot drop not null;

create or replace function public.purge_old_personal_data()
returns jsonb language plpgsql security definer set search_path = public as $$
declare a int; c int; d int;
begin
  update public.wallet_load_requests set screenshot = null
    where screenshot is not null and status <> 'pending' and reviewed_at < now() - interval '30 days';
  get diagnostics a = row_count;

  update public.registrations set payment_screenshot = null
    where payment_screenshot is not null and created_at < now() - interval '30 days';
  get diagnostics c = row_count;
  update public.registrations set whatsapp = null
    where whatsapp is not null
      and coalesce(public.tournament_start_at(tournament_slug), created_at + interval '14 days') < now() - interval '2 days';
  get diagnostics d = row_count;
  return jsonb_build_object('load_screenshots', a, 'registration_screenshots', c, 'whatsapp_numbers', d);
end;
$$;
revoke all on function public.purge_old_personal_data() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'privacy-purge';
select cron.schedule('privacy-purge', '17 3 * * *', 'select public.purge_old_personal_data()');

commit;

-- ZULU rate-limit log (visitor IPs) is only needed for a few minutes; keep at most 7 days.
begin;
do $$
declare d text;
begin
  select pg_get_functiondef('public.purge_old_personal_data()'::regprocedure) into d;
  if position('zulu_ai_reply_log' in d) = 0 then
    d := replace(d, E'  return jsonb_build_object(',
      E'  delete from public.zulu_ai_reply_log where created_at < now() - interval ''7 days'';\n  return jsonb_build_object(');
    execute d;
  end if;
end $$;
commit;

-- ── app perks + early access ─────────────────────────────────────────────
-- * players.app_installed_at: set the first time a signed-in player opens the installed
--   app (claim_app_perks, called by index.html only in standalone mode). The client check
--   can't be proven server-side; the perks are cosmetic + an early registration window.
-- * claim_app_perks(p_effect): once per account, a free 7-day Lite pass (glow or steel)
--   and the 📱 badge (_display_name, used by the challenge lobby/room names).
-- * Early access: a tournament with "early_access": "yes" and "reg_opens" (ISO) in
--   tournaments.json opens to app users 24 hours before reg_opens and to everyone else at
--   reg_opens. register_for_tournament() enforces it.
begin;

alter table public.players add column if not exists app_installed_at timestamptz;

create or replace function public.claim_app_perks(p_effect text default 'glow')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_at timestamptz; v_res jsonb;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  select app_installed_at into v_at from public.players where id = auth.uid() for update;
  if v_at is not null then
    return jsonb_build_object('new', false, 'since', v_at);
  end if;
  if p_effect not in ('glow','steel') then p_effect := 'glow'; end if;
  update public.players set app_installed_at = now() where id = auth.uid();
  v_res := public._apply_effect_plan(auth.uid(), 'fx_lite_week', p_effect, null, 'APP-WELCOME');
  insert into public.notifications (player_id, title, body)
  values (auth.uid(), '📱 Welcome to the JD Arena app',
          'Your free 7-day Lite squad effect is on, your username now shows the 📱 app badge, and you get early access to marked events — 24 hours before everyone else.');
  return jsonb_build_object('new', true, 'effect', p_effect, 'expires_at', v_res->>'expires_at');
end;
$$;
revoke all on function public.claim_app_perks(text) from public, anon;
grant execute on function public.claim_app_perks(text) to authenticated;

create or replace function public.tournament_field(p_slug text, p_key text)
returns text language sql stable security definer set search_path = public as $$
  select t->>p_key
  from public.site_content, jsonb_array_elements(content->'tournaments') t
  where key = 'tournaments' and t->>'name' = p_slug
  limit 1;
$$;

-- display name for other players to see: @username, plus 📱 for app users
create or replace function public._display_name(p_player uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce('@' || username, player_tag, 'a player') || case when app_installed_at is not null then ' 📱' else '' end
  from public.players where id = p_player
$$;

do $$
declare d text;
begin
  -- challenge lobby + room names show the badge (notification texts keep _challenge_name)
  select pg_get_functiondef('public.get_open_challenges()'::regprocedure) into d;
  if position('_display_name' in d) = 0 then
    d := replace(d, 'public._challenge_name(c.creator)', 'public._display_name(c.creator)');
    execute d;
  end if;
  select pg_get_functiondef('public.get_challenge_names(uuid[])'::regprocedure) into d;
  if position('_display_name' in d) = 0 then
    d := replace(d, E'coalesce(''@'' || p.username, p.player_tag, ''Player'')', 'public._display_name(p.id)');
    if position('_display_name' in d) = 0 then raise exception 'get_challenge_names patch did not apply'; end if;
    execute d;
  end if;

  -- early access window in register_for_tournament()
  select pg_get_functiondef('public.register_for_tournament(text,text,text,text,text,text)'::regprocedure) into d;
  if position('early_access' in d) = 0 then
    d := replace(d, E'  if p_device_type not in (''mobile'',''emulator'') then',
E'  declare v_open timestamptz;
  begin
    if lower(coalesce(public.tournament_field(p_tournament_slug, ''early_access''), '''')) in (''yes'',''true'')
       and not exists(select 1 from public.registrations where tournament_slug = p_tournament_slug and player_id = auth.uid()) then
      begin v_open := nullif(public.tournament_field(p_tournament_slug, ''reg_opens''), '''')::timestamptz;
      exception when others then v_open := null; end;
      if v_open is not null and now() < v_open then
        if now() < v_open - interval ''24 hours'' then
          raise exception ''Registration opens at % (app users 24 hours earlier).'', to_char(v_open at time zone ''Asia/Kathmandu'', ''Dy DD Mon, HH12:MI AM'') || '' NPT'';
        end if;
        if (select app_installed_at from public.players where id = auth.uid()) is null then
          raise exception ''Early access: only JD Arena app users can join before %. Open the app to join now.'', to_char(v_open at time zone ''Asia/Kathmandu'', ''Dy DD Mon, HH12:MI AM'') || '' NPT'';
        end if;
      end if;
    end if;
  end;
  if p_device_type not in (''mobile'',''emulator'') then');
    if position('early_access' in d) = 0 then raise exception 'register_for_tournament patch did not apply'; end if;
    execute d;
  end if;
end $$;

commit;

-- ── friends + direct messages (Messenger) ─────────────────────────────────
-- Players add each other by username or JD tag; once a request is accepted they can
-- message each other 1:1 (chat.js, the 💬 bubble on every page). Everything goes through
-- the SECURITY DEFINER RPCs below (players RLS only exposes a player's own row).
-- * Friend requests/accepts land in notifications (push = true, so the existing trigger
--   pushes them). DMs do NOT — they'd flood Notification History — they are pushed by
--   the dm-push Edge Function instead (trigger dm_messages_push, same vault secrets).
-- * Block: removes the friendship and stops requests/messages both ways.
-- * last_seen_at drives the green "online" dot; dm_poll() refreshes it at most once a minute.
-- * Messages are kept 180 days (purge_old_personal_data, see /privacy/) and are deleted
--   with either account (on delete cascade). Idempotent.
begin;
alter table public.players add column if not exists last_seen_at timestamptz;

create table if not exists public.friendships (
  id bigserial primary key,
  requester uuid not null references public.players(id) on delete cascade,
  addressee uuid not null references public.players(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  check (requester <> addressee)
);
create unique index if not exists friendships_pair_idx on public.friendships (least(requester, addressee), greatest(requester, addressee));
create index if not exists friendships_addressee_idx on public.friendships (addressee, status);
create index if not exists friendships_requester_idx on public.friendships (requester, status);
alter table public.friendships enable row level security;
drop policy if exists "players read own friendships" on public.friendships;
create policy "players read own friendships" on public.friendships
  for select using (auth.uid() in (requester, addressee));

create table if not exists public.player_blocks (
  blocker uuid not null references public.players(id) on delete cascade,
  blocked uuid not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked)
);
alter table public.player_blocks enable row level security;
drop policy if exists "players read own blocks" on public.player_blocks;
create policy "players read own blocks" on public.player_blocks
  for select using (auth.uid() = blocker);

create table if not exists public.dm_messages (
  id bigserial primary key,
  sender uuid not null references public.players(id) on delete cascade,
  recipient uuid not null references public.players(id) on delete cascade,
  body text not null check (length(body) between 1 and 500),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists dm_messages_pair_idx on public.dm_messages (least(sender, recipient), greatest(sender, recipient), id desc);
create index if not exists dm_messages_unread_idx on public.dm_messages (recipient, sender) where read_at is null;
create index if not exists dm_messages_sender_time_idx on public.dm_messages (sender, created_at desc);
alter table public.dm_messages enable row level security;
drop policy if exists "participants read direct messages" on public.dm_messages;
create policy "participants read direct messages" on public.dm_messages
  for select using (auth.uid() in (sender, recipient));

-- ── helpers ──
create or replace function public._find_player(p_who text)
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.players
  where lower(username) = lower(trim(regexp_replace(coalesce(p_who, ''), '^\s*@', '')))
     or upper(player_tag) = upper(trim(coalesce(p_who, '')))
  limit 1
$$;

create or replace function public._blocked_either(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.player_blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a))
$$;

create or replace function public._are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.friendships
    where status = 'accepted' and least(requester, addressee) = least(a, b) and greatest(requester, addressee) = greatest(a, b))
$$;

create or replace function public._chat_name(p uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce('@' || username, player_tag, 'a player') from public.players where id = p
$$;

create or replace function public._chat_card(p uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'username', username, 'tag', player_tag, 'logo', squad_logo,
    'squad', squad_name, 'app', app_installed_at is not null,
    'online', coalesce(last_seen_at > now() - interval '2 minutes', false), 'seen', last_seen_at)
  from public.players where id = p
$$;

-- ── friend requests ──
create or replace function public.send_friend_request(p_who text)
returns text language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_to uuid; f public.friendships;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  v_to := public._find_player(p_who);
  if v_to is null or public._blocked_either(v_me, v_to) then
    raise exception 'No player called %.', coalesce(nullif(trim(p_who), ''), '(blank)');
  end if;
  if v_to = v_me then raise exception 'That''s you!'; end if;
  select * into f from public.friendships
    where least(requester, addressee) = least(v_me, v_to) and greatest(requester, addressee) = greatest(v_me, v_to);
  if f.id is not null then
    if f.status = 'accepted' then return 'already'; end if;
    if f.requester = v_me then return 'pending'; end if;
    -- they already asked us: adding them back accepts it
    update public.friendships set status = 'accepted', accepted_at = now() where id = f.id;
    insert into public.notifications (player_id, title, body)
      values (v_to, '🤝 ' || public._chat_name(v_me) || ' is now your friend', 'You can message each other now. Tap 💬 Messages to say hi.');
    return 'accepted';
  end if;
  if (select count(*) from public.friendships where requester = v_me and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Too many friend requests. Try again in a while.';
  end if;
  insert into public.friendships (requester, addressee) values (v_me, v_to);
  insert into public.notifications (player_id, title, body)
    values (v_to, '👋 Friend request from ' || public._chat_name(v_me), 'Open 💬 Messages to accept or decline.');
  return 'sent';
end;
$$;

create or replace function public.respond_friend_request(p_from uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_id bigint;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  select id into v_id from public.friendships where requester = p_from and addressee = v_me and status = 'pending';
  if v_id is null then raise exception 'That request is no longer pending.'; end if;
  if p_accept then
    update public.friendships set status = 'accepted', accepted_at = now() where id = v_id;
    insert into public.notifications (player_id, title, body)
      values (p_from, '🤝 ' || public._chat_name(v_me) || ' accepted your friend request', 'You can message each other now. Tap 💬 Messages to say hi.');
  else
    delete from public.friendships where id = v_id;
  end if;
end;
$$;

-- unfriend, or cancel a request either of you sent
create or replace function public.remove_friend(p_who uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.friendships
  where auth.uid() is not null
    and least(requester, addressee) = least(auth.uid(), p_who) and greatest(requester, addressee) = greatest(auth.uid(), p_who)
$$;

create or replace function public.block_player(p_who uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_who = auth.uid() then raise exception 'That''s you!'; end if;
  perform public.remove_friend(p_who);
  insert into public.player_blocks (blocker, blocked) values (auth.uid(), p_who) on conflict do nothing;
end;
$$;

create or replace function public.unblock_player(p_who uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.player_blocks where blocker = auth.uid() and blocked = p_who
$$;

-- ── messages ──
create or replace function public.send_dm(p_to uuid, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_id bigint;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  p_body := trim(coalesce(p_body, ''));
  if length(p_body) < 1 or length(p_body) > 500 then raise exception 'Messages must be 1-500 characters.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  if not public._are_friends(v_me, p_to) or public._blocked_either(v_me, p_to) then
    raise exception 'You can only message your friends.';
  end if;
  if (select count(*) from public.dm_messages where sender = v_me and created_at > now() - interval '10 seconds') >= 8 then
    raise exception 'Slow down a little.';
  end if;
  insert into public.dm_messages (sender, recipient, body) values (v_me, p_to, p_body) returning id into v_id;
  return v_id;
end;
$$;

-- newest-first page of a conversation; p_after = only messages newer than that id
create or replace function public.dm_thread(p_with uuid, p_before bigint default null, p_after bigint default null)
returns table (id bigint, mine boolean, body text, created_at timestamptz, read_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.id, m.sender = auth.uid(), m.body, m.created_at, m.read_at
  from public.dm_messages m
  where auth.uid() is not null
    and least(m.sender, m.recipient) = least(auth.uid(), p_with) and greatest(m.sender, m.recipient) = greatest(auth.uid(), p_with)
    and (p_before is null or m.id < p_before)
    and (p_after is null or m.id > p_after)
  order by m.id desc
  limit 60
$$;

create or replace function public.dm_mark_read(p_with uuid)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.dm_messages set read_at = now() where recipient = auth.uid() and sender = p_with and read_at is null;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- the cheap 5-second poll behind the 💬 badge: unread total, pending requests, the newest
-- unread message (for the in-app banner), and a throttled "online" heartbeat
create or replace function public.dm_poll()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_last jsonb;
begin
  if v_me is null then return null; end if;
  update public.players set last_seen_at = now()
    where id = v_me and (last_seen_at is null or last_seen_at < now() - interval '1 minute');
  select jsonb_build_object('id', m.id, 'from', m.sender, 'name', public._chat_name(m.sender), 'body', left(m.body, 140))
    into v_last
    from public.dm_messages m
    where m.recipient = v_me and m.read_at is null and not public._blocked_either(v_me, m.sender)
    order by m.id desc limit 1;
  return jsonb_build_object(
    'unread', (select count(*) from public.dm_messages m where m.recipient = v_me and m.read_at is null
                 and not exists(select 1 from public.player_blocks b where b.blocker = v_me and b.blocked = m.sender)),
    'requests', (select count(*) from public.friendships where addressee = v_me and status = 'pending'),
    'last', v_last);
end;
$$;

-- everything the Messages panel lists: friends (latest message + unread first), requests, blocks
create or replace function public.chat_overview()
returns jsonb language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as id),
  fr as (
    select f.*, case when f.requester = me.id then f.addressee else f.requester end as other
    from public.friendships f, me where me.id in (f.requester, f.addressee)
  ),
  friends as (
    select fr.other, lm.id as last_id, lm.body as last_body, lm.created_at as last_at, lm.sender = (select id from me) as last_mine, lm.read_at as last_read,
      (select count(*) from public.dm_messages u where u.recipient = (select id from me) and u.sender = fr.other and u.read_at is null) as unread
    from fr
    left join lateral (
      select m.* from public.dm_messages m
      where least(m.sender, m.recipient) = least((select id from me), fr.other) and greatest(m.sender, m.recipient) = greatest((select id from me), fr.other)
      order by m.id desc limit 1
    ) lm on true
    where fr.status = 'accepted'
  )
  select jsonb_build_object(
    'friends', coalesce((select jsonb_agg(public._chat_card(f.other) || jsonb_build_object(
        'last_id', f.last_id, 'last_body', left(f.last_body, 120), 'last_at', f.last_at, 'last_mine', f.last_mine,
        'last_read', f.last_read is not null, 'unread', f.unread)
      order by f.last_at desc nulls last) from friends f), '[]'::jsonb),
    'incoming', coalesce((select jsonb_agg(public._chat_card(fr.other) || jsonb_build_object('at', fr.created_at) order by fr.created_at desc)
      from fr where fr.status = 'pending' and fr.addressee = (select id from me)), '[]'::jsonb),
    'outgoing', coalesce((select jsonb_agg(public._chat_card(fr.other) || jsonb_build_object('at', fr.created_at) order by fr.created_at desc)
      from fr where fr.status = 'pending' and fr.requester = (select id from me)), '[]'::jsonb),
    'blocked', coalesce((select jsonb_agg(public._chat_card(b.blocked) order by b.created_at desc)
      from public.player_blocks b where b.blocker = (select id from me)), '[]'::jsonb)
  )
  where (select id from me) is not null
$$;

-- player card for a ?dm=<tag> deep link / search preview (friends or anyone you're not blocked by)
create or replace function public.chat_player(p_who text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then return null; end if;
  v := public._find_player(p_who);
  if v is null or public._blocked_either(auth.uid(), v) then return null; end if;
  return public._chat_card(v) || jsonb_build_object('friend', public._are_friends(auth.uid(), v));
end;
$$;

revoke all on function public._find_player(text) from public, anon, authenticated;
revoke all on function public._blocked_either(uuid, uuid) from public, anon, authenticated;
revoke all on function public._are_friends(uuid, uuid) from public, anon, authenticated;
revoke all on function public._chat_name(uuid) from public, anon, authenticated;
revoke all on function public._chat_card(uuid) from public, anon, authenticated;
revoke all on function public.send_friend_request(text) from public, anon;
revoke all on function public.respond_friend_request(uuid, boolean) from public, anon;
revoke all on function public.remove_friend(uuid) from public, anon;
revoke all on function public.block_player(uuid) from public, anon;
revoke all on function public.unblock_player(uuid) from public, anon;
revoke all on function public.send_dm(uuid, text) from public, anon;
revoke all on function public.dm_thread(uuid, bigint, bigint) from public, anon;
revoke all on function public.dm_mark_read(uuid) from public, anon;
revoke all on function public.dm_poll() from public, anon;
revoke all on function public.chat_overview() from public, anon;
revoke all on function public.chat_player(text) from public, anon;
grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
grant execute on function public.block_player(uuid) to authenticated;
grant execute on function public.unblock_player(uuid) to authenticated;
grant execute on function public.send_dm(uuid, text) to authenticated;
grant execute on function public.dm_thread(uuid, bigint, bigint) to authenticated;
grant execute on function public.dm_mark_read(uuid) to authenticated;
grant execute on function public.dm_poll() to authenticated;
grant execute on function public.chat_overview() to authenticated;
grant execute on function public.chat_player(text) to authenticated;

-- ── push each new DM (dm-push Edge Function; a failed hand-off never blocks the send) ──
create or replace function public.dm_messages_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ids bigint[];
begin
  select array_agg(id) into v_ids from new_rows;
  if v_ids is null then return null; end if;
  begin
    perform net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/dm-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
      ),
      body := jsonb_build_object('ids', to_jsonb(v_ids))
    );
  exception when others then
    raise warning 'dm_messages_push: %', sqlerrm;
  end;
  return null;
end;
$$;
revoke all on function public.dm_messages_push() from public, anon, authenticated;
drop trigger if exists dm_messages_push on public.dm_messages;
create trigger dm_messages_push after insert on public.dm_messages
  referencing new table as new_rows for each statement execute function public.dm_messages_push();

-- retention: direct messages are deleted after 180 days (stated on /privacy/)
do $$
declare d text;
begin
  select pg_get_functiondef('public.purge_old_personal_data()'::regprocedure) into d;
  if position('dm_messages' in d) = 0 then
    d := replace(d, E'  return jsonb_build_object(',
      E'  delete from public.dm_messages where created_at < now() - interval ''180 days'';\n  return jsonb_build_object(');
    execute d;
  end if;
end $$;
commit;

-- ── friends + direct messages: hardening ──────────────────────────────────
-- * Online status / last seen are shown to friends only: _chat_card(p, viewer) blanks
--   online + seen unless they're friends (requests, search previews, blocked list).
-- * Request spam: cancelling/declining deletes the friendships row, so the hourly cap alone
--   let someone resend forever. Requests are now also logged (friend_request_log, kept 7
--   days by purge_old_personal_data) for the cap, and the target gets at most one
--   notification/push per sender per 24h. Idempotent.
begin;
create table if not exists public.friend_request_log (
  id bigserial primary key,
  requester uuid not null references public.players(id) on delete cascade,
  addressee uuid not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists friend_request_log_idx on public.friend_request_log (requester, created_at desc);
alter table public.friend_request_log enable row level security; -- no policies: RPC only

create or replace function public._chat_card(p uuid, viewer uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public._are_friends(p, viewer) then c else c - 'online' - 'seen' || '{"online":false}'::jsonb end
  from (select public._chat_card(p) as c) x
$$;
revoke all on function public._chat_card(uuid, uuid) from public, anon, authenticated;

create or replace function public.send_friend_request(p_who text)
returns text language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_to uuid; f public.friendships;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  v_to := public._find_player(p_who);
  if v_to is null or public._blocked_either(v_me, v_to) then
    raise exception 'No player called %.', coalesce(nullif(trim(p_who), ''), '(blank)');
  end if;
  if v_to = v_me then raise exception 'That''s you!'; end if;
  select * into f from public.friendships
    where least(requester, addressee) = least(v_me, v_to) and greatest(requester, addressee) = greatest(v_me, v_to);
  if f.id is not null then
    if f.status = 'accepted' then return 'already'; end if;
    if f.requester = v_me then return 'pending'; end if;
    -- they already asked us: adding them back accepts it
    update public.friendships set status = 'accepted', accepted_at = now() where id = f.id;
    insert into public.notifications (player_id, title, body)
      values (v_to, '🤝 ' || public._chat_name(v_me) || ' is now your friend', 'You can message each other now. Tap 💬 Messages to say hi.');
    return 'accepted';
  end if;
  if (select count(*) from public.friend_request_log where requester = v_me and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Too many friend requests. Try again in a while.';
  end if;
  insert into public.friendships (requester, addressee) values (v_me, v_to);
  if not exists(select 1 from public.friend_request_log where requester = v_me and addressee = v_to and created_at > now() - interval '24 hours') then
    insert into public.notifications (player_id, title, body)
      values (v_to, '👋 Friend request from ' || public._chat_name(v_me), 'Open 💬 Messages to accept or decline.');
  end if;
  insert into public.friend_request_log (requester, addressee) values (v_me, v_to);
  return 'sent';
end;
$$;

create or replace function public.chat_overview()
returns jsonb language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as id),
  fr as (
    select f.*, case when f.requester = me.id then f.addressee else f.requester end as other
    from public.friendships f, me where me.id in (f.requester, f.addressee)
  ),
  friends as (
    select fr.other, lm.id as last_id, lm.body as last_body, lm.created_at as last_at, lm.sender = (select id from me) as last_mine, lm.read_at as last_read,
      (select count(*) from public.dm_messages u where u.recipient = (select id from me) and u.sender = fr.other and u.read_at is null) as unread
    from fr
    left join lateral (
      select m.* from public.dm_messages m
      where least(m.sender, m.recipient) = least((select id from me), fr.other) and greatest(m.sender, m.recipient) = greatest((select id from me), fr.other)
      order by m.id desc limit 1
    ) lm on true
    where fr.status = 'accepted'
  )
  select jsonb_build_object(
    'friends', coalesce((select jsonb_agg(public._chat_card(f.other) || jsonb_build_object(
        'last_id', f.last_id, 'last_body', left(f.last_body, 120), 'last_at', f.last_at, 'last_mine', f.last_mine,
        'last_read', f.last_read is not null, 'unread', f.unread)
      order by f.last_at desc nulls last) from friends f), '[]'::jsonb),
    'incoming', coalesce((select jsonb_agg(public._chat_card(fr.other, (select id from me)) || jsonb_build_object('at', fr.created_at) order by fr.created_at desc)
      from fr where fr.status = 'pending' and fr.addressee = (select id from me)), '[]'::jsonb),
    'outgoing', coalesce((select jsonb_agg(public._chat_card(fr.other, (select id from me)) || jsonb_build_object('at', fr.created_at) order by fr.created_at desc)
      from fr where fr.status = 'pending' and fr.requester = (select id from me)), '[]'::jsonb),
    'blocked', coalesce((select jsonb_agg(public._chat_card(b.blocked, (select id from me)) order by b.created_at desc)
      from public.player_blocks b where b.blocker = (select id from me)), '[]'::jsonb)
  )
  where (select id from me) is not null
$$;

create or replace function public.chat_player(p_who text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null then return null; end if;
  v := public._find_player(p_who);
  if v is null or public._blocked_either(auth.uid(), v) then return null; end if;
  return public._chat_card(v, auth.uid()) || jsonb_build_object('friend', public._are_friends(auth.uid(), v));
end;
$$;

do $$
declare d text;
begin
  select pg_get_functiondef('public.purge_old_personal_data()'::regprocedure) into d;
  if position('friend_request_log' in d) = 0 then
    d := replace(d, E'  return jsonb_build_object(',
      E'  delete from public.friend_request_log where created_at < now() - interval ''7 days'';\n  return jsonb_build_object(');
    execute d;
  end if;
end $$;
commit;

-- ── Messages v2: squad group chats + match (challenge) chat in the inbox + push ──────────
-- * Squad chats: any player can start a group with up to 7 friends (8 people max) — their
--   Clash Squad team — from 💬 Messages. Only the adder's friends can be added. Tables are
--   RPC-only (no RLS policies); every read goes through a member check.
-- * Match chat: the existing captain-vs-captain challenge chat (challenge_messages) now
--   shows up in the Messages inbox with unread counts. challenge_reads stores how far each
--   side has read, so push can skip a message the other captain is already looking at.
--   challenges / challenge_messages RLS is unchanged.
-- * Push: new group and challenge messages go to the chat-push Edge Function (pg_net, same
--   vault secrets as dm-push). A failed hand-off never blocks the send.
-- * Retention: group messages are deleted after 180 days, like direct messages (/privacy/).
-- Additive only: dm_poll() and chat_overview() keep every key the old chat.js reads. Idempotent.
begin;
create table if not exists public.chat_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(name) between 1 and 40),
  created_by uuid references public.players(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.chat_groups enable row level security; -- no policies: RPC only

create table if not exists public.chat_group_members (
  group_id uuid not null references public.chat_groups(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  added_by uuid references public.players(id) on delete set null,
  last_read_id bigint not null default 0,
  muted boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key (group_id, player_id)
);
create index if not exists chat_group_members_player_idx on public.chat_group_members (player_id);
alter table public.chat_group_members enable row level security;

create table if not exists public.group_messages (
  id bigserial primary key,
  group_id uuid not null references public.chat_groups(id) on delete cascade,
  sender uuid references public.players(id) on delete set null,
  kind text not null default 'text' check (kind in ('text','system','room')),
  body text not null check (length(body) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists group_messages_group_idx on public.group_messages (group_id, id desc);
create index if not exists group_messages_sender_time_idx on public.group_messages (sender, created_at desc);
alter table public.group_messages enable row level security;

create table if not exists public.challenge_reads (
  challenge_id uuid not null references public.challenges(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  last_read_id bigint not null default 0,
  primary key (challenge_id, player_id)
);
alter table public.challenge_reads enable row level security;

-- ── helpers ──
create or replace function public._group_member(g uuid, p uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.chat_group_members where group_id = g and player_id = p)
$$;
revoke all on function public._group_member(uuid, uuid) from public, anon, authenticated;

create or replace function public._group_system(g uuid, p_body text)
returns void language sql security definer set search_path = public as $$
  insert into public.group_messages (group_id, sender, kind, body) values (g, null, 'system', left(p_body, 500))
$$;
revoke all on function public._group_system(uuid, text) from public, anon, authenticated;

-- adds friends of v_by to a group; returns how many were added (errors on a non-friend)
create or replace function public._group_add(g uuid, v_by uuid, p_members uuid[])
returns int language plpgsql security definer set search_path = public as $$
declare v uuid; n int := 0; v_name text; v_names text := '';
begin
  select name into v_name from public.chat_groups where id = g;
  foreach v in array coalesce(p_members, '{}'::uuid[]) loop
    if v = v_by or public._group_member(g, v) then continue; end if;
    if not public._are_friends(v_by, v) or public._blocked_either(v_by, v) then
      raise exception 'You can only add your friends.';
    end if;
    insert into public.chat_group_members (group_id, player_id, added_by, last_read_id)
      values (g, v, v_by, coalesce((select max(id) from public.group_messages where group_id = g), 0));
    insert into public.notifications (player_id, title, body)
      values (v, '👥 ' || public._chat_name(v_by) || ' added you to the squad chat "' || v_name || '"', 'Open 💬 Messages to chat with your squad.');
    v_names := v_names || case when n > 0 then ', ' else '' end || public._chat_name(v);
    n := n + 1;
  end loop;
  if (select count(*) from public.chat_group_members where group_id = g) > 8 then
    raise exception 'A squad chat can have up to 8 players.';
  end if;
  if n > 0 then perform public._group_system(g, public._chat_name(v_by) || ' added ' || v_names); end if;
  return n;
end;
$$;
revoke all on function public._group_add(uuid, uuid, uuid[]) from public, anon, authenticated;

-- ── squad chat RPCs ──
create or replace function public.create_group_chat(p_name text, p_members uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); g uuid;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  p_name := trim(coalesce(p_name, ''));
  if length(p_name) < 1 or length(p_name) > 40 then raise exception 'Give the squad chat a name (up to 40 characters).'; end if;
  if coalesce(array_length(p_members, 1), 0) < 1 then raise exception 'Pick at least one friend.'; end if;
  if (select count(*) from public.chat_groups where created_by = v_me and created_at > now() - interval '1 day') >= 10 then
    raise exception 'You''ve made a lot of squad chats today. Try again tomorrow.';
  end if;
  insert into public.chat_groups (name, created_by) values (p_name, v_me) returning id into g;
  insert into public.chat_group_members (group_id, player_id, added_by) values (g, v_me, v_me);
  perform public._group_system(g, public._chat_name(v_me) || ' created the squad chat');
  perform public._group_add(g, v_me, p_members);
  update public.chat_group_members set last_read_id = (select max(id) from public.group_messages where group_id = g)
    where group_id = g and player_id = v_me;
  return g;
end;
$$;

create or replace function public.add_group_members(p_group uuid, p_members uuid[])
returns int language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public._group_member(p_group, auth.uid()) then raise exception 'You''re not in this chat.'; end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then raise exception 'Your account is banned.'; end if;
  return public._group_add(p_group, auth.uid(), p_members);
end;
$$;

create or replace function public.leave_group_chat(p_group uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null or not public._group_member(p_group, v_me) then return; end if;
  delete from public.chat_group_members where group_id = p_group and player_id = v_me;
  if not exists(select 1 from public.chat_group_members where group_id = p_group) then
    delete from public.chat_groups where id = p_group;
  else
    perform public._group_system(p_group, public._chat_name(v_me) || ' left');
  end if;
end;
$$;

create or replace function public.rename_group_chat(p_group uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public._group_member(p_group, auth.uid()) then raise exception 'You''re not in this chat.'; end if;
  p_name := trim(coalesce(p_name, ''));
  if length(p_name) < 1 or length(p_name) > 40 then raise exception 'Names are 1-40 characters.'; end if;
  if p_name = (select name from public.chat_groups where id = p_group) then return; end if;
  update public.chat_groups set name = p_name where id = p_group;
  perform public._group_system(p_group, public._chat_name(auth.uid()) || ' renamed the chat to "' || p_name || '"');
end;
$$;

create or replace function public.mute_group_chat(p_group uuid, p_muted boolean)
returns void language sql security definer set search_path = public as $$
  update public.chat_group_members set muted = coalesce(p_muted, false) where group_id = p_group and player_id = auth.uid()
$$;

-- p_kind 'room' = a "share room to squad" card (body = "ROOM|<id>|<password>|<label>")
create or replace function public.send_group_message(p_group uuid, p_body text, p_kind text default 'text')
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_id bigint;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  if not public._group_member(p_group, v_me) then raise exception 'You''re not in this chat any more.'; end if;
  p_body := trim(coalesce(p_body, ''));
  if length(p_body) < 1 or length(p_body) > 500 then raise exception 'Messages must be 1-500 characters.'; end if;
  if coalesce(p_kind, 'text') not in ('text','room') then raise exception 'Unknown message type.'; end if;
  if (select count(*) from public.group_messages where sender = v_me and created_at > now() - interval '10 seconds') >= 8 then
    raise exception 'Slow down a little.';
  end if;
  insert into public.group_messages (group_id, sender, kind, body) values (p_group, v_me, coalesce(p_kind, 'text'), p_body) returning id into v_id;
  update public.chat_group_members set last_read_id = v_id where group_id = p_group and player_id = v_me;
  return v_id;
end;
$$;

-- newest-first page of a squad chat
create or replace function public.group_thread(p_group uuid, p_before bigint default null)
returns table (id bigint, sender uuid, mine boolean, kind text, body text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.id, m.sender, m.sender = auth.uid(), m.kind, m.body, m.created_at
  from public.group_messages m
  where m.group_id = p_group and public._group_member(p_group, auth.uid())
    and (p_before is null or m.id < p_before)
  order by m.id desc
  limit 60
$$;

-- name, members (cards + how far each has read) and my mute setting
create or replace function public.group_info(p_group uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', g.id, 'name', g.name, 'created_by', g.created_by,
    'muted', (select muted from public.chat_group_members where group_id = g.id and player_id = auth.uid()),
    'members', coalesce((select jsonb_agg(public._chat_card(m.player_id, auth.uid()) || jsonb_build_object(
        'read', m.last_read_id, 'me', m.player_id = auth.uid(), 'friend', public._are_friends(m.player_id, auth.uid()))
      order by m.joined_at) from public.chat_group_members m where m.group_id = g.id), '[]'::jsonb))
  from public.chat_groups g
  where g.id = p_group and public._group_member(p_group, auth.uid())
$$;

create or replace function public.group_mark_read(p_group uuid)
returns void language sql security definer set search_path = public as $$
  update public.chat_group_members set last_read_id = coalesce((select max(id) from public.group_messages where group_id = p_group), 0)
  where group_id = p_group and player_id = auth.uid()
$$;

-- match chat read marker (captains only, same check as the chat itself)
create or replace function public.challenge_mark_read(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_last bigint;
begin
  if auth.uid() is null or not exists(select 1 from public.challenges where id = p_id and auth.uid() in (creator, opponent)) then return; end if;
  select coalesce(max(id), 0) into v_last from public.challenge_messages where challenge_id = p_id;
  insert into public.challenge_reads (challenge_id, player_id, last_read_id) values (p_id, auth.uid(), v_last)
  on conflict (challenge_id, player_id) do update set last_read_id = greatest(public.challenge_reads.last_read_id, excluded.last_read_id);
end;
$$;

-- ── the 5-second badge poll, now counting squad and match chats too ──
-- Old keys (unread, requests, last) are unchanged; g_unread / m_unread / last_any are new.
create or replace function public.dm_poll()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_last jsonb; v_g jsonb; v_m jsonb; v_any jsonb;
begin
  if v_me is null then return null; end if;
  update public.players set last_seen_at = now()
    where id = v_me and (last_seen_at is null or last_seen_at < now() - interval '1 minute');
  select jsonb_build_object('id', m.id, 'kind', 'dm', 'key', m.sender, 'from', m.sender, 'name', public._chat_name(m.sender), 'body', left(m.body, 140), 'at', m.created_at)
    into v_last
    from public.dm_messages m
    where m.recipient = v_me and m.read_at is null and not public._blocked_either(v_me, m.sender)
    order by m.id desc limit 1;
  select jsonb_build_object('id', m.id, 'kind', 'group', 'key', m.group_id, 'from', m.sender, 'name', public._chat_name(m.sender),
      'title', g.name, 'body', left(case when m.kind = 'room' then '🎮 Shared a room' else m.body end, 140), 'at', m.created_at)
    into v_g
    from public.chat_group_members gm
    join public.group_messages m on m.group_id = gm.group_id and m.id > gm.last_read_id
    join public.chat_groups g on g.id = gm.group_id
    where gm.player_id = v_me and not gm.muted and m.sender is distinct from v_me and m.kind <> 'system'
    order by m.id desc limit 1;
  select jsonb_build_object('id', m.id, 'kind', 'match', 'key', c.id, 'from', m.sender, 'name', public._chat_name(m.sender),
      'title', c.mode || ' challenge', 'body', left(m.body, 140), 'at', m.created_at)
    into v_m
    from public.challenges c
    join public.challenge_messages m on m.challenge_id = c.id
    left join public.challenge_reads r on r.challenge_id = c.id and r.player_id = v_me
    where v_me in (c.creator, c.opponent) and c.status in ('accepted','disputed')
      and m.sender is distinct from v_me and m.id > coalesce(r.last_read_id, 0)
    order by m.id desc limit 1;
  select x into v_any from (values (v_last), (v_g), (v_m)) t(x) where x is not null order by (x->>'at')::timestamptz desc limit 1;
  return jsonb_build_object(
    'unread', (select count(*) from public.dm_messages m where m.recipient = v_me and m.read_at is null
                 and not exists(select 1 from public.player_blocks b where b.blocker = v_me and b.blocked = m.sender)),
    'requests', (select count(*) from public.friendships where addressee = v_me and status = 'pending'),
    'last', v_last,
    'g_unread', (select count(*) from public.chat_group_members gm
                   join public.group_messages m on m.group_id = gm.group_id and m.id > gm.last_read_id
                   where gm.player_id = v_me and not gm.muted and m.sender is distinct from v_me and m.kind <> 'system'),
    'm_unread', (select count(*) from public.challenges c
                   join public.challenge_messages m on m.challenge_id = c.id
                   left join public.challenge_reads r on r.challenge_id = c.id and r.player_id = v_me
                   where v_me in (c.creator, c.opponent) and c.status in ('accepted','disputed')
                     and m.sender is distinct from v_me and m.id > coalesce(r.last_read_id, 0)),
    'last_any', v_any);
end;
$$;

-- squad chats + live match chats for the inbox (chat_overview() stays as it is)
create or replace function public.chat_threads()
returns jsonb language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as id)
  select jsonb_build_object(
    'groups', coalesce((select jsonb_agg(x.j order by x.at desc nulls last) from (
      select g.created_at as gat, coalesce(lm.created_at, g.created_at) as at, jsonb_build_object(
        'id', g.id, 'name', g.name, 'muted', gm.muted,
        'count', (select count(*) from public.chat_group_members c where c.group_id = g.id),
        'faces', (select jsonb_agg(public._chat_card(c.player_id, (select id from me)) order by c.joined_at)
                  from (select player_id, joined_at from public.chat_group_members c where c.group_id = g.id and c.player_id <> (select id from me) order by joined_at limit 3) c),
        'last_body', left(case when lm.kind = 'room' then '🎮 Shared a room' else lm.body end, 120), 'last_at', coalesce(lm.created_at, g.created_at),
        'last_mine', lm.sender = (select id from me), 'last_name', case when lm.sender is null then null else public._chat_name(lm.sender) end,
        'unread', (select count(*) from public.group_messages u where u.group_id = g.id and u.id > gm.last_read_id
                     and u.sender is distinct from (select id from me) and u.kind <> 'system')) as j
      from public.chat_group_members gm
      join public.chat_groups g on g.id = gm.group_id
      left join lateral (select * from public.group_messages m where m.group_id = g.id order by m.id desc limit 1) lm on true
      where gm.player_id = (select id from me)
    ) x), '[]'::jsonb),
    'matches', coalesce((select jsonb_agg(x.j order by x.at desc) from (
      select coalesce(lm.created_at, c.accepted_at, c.created_at) as at, jsonb_build_object(
        'id', c.id, 'mode', c.mode, 'stake', c.stake, 'status', c.status, 'map', c.map, 'rounds', c.rounds,
        'room_id', c.room_id, 'room_pass', c.room_pass, 'creator', c.creator = (select id from me),
        'other', public._chat_card(case when c.creator = (select id from me) then c.opponent else c.creator end, (select id from me)),
        'last_body', left(lm.body, 120), 'last_at', coalesce(lm.created_at, c.accepted_at), 'last_mine', lm.sender = (select id from me),
        'unread', case when c.status in ('accepted','disputed') then (select count(*) from public.challenge_messages u where u.challenge_id = c.id
                     and u.id > coalesce(r.last_read_id, 0) and u.sender is distinct from (select id from me)) else 0 end) as j
      from public.challenges c
      left join public.challenge_reads r on r.challenge_id = c.id and r.player_id = (select id from me)
      left join lateral (select * from public.challenge_messages m where m.challenge_id = c.id order by m.id desc limit 1) lm on true
      where (select id from me) in (c.creator, c.opponent) and c.opponent is not null
        and (c.status in ('accepted','disputed') or (c.status = 'completed' and c.resolved_at > now() - interval '3 days'))
    ) x), '[]'::jsonb)
  )
  where (select id from me) is not null
$$;

revoke all on function public.create_group_chat(text, uuid[]) from public, anon;
revoke all on function public.add_group_members(uuid, uuid[]) from public, anon;
revoke all on function public.leave_group_chat(uuid) from public, anon;
revoke all on function public.rename_group_chat(uuid, text) from public, anon;
revoke all on function public.mute_group_chat(uuid, boolean) from public, anon;
revoke all on function public.send_group_message(uuid, text, text) from public, anon;
revoke all on function public.group_thread(uuid, bigint) from public, anon;
revoke all on function public.group_info(uuid) from public, anon;
revoke all on function public.group_mark_read(uuid) from public, anon;
revoke all on function public.challenge_mark_read(uuid) from public, anon;
revoke all on function public.dm_poll() from public, anon;
revoke all on function public.chat_threads() from public, anon;
grant execute on function public.create_group_chat(text, uuid[]) to authenticated;
grant execute on function public.add_group_members(uuid, uuid[]) to authenticated;
grant execute on function public.leave_group_chat(uuid) to authenticated;
grant execute on function public.rename_group_chat(uuid, text) to authenticated;
grant execute on function public.mute_group_chat(uuid, boolean) to authenticated;
grant execute on function public.send_group_message(uuid, text, text) to authenticated;
grant execute on function public.group_thread(uuid, bigint) to authenticated;
grant execute on function public.group_info(uuid) to authenticated;
grant execute on function public.group_mark_read(uuid) to authenticated;
grant execute on function public.challenge_mark_read(uuid) to authenticated;
grant execute on function public.dm_poll() to authenticated;
grant execute on function public.chat_threads() to authenticated;

-- ── push (chat-push Edge Function) ──
create or replace function public.chat_messages_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_ids bigint[];
begin
  select array_agg(id) into v_ids from new_rows;
  if v_ids is null then return null; end if;
  begin
    perform net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/chat-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
      ),
      body := jsonb_build_object('kind', case when TG_TABLE_NAME = 'group_messages' then 'group' else 'match' end, 'ids', to_jsonb(v_ids))
    );
  exception when others then
    raise warning 'chat_messages_push: %', sqlerrm;
  end;
  return null;
end;
$$;
revoke all on function public.chat_messages_push() from public, anon, authenticated;
drop trigger if exists group_messages_push on public.group_messages;
create trigger group_messages_push after insert on public.group_messages
  referencing new table as new_rows for each statement execute function public.chat_messages_push();
drop trigger if exists challenge_messages_push on public.challenge_messages;
create trigger challenge_messages_push after insert on public.challenge_messages
  referencing new table as new_rows for each statement execute function public.chat_messages_push();

-- retention: squad chat messages are deleted after 180 days (stated on /privacy/)
do $$
declare d text;
begin
  select pg_get_functiondef('public.purge_old_personal_data()'::regprocedure) into d;
  if position('group_messages' in d) = 0 then
    d := replace(d, E'  return jsonb_build_object(',
      E'  delete from public.group_messages where created_at < now() - interval ''180 days'';\n  return jsonb_build_object(');
    execute d;
  end if;
end $$;
commit;

-- ── Messages v3: ZULU (AI) inside squad and match chats ─────────────────────────────────
-- * "@zulu …" in a squad chat or a match chat gets an answer from ZULU in that chat. The
--   chat-push Edge Function sees every new message anyway (membership and send limits are
--   already enforced by send_group_message / send_challenge_message), asks the AI with the
--   last few lines of that chat, and inserts the reply with the service role as kind 'ai'
--   and no sender — players can't post as ZULU, and chat-push never answers a row without
--   a sender, so ZULU can't trigger itself. Calls count towards zulu_ai_reply_log's daily cap.
-- * challenge_messages gets a kind column ('text' | 'ai') so a ZULU line isn't mistaken for
--   a message from a deleted player (sender is also null then).
-- * dm_poll / chat_threads name ZULU's lines "ZULU". Idempotent.
begin;
alter table public.group_messages drop constraint if exists group_messages_kind_check;
alter table public.group_messages add constraint group_messages_kind_check check (kind in ('text','system','room','ai'));
alter table public.challenge_messages add column if not exists kind text not null default 'text';
alter table public.challenge_messages drop constraint if exists challenge_messages_kind_check;
alter table public.challenge_messages add constraint challenge_messages_kind_check check (kind in ('text','ai'));

create or replace function public.dm_poll()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_last jsonb; v_g jsonb; v_m jsonb; v_any jsonb;
begin
  if v_me is null then return null; end if;
  update public.players set last_seen_at = now()
    where id = v_me and (last_seen_at is null or last_seen_at < now() - interval '1 minute');
  select jsonb_build_object('id', m.id, 'kind', 'dm', 'key', m.sender, 'from', m.sender, 'name', public._chat_name(m.sender), 'body', left(m.body, 140), 'at', m.created_at)
    into v_last
    from public.dm_messages m
    where m.recipient = v_me and m.read_at is null and not public._blocked_either(v_me, m.sender)
    order by m.id desc limit 1;
  select jsonb_build_object('id', m.id, 'kind', 'group', 'key', m.group_id, 'from', m.sender, 'name', coalesce(public._chat_name(m.sender), 'ZULU'),
      'title', g.name, 'body', left(case when m.kind = 'room' then '🎮 Shared a room' else m.body end, 140), 'at', m.created_at)
    into v_g
    from public.chat_group_members gm
    join public.group_messages m on m.group_id = gm.group_id and m.id > gm.last_read_id
    join public.chat_groups g on g.id = gm.group_id
    where gm.player_id = v_me and not gm.muted and m.sender is distinct from v_me and m.kind <> 'system'
    order by m.id desc limit 1;
  select jsonb_build_object('id', m.id, 'kind', 'match', 'key', c.id, 'from', m.sender, 'name', coalesce(public._chat_name(m.sender), 'ZULU'),
      'title', c.mode || ' challenge', 'body', left(m.body, 140), 'at', m.created_at)
    into v_m
    from public.challenges c
    join public.challenge_messages m on m.challenge_id = c.id
    left join public.challenge_reads r on r.challenge_id = c.id and r.player_id = v_me
    where v_me in (c.creator, c.opponent) and c.status in ('accepted','disputed')
      and m.sender is distinct from v_me and m.id > coalesce(r.last_read_id, 0)
    order by m.id desc limit 1;
  select x into v_any from (values (v_last), (v_g), (v_m)) t(x) where x is not null order by (x->>'at')::timestamptz desc limit 1;
  return jsonb_build_object(
    'unread', (select count(*) from public.dm_messages m where m.recipient = v_me and m.read_at is null
                 and not exists(select 1 from public.player_blocks b where b.blocker = v_me and b.blocked = m.sender)),
    'requests', (select count(*) from public.friendships where addressee = v_me and status = 'pending'),
    'last', v_last,
    'g_unread', (select count(*) from public.chat_group_members gm
                   join public.group_messages m on m.group_id = gm.group_id and m.id > gm.last_read_id
                   where gm.player_id = v_me and not gm.muted and m.sender is distinct from v_me and m.kind <> 'system'),
    'm_unread', (select count(*) from public.challenges c
                   join public.challenge_messages m on m.challenge_id = c.id
                   left join public.challenge_reads r on r.challenge_id = c.id and r.player_id = v_me
                   where v_me in (c.creator, c.opponent) and c.status in ('accepted','disputed')
                     and m.sender is distinct from v_me and m.id > coalesce(r.last_read_id, 0)),
    'last_any', v_any);
end;
$$;

create or replace function public.chat_threads()
returns jsonb language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as id)
  select jsonb_build_object(
    'groups', coalesce((select jsonb_agg(x.j order by x.at desc nulls last) from (
      select g.created_at as gat, coalesce(lm.created_at, g.created_at) as at, jsonb_build_object(
        'id', g.id, 'name', g.name, 'muted', gm.muted,
        'count', (select count(*) from public.chat_group_members c where c.group_id = g.id),
        'faces', (select jsonb_agg(public._chat_card(c.player_id, (select id from me)) order by c.joined_at)
                  from (select player_id, joined_at from public.chat_group_members c where c.group_id = g.id and c.player_id <> (select id from me) order by joined_at limit 3) c),
        'last_body', left(case when lm.kind = 'room' then '🎮 Shared a room' else lm.body end, 120), 'last_at', coalesce(lm.created_at, g.created_at),
        'last_mine', lm.sender = (select id from me), 'last_name', case when lm.kind = 'ai' then 'ZULU' when lm.sender is null then null else public._chat_name(lm.sender) end,
        'unread', (select count(*) from public.group_messages u where u.group_id = g.id and u.id > gm.last_read_id
                     and u.sender is distinct from (select id from me) and u.kind <> 'system')) as j
      from public.chat_group_members gm
      join public.chat_groups g on g.id = gm.group_id
      left join lateral (select * from public.group_messages m where m.group_id = g.id order by m.id desc limit 1) lm on true
      where gm.player_id = (select id from me)
    ) x), '[]'::jsonb),
    'matches', coalesce((select jsonb_agg(x.j order by x.at desc) from (
      select coalesce(lm.created_at, c.accepted_at, c.created_at) as at, jsonb_build_object(
        'id', c.id, 'mode', c.mode, 'stake', c.stake, 'status', c.status, 'map', c.map, 'rounds', c.rounds,
        'room_id', c.room_id, 'room_pass', c.room_pass, 'creator', c.creator = (select id from me),
        'other', public._chat_card(case when c.creator = (select id from me) then c.opponent else c.creator end, (select id from me)),
        'last_body', case when lm.kind = 'ai' then 'ZULU: ' else '' end || left(lm.body, 120), 'last_at', coalesce(lm.created_at, c.accepted_at), 'last_mine', lm.sender = (select id from me),
        'unread', case when c.status in ('accepted','disputed') then (select count(*) from public.challenge_messages u where u.challenge_id = c.id
                     and u.id > coalesce(r.last_read_id, 0) and u.sender is distinct from (select id from me)) else 0 end) as j
      from public.challenges c
      left join public.challenge_reads r on r.challenge_id = c.id and r.player_id = (select id from me)
      left join lateral (select * from public.challenge_messages m where m.challenge_id = c.id order by m.id desc limit 1) lm on true
      where (select id from me) in (c.creator, c.opponent) and c.opponent is not null
        and (c.status in ('accepted','disputed') or (c.status = 'completed' and c.resolved_at > now() - interval '3 days'))
    ) x), '[]'::jsonb)
  )
  where (select id from me) is not null
$$;
revoke all on function public.dm_poll() from public, anon;
revoke all on function public.chat_threads() from public, anon;
grant execute on function public.dm_poll() to authenticated;
grant execute on function public.chat_threads() to authenticated;
commit;

-- ── push alert settings ──────────────────────────────────────────────────────────────────
-- Players can switch off phone alerts per type (⚙️ in 💬 Messages and in Notifications):
--   dm (direct messages) · squad (squad chats) · match (match chats) · friends (friend
--   requests, squad chat invites) · challenges (challenge invites and results) · lobby (new
--   open challenges) · wallet (points loaded, withdrawals, prizes)
-- push_prefs.off lists the switched-off types. _shared/push.ts sendPush() drops those players
-- when a message carries that category. Only the push is skipped: notification rows still
-- land in Notification History. Tournament alerts (check-in, room ID, results) and account
-- security alerts have no category and can't be switched off. RPC only. Idempotent.
begin;
create table if not exists public.push_prefs (
  player_id uuid primary key references public.players(id) on delete cascade,
  off text[] not null default '{}',
  updated_at timestamptz not null default now()
);
create index if not exists push_prefs_off_idx on public.push_prefs using gin (off);
alter table public.push_prefs enable row level security; -- no policies: RPC / service role only

create or replace function public.get_push_prefs()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'off', coalesce((select to_jsonb(off) from public.push_prefs where player_id = auth.uid()), '[]'::jsonb),
    'daily_challenge_alert', coalesce((select daily_challenge_alert from public.players where id = auth.uid()), true))
  where auth.uid() is not null
$$;

create or replace function public.set_push_pref(p_type text, p_on boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if p_type not in ('dm','squad','match','friends','challenges','lobby','wallet') then raise exception 'Unknown alert type.'; end if;
  insert into public.push_prefs (player_id, off) values (auth.uid(), '{}') on conflict (player_id) do nothing;
  update public.push_prefs set
    off = case when coalesce(p_on, true) then array_remove(off, p_type)
               else array_append(array_remove(off, p_type), p_type) end,
    updated_at = now()
  where player_id = auth.uid();
  return public.get_push_prefs();
end;
$$;
revoke all on function public.get_push_prefs() from public, anon;
revoke all on function public.set_push_pref(text, boolean) from public, anon;
grant execute on function public.get_push_prefs() to authenticated;
grant execute on function public.set_push_pref(text, boolean) to authenticated;
commit;

-- ── Clash Squad leaderboard (leaderboard.html "⚔️ Clash Squad" tab) ──────────────────────
-- Settled challenges only (status completed, a winner). Per player: matches played, wins,
-- win rate, current win streak, last match. Logged-in players only, and no points or
-- stakes are shown (privacy page: "Challenges" row). Top 50 plus your own row. Idempotent.
begin;
create or replace function public.get_challenge_leaderboard()
returns jsonb language sql stable security definer set search_path = public as $$
  with done as (
    select c.id, c.creator, c.opponent, c.winner, coalesce(c.resolved_at, c.created_at) as at
    from public.challenges c
    where c.status = 'completed' and c.winner is not null and c.opponent is not null
  ),
  sides as (
    select creator as player, winner = creator as won, at from done
    union all
    select opponent, winner = opponent, at from done
  ),
  streaks as (
    -- wins since the player's last loss
    select s.player, count(*) filter (where s.won and s.at > coalesce(l.last_loss, '-infinity'::timestamptz)) as streak
    from sides s
    left join (select player, max(at) as last_loss from sides where not won group by player) l on l.player = s.player
    group by s.player
  ),
  agg as (
    select s.player, count(*) as played, count(*) filter (where s.won) as wins, max(s.at) as last_at
    from sides s join public.players p on p.id = s.player
    where not exists (select 1 from public.banned_players b where b.player_id = s.player)
    group by s.player
  ),
  ranked as (
    select a.*, st.streak, rank() over (order by a.wins desc, (a.wins::numeric / a.played) desc, a.played desc) as rk
    from agg a join streaks st on st.player = a.player
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'rank', r.rk, 'id', r.player, 'name', public._chat_name(r.player), 'username', p.username, 'tag', p.player_tag,
        'squad', p.squad_name, 'logo', p.squad_logo, 'played', r.played, 'wins', r.wins,
        'rate', round(100.0 * r.wins / r.played), 'streak', r.streak, 'last_at', r.last_at,
        'me', r.player = auth.uid(), 'friend', public._are_friends(r.player, auth.uid()))
      order by r.rk, r.played desc)
      from (select * from ranked order by rk, played desc limit 50) r join public.players p on p.id = r.player), '[]'::jsonb),
    'me', (select jsonb_build_object('rank', r.rk, 'played', r.played, 'wins', r.wins, 'rate', round(100.0 * r.wins / r.played), 'streak', r.streak)
           from ranked r where r.player = auth.uid()),
    'total', (select count(*) from done))
  where auth.uid() is not null
$$;
revoke all on function public.get_challenge_leaderboard() from public, anon;
grant execute on function public.get_challenge_leaderboard() to authenticated;
commit;

-- ── Clash Squad leaderboard (leaderboard.html "⚔️ Clash Squad" tab) ──────────────────────
-- Settled challenges only (status completed, a winner). Per player: matches played, wins,
-- win rate, current win streak, last match. Logged-in players only, and no points or
-- stakes are shown (privacy page: "Challenges" row). Top 50 plus your own row. No squad logos
-- (they are inline images; 50 of them is too heavy on mobile data). Idempotent.
begin;
create or replace function public.get_challenge_leaderboard()
returns jsonb language sql stable security definer set search_path = public as $$
  with done as (
    select c.id, c.creator, c.opponent, c.winner, coalesce(c.resolved_at, c.created_at) as at
    from public.challenges c
    where c.status = 'completed' and c.winner is not null and c.opponent is not null
  ),
  sides as (
    select creator as player, winner = creator as won, at from done
    union all
    select opponent, winner = opponent, at from done
  ),
  streaks as (
    -- wins since the player's last loss
    select s.player, count(*) filter (where s.won and s.at > coalesce(l.last_loss, '-infinity'::timestamptz)) as streak
    from sides s
    left join (select player, max(at) as last_loss from sides where not won group by player) l on l.player = s.player
    group by s.player
  ),
  agg as (
    select s.player, count(*) as played, count(*) filter (where s.won) as wins, max(s.at) as last_at
    from sides s join public.players p on p.id = s.player
    where not exists (select 1 from public.banned_players b where b.player_id = s.player)
    group by s.player
  ),
  ranked as (
    select a.*, st.streak, rank() over (order by a.wins desc, (a.wins::numeric / a.played) desc, a.played desc) as rk
    from agg a join streaks st on st.player = a.player
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'rank', r.rk, 'id', r.player, 'name', public._chat_name(r.player), 'username', p.username, 'tag', p.player_tag,
        'squad', p.squad_name, 'played', r.played, 'wins', r.wins,
        'rate', round(100.0 * r.wins / r.played), 'streak', r.streak, 'last_at', r.last_at,
        'me', r.player = auth.uid(), 'friend', public._are_friends(r.player, auth.uid()))
      order by r.rk, r.played desc)
      from (select * from ranked order by rk, played desc limit 50) r join public.players p on p.id = r.player), '[]'::jsonb),
    'me', (select jsonb_build_object('rank', r.rk, 'played', r.played, 'wins', r.wins, 'rate', round(100.0 * r.wins / r.played), 'streak', r.streak)
           from ranked r where r.player = auth.uid()),
    'total', (select count(*) from done))
  where auth.uid() is not null
$$;
revoke all on function public.get_challenge_leaderboard() from public, anon;
grant execute on function public.get_challenge_leaderboard() to authenticated;
commit;

-- ── design-style pro effects: skeuo, soft, glass, clay, brutal, mono, maximal, liquid, bento, spatial ──
-- Ten effects drawn from UI design styles (Metal Plate = skeuomorphism, Soft Touch =
-- neumorphism, Frosted = glassmorphism, Clay, Brutal, Mono = minimalism, Overload =
-- maximalism, Liquid Glass, Bento grid, Spatial 3D). All Pro-only. Additive. Idempotent.
begin;
alter table public.registrations drop constraint if exists registrations_effect_check;
alter table public.registrations add constraint registrations_effect_check
  check (effect is null or effect in ('glow','steel','gold','fire','ice','neon','rainbow','galaxy','thunder','legend','bullets','blade',
    'skeuo','soft','glass','clay','brutal','mono','maximal','liquid','bento','spatial'));
alter table public.effect_passes drop constraint if exists effect_passes_effect_check;
alter table public.effect_passes add constraint effect_passes_effect_check
  check (effect in ('glow','steel','gold','fire','ice','neon','rainbow','galaxy','thunder','legend','bullets','blade',
    'skeuo','soft','glass','clay','brutal','mono','maximal','liquid','bento','spatial'));
create or replace function public.fx_tier_ok(p_tier text, p_effect text)
returns boolean language sql immutable as $$
  select case p_tier
    when 'lite' then p_effect in ('glow','steel')
    when 'game' then p_effect in ('gold','fire','ice','neon','rainbow')
    when 'pro'  then p_effect in ('glow','steel','gold','fire','ice','neon','rainbow','galaxy','thunder','legend','bullets','blade',
      'skeuo','soft','glass','clay','brutal','mono','maximal','liquid','bento','spatial')
    else false end;
$$;
commit;

-- ── Messages v4: profile pictures in chat + message requests ─────────────────────────────
-- * Profile pictures (private `avatars` bucket) can now be read by the people you chat
--   with: friends (and pending friend requests, so you can see who's asking), members of a
--   squad chat you're in, and the other captain of a challenge. Still never public, never
--   for blocked players. Anyone else still can't open them.
-- * Message requests: you can message someone who isn't your friend yet once a friend
--   request is pending between you (either way), up to 3 messages until they accept, so
--   "talk by username" works without opening chat up to spam. Friends are unchanged.
-- Additive. Idempotent.
begin;
create or replace function public.can_see_avatar(p_folder text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v uuid; v_me uuid := auth.uid();
begin
  if v_me is null then return false; end if;
  begin v := p_folder::uuid; exception when others then return false; end;
  if v = v_me then return true; end if;
  if public._blocked_either(v_me, v) then return false; end if;
  return exists(select 1 from public.friendships f
                 where least(f.requester, f.addressee) = least(v_me, v) and greatest(f.requester, f.addressee) = greatest(v_me, v))
      or exists(select 1 from public.chat_group_members a join public.chat_group_members b on b.group_id = a.group_id
                 where a.player_id = v_me and b.player_id = v)
      or exists(select 1 from public.challenges c
                 where (c.creator = v_me and c.opponent = v) or (c.creator = v and c.opponent = v_me));
end;
$$;
revoke all on function public.can_see_avatar(text) from public, anon;
grant execute on function public.can_see_avatar(text) to authenticated;

drop policy if exists "avatars select chat contacts" on storage.objects;
create policy "avatars select chat contacts" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and public.can_see_avatar((storage.foldername(name))[1]));

create or replace function public.send_dm(p_to uuid, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); v_id bigint;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  p_body := trim(coalesce(p_body, ''));
  if length(p_body) < 1 or length(p_body) > 500 then raise exception 'Messages must be 1-500 characters.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  if p_to is null or p_to = v_me or public._blocked_either(v_me, p_to) then
    raise exception 'You can only message your friends.';
  end if;
  if not public._are_friends(v_me, p_to) then
    -- message request: needs a pending friend request between you, and at most 3 messages until it's accepted
    if not exists(select 1 from public.friendships f
                   where least(f.requester, f.addressee) = least(v_me, p_to) and greatest(f.requester, f.addressee) = greatest(v_me, p_to)
                     and f.status = 'pending') then
      raise exception 'Send a friend request first, then you can message them.';
    end if;
    if (select count(*) from public.dm_messages where sender = v_me and recipient = p_to) >= 3 then
      raise exception 'You can send 3 messages until they accept your request.';
    end if;
  end if;
  if (select count(*) from public.dm_messages where sender = v_me and created_at > now() - interval '10 seconds') >= 8 then
    raise exception 'Slow down a little.';
  end if;
  insert into public.dm_messages (sender, recipient, body) values (v_me, p_to, p_body) returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.send_dm(uuid, text) from public, anon;
grant execute on function public.send_dm(uuid, text) to authenticated;
commit;


-- ── JD-Optimiers plans: Optimizer Pro / Optimizer Max (2026-10-16) ─────────────────────────────
-- The Windows app (JD-Optimiers.exe) only opens with an active plan. Plans are bought with JD points
-- (1 point = Rs 1): Optimizer Pro 100 points / 30 days, Optimizer Max 170 points / 30 days (Max adds the
-- Panel scan). Buying the same plan again adds 30 days; Pro -> Max converts the Pro days left into Max days
-- (days x 100/170) and adds 30.
-- A PC is linked to an account without the app ever seeing a password (works for Google sign-in too):
--   app: optimizer_link_start(device)  -> code "ABCD-2345" + a poll secret   (anon)
--   player opens jdesport.co.uk/optimizer/link/?c=ABCD-2345, signed in, checks the code matches the app,
--          optimizer_link_approve(code) -> a device token is minted          (authenticated)
--   app: optimizer_link_poll(code, poll) -> the token, exactly once           (anon)
--   app at every start: optimizer_check(token) -> {status: ok|no_plan|revoked, tier, expires_at, username}
-- Only token hashes are stored. 2 PCs per account: linking a third removes the oldest.
-- Admin (grant / revoke / devices) goes through the optimizer-admin Edge Function (service role).
-- Additive. Idempotent. Applied on its own with: supabase db query --linked -f supabase/optimizer.sql
begin;

alter table public.wallet_ledger drop constraint if exists wallet_ledger_reason_check;
alter table public.wallet_ledger add constraint wallet_ledger_reason_check
  check (reason in ('load','entry','effect','withdraw','withdraw_returned','refund','adjust','prize',
                    'challenge_stake','challenge_win','challenge_refund','optimizer'));

create table if not exists public.optimizer_plans (
  player_id uuid primary key references public.players(id) on delete cascade,
  tier text not null check (tier in ('pro','max')),
  expires_at timestamptz not null,
  updated_at timestamptz not null default now(),
  note text
);
alter table public.optimizer_plans enable row level security;
drop policy if exists "players read own optimizer plan" on public.optimizer_plans;
create policy "players read own optimizer plan" on public.optimizer_plans for select using (auth.uid() = player_id);

create table if not exists public.optimizer_devices (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references public.players(id) on delete cascade,
  token_hash text not null unique,
  device_name text not null default 'PC',
  created_at timestamptz not null default now(),
  last_seen timestamptz,
  revoked_at timestamptz
);
create index if not exists optimizer_devices_player on public.optimizer_devices(player_id, created_at);
alter table public.optimizer_devices enable row level security;
-- no policies on purpose: players see their PCs through optimizer_my_status()

create table if not exists public.optimizer_links (
  code text primary key,
  poll_hash text not null,
  device_name text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  approved_by uuid references public.players(id) on delete cascade,
  approved_at timestamptz,
  device_token text            -- handed to the app once by optimizer_link_poll, then cleared
);
alter table public.optimizer_links enable row level security;
-- no policies on purpose

create or replace function public._optimizer_hash(p text)
returns text language sql immutable set search_path = public as $$
  select encode(sha256(convert_to(coalesce(p, ''), 'UTF8')), 'hex');
$$;

create or replace function public._optimizer_random_hex()
returns text language sql volatile set search_path = public as $$
  select encode(sha256(convert_to(gen_random_uuid()::text || gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex');
$$;

create or replace function public._optimizer_price(p_tier text)
returns int language sql immutable set search_path = public as $$
  select case p_tier when 'pro' then 100 when 'max' then 170 end;
$$;

-- Adds p_days of p_tier (see the header for the Pro -> Max rule). Internal: buy + admin grant.
create or replace function public._optimizer_grant(p_player uuid, p_tier text, p_days int, p_note text)
returns public.optimizer_plans language plpgsql security definer set search_path = public as $$
declare
  v_cur public.optimizer_plans;
  v_exp timestamptz;
  v_row public.optimizer_plans;
begin
  if p_tier not in ('pro','max') then raise exception 'Unknown plan.'; end if;
  if p_days is null or p_days < 1 or p_days > 3660 then raise exception 'Days must be 1-3660.'; end if;
  select * into v_cur from public.optimizer_plans where player_id = p_player for update;
  if found and v_cur.expires_at > now() then
    if v_cur.tier = p_tier then
      v_exp := v_cur.expires_at + make_interval(days => p_days);
    elsif v_cur.tier = 'pro' and p_tier = 'max' then
      v_exp := now() + (v_cur.expires_at - now()) * (100.0 / 170.0)::float8 + make_interval(days => p_days);
    else
      raise exception 'You have Optimizer Max until % - renew Max instead.', to_char(v_cur.expires_at, 'DD Mon YYYY');
    end if;
  else
    v_exp := now() + make_interval(days => p_days);
  end if;
  insert into public.optimizer_plans (player_id, tier, expires_at, updated_at, note)
  values (p_player, p_tier, v_exp, now(), p_note)
  on conflict (player_id) do update set tier = excluded.tier, expires_at = excluded.expires_at,
                                        updated_at = now(), note = excluded.note
  returning * into v_row;
  return v_row;
end;
$$;

-- Player buys 30 days with points.
create or replace function public.optimizer_buy(p_tier text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_price int := public._optimizer_price(p_tier);
  v_plan public.optimizer_plans;
  v_bal int;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if v_price is null then raise exception 'Unknown plan.'; end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then raise exception 'Your account is banned.'; end if;
  v_plan := public._optimizer_grant(auth.uid(), p_tier, 30, 'points');
  v_bal := public._wallet_apply(auth.uid(), -v_price, 'optimizer', 'opt:' || p_tier || ':' || gen_random_uuid()::text,
                                'Optimizer ' || initcap(p_tier) || ' - 30 days');
  return jsonb_build_object('tier', v_plan.tier, 'expires_at', v_plan.expires_at, 'paid', v_price, 'balance', v_bal);
end;
$$;

-- Plan, linked PCs and prices for the signed-in player (download page).
create or replace function public.optimizer_my_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_plan public.optimizer_plans;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  select * into v_plan from public.optimizer_plans where player_id = auth.uid();
  return jsonb_build_object(
    'tier', case when v_plan.expires_at > now() then v_plan.tier end,
    'expires_at', case when v_plan.expires_at > now() then v_plan.expires_at end,
    'last_tier', v_plan.tier, 'last_expires_at', v_plan.expires_at,
    'prices', jsonb_build_object('pro', 100, 'max', 170),
    'devices', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.device_name,
                                 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.created_at)
                         from public.optimizer_devices d where d.player_id = auth.uid() and d.revoked_at is null), '[]'::jsonb));
end;
$$;

create or replace function public.optimizer_revoke_device(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  update public.optimizer_devices set revoked_at = now() where id = p_id and player_id = auth.uid() and revoked_at is null;
end;
$$;

-- App: start linking this PC.
create or replace function public.optimizer_link_start(p_device text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_raw bytea;
  v_code text;
  v_poll text := public._optimizer_random_hex();
  i int;
begin
  delete from public.optimizer_links where expires_at < now() - interval '1 day';
  if (select count(*) from public.optimizer_links where created_at > now() - interval '1 minute') >= 60 then
    raise exception 'Too many sign-in requests right now - try again in a minute.';
  end if;
  loop
    v_raw := sha256(convert_to(gen_random_uuid()::text, 'UTF8'));
    v_code := '';
    for i in 0..7 loop
      v_code := v_code || substr(v_chars, (get_byte(v_raw, i) % 32) + 1, 1);
      if i = 3 then v_code := v_code || '-'; end if;
    end loop;
    exit when not exists(select 1 from public.optimizer_links where code = v_code);
  end loop;
  insert into public.optimizer_links (code, poll_hash, device_name, expires_at)
  values (v_code, public._optimizer_hash(v_poll),
          left(coalesce(nullif(regexp_replace(coalesce(p_device, ''), '[^A-Za-z0-9 ._()-]', '', 'g'), ''), 'PC'), 60),
          now() + interval '10 minutes');
  return jsonb_build_object('code', v_code, 'poll', v_poll, 'expires_in', 600);
end;
$$;

-- Approve page: what is being linked (shown next to the code so the player can compare).
create or replace function public.optimizer_link_info(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v public.optimizer_links;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  select * into v from public.optimizer_links where code = upper(trim(p_code));
  if not found or v.expires_at < now() then return jsonb_build_object('status', 'expired'); end if;
  if v.approved_by is not null then return jsonb_build_object('status', 'used'); end if;
  return jsonb_build_object('status', 'pending', 'device', v.device_name, 'expires_at', v.expires_at);
end;
$$;

create or replace function public.optimizer_link_approve(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v public.optimizer_links;
  v_token text := public._optimizer_random_hex();
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then raise exception 'Your account is banned.'; end if;
  select * into v from public.optimizer_links where code = upper(trim(p_code)) for update;
  if not found or v.expires_at < now() then raise exception 'This code has expired - press "Sign in" in the app again.'; end if;
  if v.approved_by is not null then raise exception 'This code was already used.'; end if;
  insert into public.optimizer_devices (player_id, token_hash, device_name) values (auth.uid(), public._optimizer_hash(v_token), v.device_name);
  -- 2 PCs per account: unlink the oldest beyond that
  update public.optimizer_devices set revoked_at = now()
   where id in (select id from public.optimizer_devices where player_id = auth.uid() and revoked_at is null
                order by created_at desc offset 2);
  update public.optimizer_links set approved_by = auth.uid(), approved_at = now(), device_token = v_token where code = v.code;
  return jsonb_build_object('status', 'approved', 'device', v.device_name);
end;
$$;

-- App: waits for the approval; returns the device token exactly once.
create or replace function public.optimizer_link_poll(p_code text, p_poll text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.optimizer_links;
begin
  select * into v from public.optimizer_links where code = upper(trim(p_code)) for update;
  if not found or v.poll_hash <> public._optimizer_hash(p_poll) then return jsonb_build_object('status', 'unknown'); end if;
  if v.device_token is not null then
    update public.optimizer_links set device_token = null where code = v.code;
    return jsonb_build_object('status', 'approved', 'token', v.device_token);
  end if;
  if v.approved_by is not null then return jsonb_build_object('status', 'used'); end if;
  if v.expires_at < now() then return jsonb_build_object('status', 'expired'); end if;
  return jsonb_build_object('status', 'pending');
end;
$$;

-- App at every start. Always answers (never raises) so the app can tell "no" from "offline".
create or replace function public.optimizer_check(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  d public.optimizer_devices;
  p public.optimizer_plans;
  v_user text;
begin
  select * into d from public.optimizer_devices where token_hash = public._optimizer_hash(p_token) and revoked_at is null;
  if not found then return jsonb_build_object('status', 'revoked'); end if;
  update public.optimizer_devices set last_seen = now() where id = d.id;
  select coalesce(username, player_tag) into v_user from public.players where id = d.player_id;
  if exists(select 1 from public.banned_players where player_id = d.player_id) then
    return jsonb_build_object('status', 'no_plan', 'username', v_user, 'reason', 'banned');
  end if;
  select * into p from public.optimizer_plans where player_id = d.player_id and expires_at > now();
  if not found then return jsonb_build_object('status', 'no_plan', 'username', v_user); end if;
  return jsonb_build_object('status', 'ok', 'tier', p.tier, 'expires_at', p.expires_at, 'username', v_user,
                            'server_time', now());
end;
$$;

-- App: "Sign out" (tray menu) unlinks this PC.
create or replace function public.optimizer_unlink(p_token text)
returns void language sql security definer set search_path = public as $$
  update public.optimizer_devices set revoked_at = now() where token_hash = public._optimizer_hash(p_token) and revoked_at is null;
$$;

-- Who may call what. Internal helpers: nobody but the service role.
revoke all on function public._optimizer_hash(text) from public, anon, authenticated;
revoke all on function public._optimizer_random_hex() from public, anon, authenticated;
revoke all on function public._optimizer_price(text) from public, anon, authenticated;
revoke all on function public._optimizer_grant(uuid, text, int, text) from public, anon, authenticated;
revoke all on function public.optimizer_buy(text) from public, anon;
revoke all on function public.optimizer_my_status() from public, anon;
revoke all on function public.optimizer_revoke_device(uuid) from public, anon;
revoke all on function public.optimizer_link_info(text) from public, anon;
revoke all on function public.optimizer_link_approve(text) from public, anon;
grant execute on function public.optimizer_buy(text) to authenticated;
grant execute on function public.optimizer_my_status() to authenticated;
grant execute on function public.optimizer_revoke_device(uuid) to authenticated;
grant execute on function public.optimizer_link_info(text) to authenticated;
grant execute on function public.optimizer_link_approve(text) to authenticated;
revoke all on function public.optimizer_link_start(text) from public;
revoke all on function public.optimizer_link_poll(text, text) from public;
revoke all on function public.optimizer_check(text) from public;
revoke all on function public.optimizer_unlink(text) from public;
grant execute on function public.optimizer_link_start(text) to anon, authenticated;
grant execute on function public.optimizer_link_poll(text, text) to anon, authenticated;
grant execute on function public.optimizer_check(text) to anon, authenticated;
grant execute on function public.optimizer_unlink(text) to anon, authenticated;
grant execute on function public._optimizer_grant(uuid, text, int, text) to service_role;

commit;


-- ── JD-Optimiers plans v2 (2026-10-17) ────────────────────────────────────────────────────────
-- * New prices: Optimizer Pro 49 points, Optimizer Max 99 points (30 days each). Pro -> Max upgrade
--   converts the Pro days left at 49/99.
-- * Optimizer Max perks, while the plan is active:
--     - a 30-day Pro squad effect with every Max purchase (player picks the effect; stacks after any
--       pass they already have, through the same _apply_effect_plan as the effect shop)
--     - early entry: joins "early_access" tournaments 24 h before reg_opens, like app users
--     - verified tag: _display_name shows " ✔" (lobby / room names)
-- * Sharing guard: at most 4 PC links per account per 30 days (the 2-PC cap alone could be rotated).
-- Additive. Idempotent. Applied on its own with: supabase db query --linked -f supabase/optimizer_v2.sql
begin;

create or replace function public._optimizer_price(p_tier text)
returns int language sql immutable set search_path = public as $$
  select case p_tier when 'pro' then 49 when 'max' then 99 end;
$$;
revoke all on function public._optimizer_price(text) from public, anon, authenticated;

create or replace function public._optimizer_is_max(p_player uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.optimizer_plans where player_id = p_player and tier = 'max' and expires_at > now());
$$;
revoke all on function public._optimizer_is_max(uuid) from public, anon, authenticated;

create or replace function public._optimizer_grant(p_player uuid, p_tier text, p_days int, p_note text)
returns public.optimizer_plans language plpgsql security definer set search_path = public as $$
declare
  v_cur public.optimizer_plans;
  v_exp timestamptz;
  v_row public.optimizer_plans;
begin
  if p_tier not in ('pro','max') then raise exception 'Unknown plan.'; end if;
  if p_days is null or p_days < 1 or p_days > 3660 then raise exception 'Days must be 1-3660.'; end if;
  select * into v_cur from public.optimizer_plans where player_id = p_player for update;
  if found and v_cur.expires_at > now() then
    if v_cur.tier = p_tier then
      v_exp := v_cur.expires_at + make_interval(days => p_days);
    elsif v_cur.tier = 'pro' and p_tier = 'max' then
      v_exp := now() + (v_cur.expires_at - now()) * (49.0 / 99.0)::float8 + make_interval(days => p_days);
    else
      raise exception 'You have Optimizer Max until % - renew Max instead.', to_char(v_cur.expires_at, 'DD Mon YYYY');
    end if;
  else
    v_exp := now() + make_interval(days => p_days);
  end if;
  insert into public.optimizer_plans (player_id, tier, expires_at, updated_at, note)
  values (p_player, p_tier, v_exp, now(), p_note)
  on conflict (player_id) do update set tier = excluded.tier, expires_at = excluded.expires_at,
                                        updated_at = now(), note = excluded.note
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function public._optimizer_grant(uuid, text, int, text) from public, anon, authenticated;
grant execute on function public._optimizer_grant(uuid, text, int, text) to service_role;

-- Max perk: one 30-day Pro squad effect. Internal (buy + admin grant).
create or replace function public._optimizer_max_effect(p_player uuid, p_effect text, p_ref text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if p_effect is null or not public.fx_tier_ok('pro', p_effect) then p_effect := 'gold'; end if;
  return public._apply_effect_plan(p_player, 'fx_month', p_effect, null, p_ref);
end;
$$;
revoke all on function public._optimizer_max_effect(uuid, text, text) from public, anon, authenticated;
grant execute on function public._optimizer_max_effect(uuid, text, text) to service_role;

drop function if exists public.optimizer_buy(text);
create or replace function public.optimizer_buy(p_tier text, p_effect text default 'gold')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_price int := public._optimizer_price(p_tier);
  v_plan public.optimizer_plans;
  v_bal int;
  v_ref text := 'opt:' || p_tier || ':' || gen_random_uuid()::text;
  v_fx jsonb;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if v_price is null then raise exception 'Unknown plan.'; end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then raise exception 'Your account is banned.'; end if;
  v_plan := public._optimizer_grant(auth.uid(), p_tier, 30, 'points');
  v_bal := public._wallet_apply(auth.uid(), -v_price, 'optimizer', v_ref, 'Optimizer ' || initcap(p_tier) || ' - 30 days');
  if p_tier = 'max' then v_fx := public._optimizer_max_effect(auth.uid(), p_effect, v_ref); end if;
  return jsonb_build_object('tier', v_plan.tier, 'expires_at', v_plan.expires_at, 'paid', v_price, 'balance', v_bal,
                            'effect', v_fx->>'effect', 'effect_expires_at', v_fx->>'expires_at');
end;
$$;
revoke all on function public.optimizer_buy(text, text) from public, anon;
grant execute on function public.optimizer_buy(text, text) to authenticated;

create or replace function public.optimizer_my_status()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_plan public.optimizer_plans;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  select * into v_plan from public.optimizer_plans where player_id = auth.uid();
  return jsonb_build_object(
    'tier', case when v_plan.expires_at > now() then v_plan.tier end,
    'expires_at', case when v_plan.expires_at > now() then v_plan.expires_at end,
    'last_tier', v_plan.tier, 'last_expires_at', v_plan.expires_at,
    'prices', jsonb_build_object('pro', 49, 'max', 99),
    'links_left', greatest(0, 4 - (select count(*) from public.optimizer_devices
                                    where player_id = auth.uid() and created_at > now() - interval '30 days')),
    'devices', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'name', d.device_name,
                                 'created_at', d.created_at, 'last_seen', d.last_seen) order by d.created_at)
                         from public.optimizer_devices d where d.player_id = auth.uid() and d.revoked_at is null), '[]'::jsonb));
end;
$$;
revoke all on function public.optimizer_my_status() from public, anon;
grant execute on function public.optimizer_my_status() to authenticated;

-- Sharing guard: 4 links / 30 days.
create or replace function public.optimizer_link_approve(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v public.optimizer_links;
  v_token text := public._optimizer_random_hex();
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then raise exception 'Your account is banned.'; end if;
  select * into v from public.optimizer_links where code = upper(trim(p_code)) for update;
  if not found or v.expires_at < now() then raise exception 'This code has expired - press "Sign in" in the app again.'; end if;
  if v.approved_by is not null then raise exception 'This code was already used.'; end if;
  if (select count(*) from public.optimizer_devices where player_id = auth.uid() and created_at > now() - interval '30 days') >= 4 then
    raise exception 'You have linked 4 PCs in the last 30 days - that is the limit. Ask the JD admin if you changed PC.';
  end if;
  insert into public.optimizer_devices (player_id, token_hash, device_name) values (auth.uid(), public._optimizer_hash(v_token), v.device_name);
  update public.optimizer_devices set revoked_at = now()
   where id in (select id from public.optimizer_devices where player_id = auth.uid() and revoked_at is null
                order by created_at desc offset 2);
  update public.optimizer_links set approved_by = auth.uid(), approved_at = now(), device_token = v_token where code = v.code;
  return jsonb_build_object('status', 'approved', 'device', v.device_name);
end;
$$;
revoke all on function public.optimizer_link_approve(text) from public, anon;
grant execute on function public.optimizer_link_approve(text) to authenticated;

-- Verified tag for active Max (lobby / room names); app badge kept.
create or replace function public._display_name(p_player uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce('@' || username, player_tag, 'a player')
         || case when public._optimizer_is_max(id) then ' ✔' else '' end
         || case when app_installed_at is not null then ' 📱' else '' end
  from public.players where id = p_player
$$;

-- Public read of the tag for the site (only true/false, no plan details).
create or replace function public.optimizer_verified(p_players uuid[])
returns table(player_id uuid) language sql stable security definer set search_path = public as $$
  select o.player_id from public.optimizer_plans o
   where o.player_id = any(p_players[1:200]) and o.tier = 'max' and o.expires_at > now();
$$;
revoke all on function public.optimizer_verified(uuid[]) from public;
grant execute on function public.optimizer_verified(uuid[]) to anon, authenticated;

-- Early entry for Max in register_for_tournament(): same window as app users.
do $$
declare d text;
begin
  select pg_get_functiondef('public.register_for_tournament(text,text,text,text,text,text)'::regprocedure) into d;
  if position('_optimizer_is_max' in d) = 0 then
    d := replace(d, E'if (select app_installed_at from public.players where id = auth.uid()) is null then',
                    E'if (select app_installed_at from public.players where id = auth.uid()) is null and not public._optimizer_is_max(auth.uid()) then');
    if position('_optimizer_is_max' in d) = 0 then raise exception 'register_for_tournament early-entry patch did not apply'; end if;
    d := replace(d, E'only JD Arena app users can join before', E'only JD Arena app users and Optimizer Max members can join before');
    execute d;
  end if;
end $$;

commit;


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


begin;
create or replace function public.is_moderator()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.moderators m
    where m.email = lower((select email from auth.users where id = auth.uid()))
  );
$$;
revoke all on function public.is_moderator() from public;
grant execute on function public.is_moderator() to authenticated;
commit;

-- ── hourly "seats open" reminder (added 2026-10-18) ───────────────────────
-- Hourly "seats open — join now" reminder for Open #6, daytime NPT only.
-- Pushes to players NOT currently holding a #6 seat (confirmed/approved/waitlisted);
-- released no-shows are eligible again. Stops itself when #6 fills or starts.
begin;

create table if not exists public.seat_reminder_log (
  slug text not null,
  sent_hour timestamptz not null,
  primary key (slug, sent_hour)
);

create or replace function public.jd_seat_reminder(p_slug text default 'JD Free Fire Open #6')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_start timestamptz;
  v_slots int;
  v_taken int;
  v_open int;
  v_npt timestamptz := now() at time zone 'UTC' + interval '5 hours 45 minutes';
  v_hour timestamptz := date_trunc('hour', now());
  v_sent int := 0;
begin
  select (t->>'start')::timestamptz, (t->>'slots')::int
    into v_start, v_slots
    from public.site_content, jsonb_array_elements(content->'tournaments') t
    where key = 'tournaments' and t->>'name' = p_slug;

  if v_start is null then
    return jsonb_build_object('status','no_tournament');
  end if;

  select count(*) into v_taken from public.registrations
    where tournament_slug = p_slug and status in ('confirmed','approved','waitlisted');
  v_open := coalesce(v_slots,0) - v_taken;

  -- stop the job once the event has started or the bracket is full
  if now() >= v_start or v_open <= 0 then
    perform cron.unschedule(jobid) from cron.job where jobname = 'jd-seat-reminder';
    return jsonb_build_object('status','stopped','open',v_open,'started', now() >= v_start);
  end if;

  -- daytime only: 08:00–21:00 Nepal time
  if extract(hour from v_npt) < 8 or extract(hour from v_npt) >= 21 then
    return jsonb_build_object('status','quiet_hours','npt_hour', extract(hour from v_npt));
  end if;

  -- one send per clock hour
  insert into public.seat_reminder_log(slug, sent_hour) values (p_slug, v_hour)
  on conflict do nothing;
  if not found then
    return jsonb_build_object('status','already_sent_this_hour');
  end if;

  insert into public.notifications (player_id, tournament_slug, title, body, push)
  select pl.id, p_slug,
    '🔥 Open #6 seats open — join now!',
    v_open || ' seat' || case when v_open=1 then '' else 's' end ||
    ' just opened for JD Free Fire Open #6 (Mon Oct 19, 9:30 PM NPT · free entry · mobile). Grab yours at jdesport.co.uk — tap Join. Only register if you''ll actually show up: no-shows risk a ban from future tournaments.',
    true
  from public.players pl
  where pl.id not in (
    select player_id from public.registrations
    where tournament_slug = p_slug and status in ('confirmed','approved','waitlisted')
  );
  get diagnostics v_sent = row_count;
  return jsonb_build_object('status','sent','open',v_open,'notified',v_sent);
end;
$$;

revoke all on function public.jd_seat_reminder(text) from public, anon, authenticated;
grant execute on function public.jd_seat_reminder(text) to service_role;

-- schedule hourly (guards daytime + dedup internally); replace if it already exists
select cron.unschedule(jobid) from cron.job where jobname = 'jd-seat-reminder';
select cron.schedule('jd-seat-reminder', '15 * * * *', $cron$select public.jd_seat_reminder()$cron$);

commit;


-- ── admin alert on new withdrawal requests + Zulu real-time announcements (2026-10-18) ──
begin;

create index if not exists notifications_created_at_idx on public.notifications(created_at);

-- 1) tell the owner whenever a player files a withdrawal (pushes via notifications_push)
create or replace function public.notify_admin_withdrawal() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_admin uuid;
begin
  select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com' limit 1;
  if v_admin is not null then
    insert into public.notifications (player_id, title, body)
    values (v_admin,
      '💸 New withdrawal request: Rs ' || NEW.amount,
      'A player requested to withdraw Rs ' || NEW.amount || ' to eSewa ' || NEW.esewa_id ||
      ' (' || NEW.esewa_name || '). Review and pay it in Admin → Wallet → Withdrawals.');
  end if;
  return NEW;
end; $$;
revoke all on function public.notify_admin_withdrawal() from public, anon, authenticated;
drop trigger if exists trg_notify_admin_withdrawal on public.withdraw_requests;
create trigger trg_notify_admin_withdrawal after insert on public.withdraw_requests
  for each row execute function public.notify_admin_withdrawal();

-- 2) recent broadcast announcements for ZULU's context. Privacy: broadcasts only
--    (>=10 distinct recipients, last 3 days), never room codes, tickets, or
--    wallet/prize/withdraw messages. Titles only, max 5.
create or replace function public.recent_announcements()
returns table(title text, body text)
language sql stable security definer set search_path = public as $$
  select title, body from (
    select n.title, n.body, count(distinct n.player_id) as recips, max(n.created_at) as last_at
    from public.notifications n
    where n.created_at > now() - interval '3 days'
      and n.room_id is null and n.room_pass is null
      and n.title not like 'Room code%'
      and coalesce(n.body,'') not like 'TICKET::%'
      and n.title !~* 'withdraw|prize|wallet|points|🪙|💸'
      and coalesce(n.body,'') !~* 'wallet|withdraw|esewa|prize for|points were added'
    group by n.title, n.body
    having count(distinct n.player_id) >= 10
    order by max(n.created_at) desc
    limit 5
  ) x;
$$;
revoke all on function public.recent_announcements() from public, anon, authenticated;
grant execute on function public.recent_announcements() to service_role;

commit;


-- ── 1% withdrawal platform fee, minimum 1 point (2026-10-18) ──
-- Player is debited the full amount; platform keeps the fee; player receives `payout`.
-- Old rows keep fee 0 / payout = amount (free), so past withdrawals are unaffected.
begin;

alter table public.withdraw_requests add column if not exists fee int not null default 0;
alter table public.withdraw_requests add column if not exists payout int;
update public.withdraw_requests set payout = amount where payout is null;

create or replace function public.request_withdrawal(p_amount integer, p_esewa_id text, p_esewa_name text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare
  v_req public.withdraw_requests;
  v_bal int;
  v_fee int;
  v_payout int;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  perform public._assert_open();
  if exists(select 1 from public.wallets where player_id = auth.uid() and unlimited) then
    raise exception 'The admin wallet has unlimited points, so it can''t be withdrawn.';
  end if;
  if (select count(*) from public.withdraw_requests where player_id = auth.uid() and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'Too many withdrawal requests — please wait an hour and try again.';
  end if;
  if p_amount is null or p_amount < 1 then raise exception 'Enter how many points to withdraw.'; end if;
  -- 1% platform fee, at least 1 point. Net payout must be at least 1 point.
  v_fee := greatest(1, ceil(p_amount::numeric / 100))::int;
  v_payout := p_amount - v_fee;
  if v_payout < 1 then
    raise exception 'Withdraw at least 2 points (a 1%% platform fee, minimum 1 point, applies).';
  end if;
  p_esewa_id := trim(coalesce(p_esewa_id, ''));
  p_esewa_name := trim(coalesce(p_esewa_name, ''));
  if length(p_esewa_id) < 5 or length(p_esewa_id) > 40 then
    raise exception 'Enter your eSewa ID (the phone number or email on your eSewa account).';
  end if;
  if length(p_esewa_name) < 2 or length(p_esewa_name) > 60 then
    raise exception 'Enter the name on your eSewa account.';
  end if;
  insert into public.withdraw_requests (player_id, amount, esewa_id, esewa_name, fee, payout)
  values (auth.uid(), p_amount, p_esewa_id, p_esewa_name, v_fee, v_payout) returning * into v_req;
  v_bal := public._wallet_apply(auth.uid(), -p_amount, 'withdraw', v_req.id::text, null);
  return jsonb_build_object('id', v_req.id, 'amount', p_amount, 'fee', v_fee, 'payout', v_payout, 'balance', v_bal);
end; $function$;
revoke all on function public.request_withdrawal(integer, text, text) from public, anon, authenticated;
grant execute on function public.request_withdrawal(integer, text, text) to authenticated;

-- resolver: tell the player the NET amount actually sent (payout), fall back to amount for old rows
create or replace function public.admin_resolve_withdrawal(p_id uuid, p_paid boolean, p_payout_ref text)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_req public.withdraw_requests; v_net int;
begin
  update public.withdraw_requests
    set status = case when p_paid then 'paid' else 'rejected' end, processed_at = now(),
        payout_ref = nullif(trim(coalesce(p_payout_ref, '')), '')
    where id = p_id and status = 'pending'
    returning * into v_req;
  if v_req.id is null then raise exception 'This withdrawal was already processed.'; end if;
  if p_paid then
    v_net := coalesce(v_req.payout, v_req.amount);
    insert into public.notifications (player_id, title, body)
    values (v_req.player_id, '💸 Withdrawal sent: Rs ' || v_net,
            'Rs ' || v_net || ' was sent to your eSewa (' || v_req.esewa_id || ')' ||
            coalesce(' · ref ' || v_req.payout_ref, '') ||
            case when coalesce(v_req.fee,0) > 0 then ' · after a ' || v_req.fee || '-point platform fee' else '' end || '.');
  else
    perform public._wallet_apply(v_req.player_id, v_req.amount, 'withdraw_returned', v_req.id::text, null);
    insert into public.notifications (player_id, title, body)
    values (v_req.player_id, 'Withdrawal not processed',
            'Your withdrawal of ' || v_req.amount || ' points could not be sent, so the points were returned to your wallet. Please check your eSewa details or contact us on WhatsApp.');
  end if;
  return jsonb_build_object('id', v_req.id, 'status', v_req.status, 'payout', coalesce(v_req.payout, v_req.amount));
end; $function$;
revoke all on function public.admin_resolve_withdrawal(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.admin_resolve_withdrawal(uuid, boolean, text) to service_role;

commit;

-- ── squad-name uniqueness per tournament (2026-10-18) ──
begin;
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

  declare v_open timestamptz;
  begin
    if lower(coalesce(public.tournament_field(p_tournament_slug, 'early_access'), '')) in ('yes','true')
       and not exists(select 1 from public.registrations where tournament_slug = p_tournament_slug and player_id = auth.uid()) then
      begin v_open := nullif(public.tournament_field(p_tournament_slug, 'reg_opens'), '')::timestamptz;
      exception when others then v_open := null; end;
      if v_open is not null and now() < v_open then
        if now() < v_open - interval '24 hours' then
          raise exception 'Registration opens at % (app users 24 hours earlier).', to_char(v_open at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM') || ' NPT';
        end if;
        if (select app_installed_at from public.players where id = auth.uid()) is null and not public._optimizer_is_max(auth.uid()) then
          raise exception 'Early access: only JD Arena app users and Optimizer Max members can join before %. Open the app to join now.', to_char(v_open at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM') || ' NPT';
        end if;
      end if;
    end if;
  end;
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
    -- squad name must be unique within this tournament (case-insensitive)
    if exists(select 1 from public.registrations r
              where r.tournament_slug = p_tournament_slug
                and r.player_id <> auth.uid()
                and r.status in ('confirmed','approved','waitlisted','pending')
                and lower(trim(r.squad_name)) = lower(trim(v_name))) then
      raise exception 'That squad name is already taken for this event — please pick a different name.';
    end if;
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
$function$
;
commit;

-- ── confirm-or-be-removed rule (2026-10-18) ──
-- Squads must CONFIRM they're playing. The sweep reminds unconfirmed squads in the
-- 48h→24h window before start, then at 24h-before removes the ones still unconfirmed
-- (logged + deleted so they can re-register), refunding any entry points. Runs hourly.
begin;

create table if not exists public.jd_no_show_log (
  id bigserial primary key,
  tournament_slug text not null,
  player_id uuid,
  squad_name text,
  reason text not null default 'did_not_confirm',
  removed_at timestamptz not null default now()
);
alter table public.jd_no_show_log enable row level security;

create table if not exists public.jd_confirm_reminders (tournament_slug text primary key, sent_at timestamptz not null default now());
create table if not exists public.jd_confirm_sweeps   (tournament_slug text primary key, swept_at timestamptz not null default now());

-- player confirms attendance (any time from registration until start). Idempotent.
create or replace function public.confirm_attendance(p_slug text)
returns public.registrations language plpgsql security definer set search_path = public as $$
declare v_row public.registrations; v_start timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  v_start := public.tournament_start_at(p_slug);
  if v_start is not null and now() >= v_start then raise exception 'This tournament has already started.'; end if;
  update public.registrations set checked_in_at = coalesce(checked_in_at, now())
    where tournament_slug = p_slug and player_id = auth.uid() and status in ('confirmed','approved')
    returning * into v_row;
  if not found then raise exception 'No confirmed registration found for this tournament.'; end if;
  return v_row;
end; $$;
revoke all on function public.confirm_attendance(text) from public, anon;
grant execute on function public.confirm_attendance(text) to authenticated;

-- hourly sweep: remind (48h→24h), then remove unconfirmed (at 24h-before)
create or replace function public.jd_confirm_sweep()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_doc jsonb; t record; r record;
  v_removed int := 0; v_reminded int := 0; v_tmp int := 0;
begin
  select content into v_doc from public.site_content where key = 'tournaments';
  for t in
    select (x->>'name') as name, (x->>'start')::timestamptz as start_at,
           coalesce(x->>'date','') as d, coalesce(x->>'time','') as tm
    from jsonb_array_elements(coalesce(v_doc->'tournaments','[]'::jsonb)) x
    where nullif(x->>'start','') is not null
      and lower(coalesce(x->>'status','upcoming')) not in ('completed','cancelled')
  loop
    if t.start_at is null then continue; end if;

    -- 1) remind: in the 48h→24h window before start, once
    if now() >= t.start_at - interval '48 hours' and now() < t.start_at - interval '24 hours' then
      begin
        insert into public.jd_confirm_reminders(tournament_slug) values (t.name);
        insert into public.notifications (player_id, tournament_slug, title, body, push)
        select r2.player_id, t.name,
          '⚠️ Confirm your spot: ' || t.name,
          'Open JD Esports Arena and tap "Confirm you''re playing" for ' || t.name ||
          ' (' || nullif(t.d,'') || ' ' || nullif(t.tm,'') || '). Squads not confirmed by 24 hours before start lose their seat to another team. We need real players!',
          true
        from public.registrations r2
        where r2.tournament_slug = t.name and r2.status in ('confirmed','approved') and r2.checked_in_at is null;
        get diagnostics v_tmp = row_count; v_reminded := v_reminded + v_tmp;
      exception when unique_violation then null; end;
    end if;

    -- 2) remove: once we're within 24h of start (and it hasn't started), remove unconfirmed
    if now() >= t.start_at - interval '24 hours' and now() < t.start_at then
      begin
        insert into public.jd_confirm_sweeps(tournament_slug) values (t.name);
        for r in select * from public.registrations
                 where tournament_slug = t.name and status in ('confirmed','approved') and checked_in_at is null
        loop
          insert into public.jd_no_show_log(tournament_slug, player_id, squad_name, reason)
            values (t.name, r.player_id, r.squad_name, 'did_not_confirm');
          if coalesce(r.paid_points,0) > 0 then
            perform public._wallet_apply(r.player_id, r.paid_points, 'refund', 'noshow_refund:'||r.id::text,
                     'Auto-refund: removed from '||t.name||' for not confirming');
          end if;
          insert into public.notifications (player_id, tournament_slug, title, body)
            values (r.player_id, t.name, '❌ Removed from ' || t.name || ' — not confirmed',
              'You didn''t confirm you were playing by the deadline (24h before start), so your seat went to another squad. ' ||
              case when coalesce(r.paid_points,0) > 0 then 'Your entry points were refunded. ' else '' end ||
              'You can register again if seats are open — please confirm next time. Repeated no-shows can be banned from future tournaments.');
          delete from public.registrations where id = r.id;  -- delete so they can re-register
          v_removed := v_removed + 1;
        end loop;
      exception when unique_violation then null; end;
    end if;
  end loop;
  return jsonb_build_object('reminded', v_reminded, 'removed', v_removed);
end; $$;
revoke all on function public.jd_confirm_sweep() from public, anon, authenticated;
grant execute on function public.jd_confirm_sweep() to service_role;

select cron.unschedule(jobid) from cron.job where jobname = 'jd-confirm-sweep';
select cron.schedule('jd-confirm-sweep', '25 * * * *', $cron$select public.jd_confirm_sweep()$cron$);

commit;

-- ── confirm-sweep v2 + admin net-payout alert + balances net (2026-10-18) ──
begin;

-- admin withdrawal alert: show the NET amount to send (payout), not the gross
create or replace function public.notify_admin_withdrawal() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_admin uuid;
begin
  select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com' limit 1;
  if v_admin is not null then
    insert into public.notifications (player_id, title, body)
    values (v_admin,
      '💸 New withdrawal request: send Rs ' || coalesce(NEW.payout, NEW.amount),
      'Send Rs ' || coalesce(NEW.payout, NEW.amount) || ' to eSewa ' || NEW.esewa_id ||
      ' (' || NEW.esewa_name || '). Requested ' || NEW.amount || ', fee ' || coalesce(NEW.fee,0) ||
      '. Pay and mark it paid in Admin → Wallet → Withdrawals.');
  end if;
  return NEW;
end; $$;

-- confirm sweep v2: safe start-cast guard, coalesced reminder body, and a
-- "seats open — join now" broadcast whenever a removal frees seats (any tournament).
create or replace function public.jd_confirm_sweep()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_doc jsonb; t record; r record;
  v_removed int := 0; v_reminded int := 0; v_tmp int := 0; v_here int := 0;
  v_slots int; v_taken int; v_open int;
begin
  select content into v_doc from public.site_content where key = 'tournaments';
  for t in
    select (x->>'name') as name, (x->>'start')::timestamptz as start_at,
           coalesce(x->>'date','') as d, coalesce(x->>'time','') as tm
    from jsonb_array_elements(coalesce(v_doc->'tournaments','[]'::jsonb)) x
    where (x->>'start') ~ '^\d{4}-\d{2}-\d{2}T'          -- only valid ISO timestamps
      and lower(coalesce(x->>'status','upcoming')) not in ('completed','cancelled')
  loop
    if t.start_at is null then continue; end if;

    -- 1) remind unconfirmed squads in the 48h→24h window, once per tournament
    if now() >= t.start_at - interval '48 hours' and now() < t.start_at - interval '24 hours' then
      begin
        insert into public.jd_confirm_reminders(tournament_slug) values (t.name);
        insert into public.notifications (player_id, tournament_slug, title, body, push)
        select r2.player_id, t.name,
          '⚠️ Confirm your spot: ' || t.name,
          'Open JD Esports Arena and tap "Confirm you''re playing" for ' || t.name ||
          ' (' || t.d || ' ' || t.tm || '). Squads not confirmed by 24 hours before start lose their seat to another team. We need real players!',
          true
        from public.registrations r2
        where r2.tournament_slug = t.name and r2.status in ('confirmed','approved') and r2.checked_in_at is null;
        get diagnostics v_tmp = row_count; v_reminded := v_reminded + v_tmp;
      exception when unique_violation then null; end;
    end if;

    -- 2) within 24h of start: remove still-unconfirmed squads (once per tournament)
    if now() >= t.start_at - interval '24 hours' and now() < t.start_at then
      begin
        insert into public.jd_confirm_sweeps(tournament_slug) values (t.name);
        v_here := 0;
        for r in select * from public.registrations
                 where tournament_slug = t.name and status in ('confirmed','approved') and checked_in_at is null
        loop
          insert into public.jd_no_show_log(tournament_slug, player_id, squad_name, reason)
            values (t.name, r.player_id, r.squad_name, 'did_not_confirm');
          if coalesce(r.paid_points,0) > 0 then
            perform public._wallet_apply(r.player_id, r.paid_points, 'refund', 'noshow_refund:'||r.id::text,
                     'Auto-refund: removed from '||t.name||' for not confirming');
          end if;
          insert into public.notifications (player_id, tournament_slug, title, body)
            values (r.player_id, t.name, '❌ Removed from ' || t.name || ' — not confirmed',
              'You didn''t confirm you were playing by the deadline (24h before start), so your seat went to another squad. ' ||
              case when coalesce(r.paid_points,0) > 0 then 'Your entry points were refunded. ' else '' end ||
              'You can register again if seats are open — please confirm next time. Repeated no-shows can be banned from future tournaments.');
          delete from public.registrations where id = r.id;
          v_here := v_here + 1;
        end loop;
        v_removed := v_removed + v_here;

        -- freed seats? broadcast "join now" to players not registered for this tournament
        if v_here > 0 then
          select slots into v_slots from public.tournament_capacity where tournament_slug = t.name;
          select count(*) into v_taken from public.registrations
            where tournament_slug = t.name and status in ('confirmed','approved','waitlisted');
          v_open := coalesce(v_slots,0) - v_taken;
          if v_open > 0 then
            insert into public.notifications (player_id, tournament_slug, title, body, push)
            select pl.id, t.name,
              '🔥 Seats open — join ' || t.name || ' now!',
              v_open || ' seat' || case when v_open=1 then '' else 's' end || ' just opened for ' || t.name ||
              ' (' || t.d || ' ' || t.tm || '). Register at jdesport.co.uk — and confirm your spot after. Only join if you''ll actually play.',
              true
            from public.players pl
            where pl.id not in (select player_id from public.registrations
                                where tournament_slug = t.name and status in ('confirmed','approved','waitlisted'));
          end if;
        end if;
      exception when unique_violation then null; end;
    end if;
  end loop;
  return jsonb_build_object('reminded', v_reminded, 'removed', v_removed);
end; $$;

commit;

-- ── confirm window 48h->24h (2026-10-18) ──
create or replace function public.confirm_attendance(p_slug text)
returns public.registrations language plpgsql security definer set search_path = public as $$
declare v_row public.registrations; v_start timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  v_start := public.tournament_start_at(p_slug);
  if v_start is not null then
    if now() < v_start - interval '48 hours' then
      raise exception 'Confirmation opens 48 hours before the match (at % NPT).',
        to_char((v_start - interval '48 hours') at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM');
    end if;
    if now() >= v_start - interval '24 hours' then
      raise exception 'Confirmation has closed (it closes 24 hours before start).';
    end if;
  end if;
  update public.registrations set checked_in_at = coalesce(checked_in_at, now())
    where tournament_slug = p_slug and player_id = auth.uid() and status in ('confirmed','approved')
    returning * into v_row;
  if not found then raise exception 'No confirmed registration found for this tournament.'; end if;
  return v_row;
end; $$;
revoke all on function public.confirm_attendance(text) from public, anon;
grant execute on function public.confirm_attendance(text) to authenticated;

-- ── admin money in/out dashboard (2026-10-18) ──
-- Real cash: IN = points loaded via eSewa (reason 'load'); OUT = paid withdrawals (net payout).
-- Points kept (earned) and given (prizes/comp) are internal. Owner's unlimited wallet excluded.
begin;

create or replace function public._money_window(p_since timestamptz)
returns jsonb language sql stable security definer set search_path = public as $$
  with led as (
    select l.reason, l.delta from public.wallet_ledger l
    join public.wallets w on w.player_id = l.player_id and coalesce(w.unlimited,false) = false
    where (p_since is null or l.created_at >= p_since)
  ),
  wd as (
    select status, coalesce(payout, amount) as net, coalesce(fee,0) as fee
    from public.withdraw_requests
    where (p_since is null or created_at >= p_since)
  )
  select jsonb_build_object(
    'cash_in',         (select coalesce(sum(delta),0) from led where reason = 'load'),
    'cash_out_paid',   (select coalesce(sum(net),0)  from wd  where status = 'paid'),
    'pending_payouts', (select coalesce(sum(net),0)  from wd  where status = 'pending'),
    'fees_collected',  (select coalesce(sum(fee),0)  from wd  where status = 'paid'),
    'prize_given',     (select coalesce(sum(delta),0) from led where reason = 'prize'),
    'adjust_given',    (select coalesce(sum(delta),0) from led where reason = 'adjust'),
    'earned_points',   (select coalesce(-sum(delta),0) from led
                         where reason in ('entry','effect','optimizer','challenge_stake','refund','challenge_win','challenge_refund'))
  );
$$;
revoke all on function public._money_window(timestamptz) from public, anon, authenticated;
grant execute on function public._money_window(timestamptz) to service_role;

create or replace function public.admin_money_flow()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_day   timestamptz := (date_trunc('day',   now() at time zone 'Asia/Kathmandu')) at time zone 'Asia/Kathmandu';
  v_month timestamptz := (date_trunc('month', now() at time zone 'Asia/Kathmandu')) at time zone 'Asia/Kathmandu';
  v_all jsonb := public._money_window(null);
begin
  return jsonb_build_object(
    'owed_points',   (select coalesce(sum(balance),0) from public.wallets where coalesce(unlimited,false) = false),
    'cash_on_esewa', ((v_all->>'cash_in')::int - (v_all->>'cash_out_paid')::int),
    'all',   v_all,
    'month', public._money_window(v_month),
    'today', public._money_window(v_day)
  );
end; $$;
revoke all on function public.admin_money_flow() from public, anon, authenticated;
grant execute on function public.admin_money_flow() to service_role;

commit;


-- ── leaderboard season standings + squad logos (2026-10-18) ──
-- ── leaderboard: season standings + per-tournament squad logos (2026-10-18) ──
begin;

-- Combined season standings from archived results (public data only).
create or replace function public.get_season_standings()
returns table(squad_name text, events int, points bigint, kills bigint, wins int, best_place int, prize numeric)
language sql stable security definer set search_path = public as $$
  select max(tr.squad_name) as squad_name,
         count(distinct tr.tournament_slug)::int as events,
         sum(tr.points)::bigint as points,
         sum(tr.kills)::bigint as kills,
         sum(case when tr.placement = 1 then 1 else 0 end)::int as wins,
         min(tr.placement)::int as best_place,
         sum(tr.prize_won) as prize
  from public.tournament_results tr
  group by lower(trim(tr.squad_name))
  order by sum(tr.points) desc, sum(tr.kills) desc, max(tr.squad_name) asc;
$$;
revoke all on function public.get_season_standings() from public;
grant execute on function public.get_season_standings() to anon, authenticated;

-- Logos for the squads registered in one tournament (reg logo, else the player's saved one).
create or replace function public.get_squad_logos(p_slug text)
returns table(squad_name text, logo text)
language sql stable security definer set search_path = public as $$
  select r.squad_name, coalesce(nullif(r.squad_logo, ''), p.squad_logo) as logo
  from public.registrations r
  join public.players p on p.id = r.player_id
  where r.tournament_slug = p_slug
    and r.status in ('confirmed','approved')
    and coalesce(nullif(r.squad_logo, ''), p.squad_logo) is not null;
$$;
revoke all on function public.get_squad_logos(text) from public;
grant execute on function public.get_squad_logos(text) to anon, authenticated;

commit;


-- ── no-show final warning (2026-10-20) ──
-- A squad that registered and didn't show up can register again, but the join form shows
-- a final warning. Counts only real no-shows (did_not_show), not the confirm-deadline sweep.
-- Matches the player's own no-shows and their saved squad's (a teammate may have registered it).
create or replace function public.my_no_show_count()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.jd_no_show_log l
  where l.reason = 'did_not_show'
    and (l.player_id = auth.uid()
         or lower(trim(l.squad_name)) = (select lower(trim(p.squad_name)) from public.players p
                                          where p.id = auth.uid() and coalesce(trim(p.squad_name),'') <> ''));
$$;
revoke all on function public.my_no_show_count() from public, anon;
grant execute on function public.my_no_show_count() to authenticated;

-- ── ZULU sees more of what was announced (2026-10-20) ──
-- 7 days instead of 3, broadcasts to 3+ players (results go to just the squads that played),
-- up to 12. Same privacy filter: no room codes, tickets, wallet/prize/withdraw messages, and
-- per-squad messages (warnings name the squad, so each body is unique and never qualifies).
create or replace function public.recent_announcements()
returns table(title text, body text)
language sql stable security definer set search_path = public as $$
  select title, body from (
    select n.title, n.body, count(distinct n.player_id) as recips, max(n.created_at) as last_at
    from public.notifications n
    where n.created_at > now() - interval '7 days'
      and n.room_id is null and n.room_pass is null
      and n.title not like 'Room code%'
      and coalesce(n.body,'') not like 'TICKET::%'
      and n.title !~* 'withdraw|prize|wallet|points|🪙|💸'
      and coalesce(n.body,'') !~* 'wallet|withdraw|esewa|prize for|points were added'
    group by n.title, n.body
    having count(distinct n.player_id) >= 3
    order by max(n.created_at) desc
    limit 12
  ) x;
$$;
revoke all on function public.recent_announcements() from public, anon, authenticated;
grant execute on function public.recent_announcements() to service_role;

-- ── squad slot numbers (2026-10-22) ──
-- Rule: squads sit in the seat matching their slot in the app. Slot = position among the
-- tournament's active squads (confirmed/approved) by registration time — the same order
-- the mod panel numbers them in. Players can't read other squads' rows, so this runs
-- security definer and returns only the caller's own slots.
create or replace function public.my_tournament_slots()
returns table(tournament_slug text, slot int) language sql stable security definer set search_path = public as $$
  select s.tournament_slug, s.slot from (
    select r.tournament_slug, r.player_id,
           row_number() over (partition by r.tournament_slug order by r.created_at)::int as slot
    from public.registrations r
    where r.status in ('confirmed','approved')
      and r.tournament_slug in (select tournament_slug from public.registrations where player_id = auth.uid())
  ) s where s.player_id = auth.uid();
$$;
revoke all on function public.my_tournament_slots() from public, anon;
grant execute on function public.my_tournament_slots() to authenticated;

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

-- App push diagnostics (2026-10-27): push_fcm_tokens stayed empty after app 2.0 shipped and every client-side
-- failure was silent. home.js ensurePushSubscribed() now reports why a phone couldn't save its Firebase token
-- (one row per player, latest error wins) so the admin can see it. Safe to run again.
begin;

create table if not exists public.app_push_errors (
  player_id uuid primary key references public.players(id) on delete cascade,
  error text not null,
  app_version int,
  permission text,
  at timestamptz not null default now()
);
alter table public.app_push_errors enable row level security;
revoke all on public.app_push_errors from anon, authenticated;

create or replace function public.log_app_push_error(p_error text, p_app_version int default null, p_perm text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.app_push_errors (player_id, error, app_version, permission)
  values (auth.uid(), left(coalesce(p_error, ''), 300), p_app_version, left(p_perm, 20))
  on conflict (player_id) do update set error = excluded.error, app_version = excluded.app_version,
    permission = excluded.permission, at = now();
end $$;

-- a token saved = that phone works now
create or replace function public._clear_app_push_error() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.app_push_errors where player_id = new.player_id;
  return null;
end $$;
drop trigger if exists push_fcm_tokens_clear_error on public.push_fcm_tokens;
create trigger push_fcm_tokens_clear_error after insert or update on public.push_fcm_tokens
  for each row execute function public._clear_app_push_error();

revoke all on function public.log_app_push_error(text, int, text) from public, anon;
grant execute on function public.log_app_push_error(text, int, text) to authenticated;
revoke all on function public._clear_app_push_error() from public, anon, authenticated;
commit;

-- Ads by Weekly Pass tier from 1 Nov 2026 00:00 NPT (owner, 27 Oct): Weekly Pro (and Optimizer Max) = no ads at
-- all; Basic Weekly Pass = still no ads to join free events, but the app's short "hourly" ad at most 2 a day;
-- no pass = unchanged (3 ads to join a free event + up to 1 ad per hour). Before 1 Nov every pass is ad-free.
-- ad_status() gains hourly_ok (ads.js shows the hourly ad only when it is true). Safe to run again.
begin;

create or replace function public._ad_hourly_ok(p_player uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_tier text := public.weekly_pass_tier(p_player, now());
begin
  if v_tier = 'pro' or public._optimizer_is_max(p_player) then return false; end if;
  if v_tier = 'basic' then
    if now() < timestamptz '2026-11-01 00:00:00+05:45' then return false; end if;
    return (select count(*) from public.ad_views where player_id = p_player and kind = 'hourly'
            and viewed_at >= date_trunc('day', now() at time zone 'Asia/Kathmandu') at time zone 'Asia/Kathmandu') < 2;
  end if;
  return true;
end $$;
revoke all on function public._ad_hourly_ok(uuid) from public, anon, authenticated;

create or replace function public.ad_status()
returns json language plpgsql stable security definer set search_path = public as $$
declare c public.ad_config; v_have int; v_last timestamptz; v_due boolean; v_quiet boolean;
begin
  select * into c from public.ad_config where id;
  if auth.uid() is null or not c.enabled or c.ad_unit is null then   -- no ad unit = gate off
    return json_build_object('enabled', false);
  end if;
  select count(*) filter (where used_for is null), max(viewed_at) into v_have, v_last
    from public.ad_views where player_id = auth.uid();
  v_due := v_last is null or v_last + make_interval(mins => c.hourly_minutes) <= now();
  v_quiet := public._ad_quiet(auth.uid());
  return json_build_object('enabled', true, 'unit', c.ad_unit, 'needed', c.ads_needed, 'have', v_have,
    'exempt', public._ad_exempt(auth.uid()),
    'next_at', case when v_last is not null and v_last + make_interval(secs => c.gap_seconds) > now()
                    then v_last + make_interval(secs => c.gap_seconds) end,
    'hourly_due', v_due,
    'hourly_ok', v_due and not v_quiet and public._ad_hourly_ok(auth.uid()),
    'tier', public.weekly_pass_tier(auth.uid(), now()),
    'quiet', v_quiet);
end $$;

create or replace function public.ad_reward_claim(p_kind text default 'gate')
returns json language plpgsql security definer set search_path = public as $$
declare c public.ad_config; v_last timestamptz;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  if p_kind not in ('gate', 'hourly') then raise exception 'Bad ad kind'; end if;
  select * into c from public.ad_config where id;
  if not c.enabled or c.ad_unit is null then raise exception 'Ads are switched off.'; end if;
  perform pg_advisory_xact_lock(hashtext('ad:' || auth.uid()::text));
  select max(viewed_at) into v_last from public.ad_views where player_id = auth.uid();
  if v_last is not null and v_last + make_interval(secs => c.gap_seconds) > now() then
    raise exception 'AD_COOLDOWN: next ad at %', to_char((v_last + make_interval(secs => c.gap_seconds)) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;
  if p_kind = 'hourly' and (public._ad_quiet(auth.uid()) or not public._ad_hourly_ok(auth.uid())
     or (v_last is not null and v_last + make_interval(mins => c.hourly_minutes) > now())) then
    raise exception 'AD_NOT_DUE';
  end if;
  insert into public.ad_views (player_id, kind) values (auth.uid(), p_kind);
  return public.ad_status();
end $$;

grant execute on function public.ad_status() to authenticated;
grant execute on function public.ad_reward_claim(text) to authenticated;
commit;

-- Player's approximate area (2026-10-27, app 2.0.3): only when the player allows location in the Android app.
-- City / district / province / country plus a position rounded to 0.1 degree (~10 km), never the exact spot.
-- Location turned off later = cleared on the next app open. Players read their own row; admins see it in the
-- player list (list-players). Safe to run again.
begin;

alter table public.players add column if not exists area_city text;
alter table public.players add column if not exists area_district text;
alter table public.players add column if not exists area_region text;
alter table public.players add column if not exists area_country text;
alter table public.players add column if not exists area_lat numeric(4,1);
alter table public.players add column if not exists area_lon numeric(4,1);
alter table public.players add column if not exists area_at timestamptz;

create or replace function public.save_my_area(p_city text, p_district text, p_region text, p_country text,
                                               p_lat double precision, p_lon double precision)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  if p_lat is null and p_city is null and p_country is null then   -- location not allowed (any more): forget it
    update public.players set area_city = null, area_district = null, area_region = null, area_country = null,
      area_lat = null, area_lon = null, area_at = null where id = auth.uid() and area_at is not null;
    return;
  end if;
  update public.players set
    area_city = nullif(left(btrim(p_city), 60), ''),
    area_district = nullif(left(btrim(p_district), 60), ''),
    area_region = nullif(left(btrim(p_region), 60), ''),
    area_country = nullif(upper(left(btrim(p_country), 2)), ''),
    area_lat = case when p_lat between -90 and 90 then round(p_lat::numeric, 1) end,
    area_lon = case when p_lon between -180 and 180 then round(p_lon::numeric, 1) end,
    area_at = now()
  where id = auth.uid();
end $$;

revoke all on function public.save_my_area(text, text, text, text, double precision, double precision) from public, anon;
grant execute on function public.save_my_area(text, text, text, text, double precision, double precision) to authenticated;
commit;

-- ── Refund + cancel every Weekly Pass (owner, 27 Oct 2026) ──
-- Each pass gets back what was actually charged for it (wallet 'pass' rows), minus anything already refunded for it
-- (TEAM TIGER's 50 was refunded earlier as passprizefix:...). The pass and its squad effect end now (rows kept for
-- history: expires_at = starts_at, the same way upgrades end a pass). Idempotent: ref passrefund:<id>.
begin;
do $$
declare
  r record;
  v_charged int;
  v_already int;
  v_amt int;
begin
  for r in select wp.*, p.squad_name from public.weekly_passes wp join public.players p on p.id = wp.player_id
           where wp.expires_at > wp.starts_at order by wp.id loop
    if exists (select 1 from public.wallet_ledger where ref = 'passrefund:' || r.id) then continue; end if;
    select coalesce(sum(-delta), 0) into v_charged from public.wallet_ledger
      where player_id = r.player_id and reason = 'pass' and (ref = r.ref or ref like r.ref || ':%');
    if v_charged = 0 then v_charged := r.price; end if;
    select coalesce(sum(delta), 0) into v_already from public.wallet_ledger
      where player_id = r.player_id and reason = 'refund' and ref like 'passprizefix:%'
        and r.ref like 'passprize:%' and ref like 'passprizefix:' || substr(r.ref, 11) || '%';
    v_amt := greatest(v_charged - v_already, 0);
    if v_amt > 0 then
      perform public._wallet_apply(r.player_id, v_amt, 'refund', 'passrefund:' || r.id,
        case r.tier when 'pro' then 'Weekly Pro refunded' else 'Weekly Pass refunded' end);
    end if;
    update public.weekly_passes set expires_at = starts_at where id = r.id;
    if r.ref is not null then
      update public.effect_passes set expires_at = least(expires_at, greatest(starts_at, now())) where code = r.ref;
    end if;
    insert into public.notifications (player_id, title, body) values (r.player_id,
      '💸 Weekly Pass refunded',
      case when v_amt > 0 then v_amt || ' points are back in your wallet. ' else 'Your points were already returned. ' end
      || 'Weekly Passes are cancelled - free JD tournaments stay free to join.');
  end loop;
end $$;

-- stacked passes that had not started yet: end them now too (otherwise expires_at = starts_at is still in the future)
update public.weekly_passes wp set starts_at = least(wp.starts_at, now()), expires_at = least(wp.starts_at, now())
 where exists (select 1 from public.wallet_ledger l where l.ref = 'passrefund:' || wp.id) or wp.ref like 'passprize:%';
update public.effect_passes e set starts_at = least(e.starts_at, now()), expires_at = least(e.starts_at, now())
 where e.code in (select ref from public.weekly_passes where ref is not null) and e.expires_at > now();
commit;

-- ── ZRX_FAMILY2: wrongly published as Open #9 winner - no pass refund, points to 0 (owner, 28 Oct 2026) ──
begin;
do $$
declare v_p uuid; v_bal int;
begin
  select id into v_p from public.players where squad_name = 'ZRX_FAMILY2';
  if exists (select 1 from public.wallet_ledger where ref = 'passrefund_reversed:13') then return; end if;
  select balance into v_bal from public.wallets where player_id = v_p;
  if v_bal > 0 then
    perform public._wallet_apply(v_p, -v_bal, 'adjust', 'passrefund_reversed:13',
      'Open #9 result was published wrongly - the pass refund does not apply, points reset to 0');
  end if;
  insert into public.notifications (player_id, title, body) values (v_p, 'Open #9 correction',
    'The Open #9 result was published by mistake and the pass came from that wrong prize, so no refund applies. Your points are 0.');
end $$;
commit;

-- ── set_pass_effect: "query returned more than one row" when a player has 2+ active effect passes (28 Oct 2026) ──
-- UPDATE ... RETURNING INTO a single row failed; now every active pass that allows the effect switches to it and the
-- longest-running one is returned.
create or replace function public.set_pass_effect(p_effect text)
 returns public.effect_passes language plpgsql security definer set search_path to 'public'
as $function$
declare v_pass public.effect_passes;
begin
  if auth.uid() is null then
    raise exception 'Please sign in first.';
  end if;
  with u as (
    update public.effect_passes set effect = p_effect
      where player_id = auth.uid() and starts_at <= now() and expires_at > now() and public.fx_tier_ok(tier, p_effect)
      returning *)
  select * into v_pass from u order by expires_at desc limit 1;
  if v_pass.id is null then
    raise exception 'Your current pass does not include that effect.';
  end if;
  return v_pass;
end;
$function$;

-- ── Squad invite links (owner, 28 Oct 2026) ──
-- The squad captain (the account that registers the squad) gets one squad chat named after the squad and a share
-- link jdesport.co.uk/chat/?join=<code>. Anyone signed in who opens it joins that chat - no friend request needed -
-- so the whole squad can talk in the app. Up to 8 players (4 + subs). The captain can make a new link (the old one
-- stops working). Banned players and players the captain blocked cannot join.
begin;
alter table public.chat_groups add column if not exists invite_code text;
alter table public.chat_groups add column if not exists is_squad boolean not null default false;
create unique index if not exists chat_groups_invite_code on public.chat_groups(invite_code) where invite_code is not null;
create unique index if not exists chat_groups_one_squad_chat on public.chat_groups(created_by) where is_squad;

create or replace function public._squad_code()
returns text language sql volatile set search_path = public as $$
  select string_agg(substr('abcdefghjkmnpqrstuvwxyz23456789', 1 + floor(random() * 31)::int, 1), '')
  from generate_series(1, 8)
$$;
revoke all on function public._squad_code() from public, anon, authenticated;

-- the caller's squad chat + invite code (created on first use)
create or replace function public.squad_invite(p_reset boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); g public.chat_groups; v_name text;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  select coalesce(nullif(trim(squad_name), ''), 'My squad') into v_name from public.players where id = v_me;
  perform pg_advisory_xact_lock(hashtext('squadchat:' || v_me::text));
  select * into g from public.chat_groups where created_by = v_me and is_squad;
  if not found then
    insert into public.chat_groups (name, created_by, is_squad, invite_code)
      values (left(v_name, 40), v_me, true, public._squad_code()) returning * into g;
    insert into public.chat_group_members (group_id, player_id, added_by) values (g.id, v_me, v_me)
      on conflict do nothing;
    perform public._group_system(g.id, public._chat_name(v_me) || ' created the squad chat - share the invite link with your squad');
  elsif p_reset or g.invite_code is null then
    update public.chat_groups set invite_code = public._squad_code() where id = g.id returning * into g;
  end if;
  if not public._group_member(g.id, v_me) then   -- captain left once; invite brings them back
    insert into public.chat_group_members (group_id, player_id, added_by) values (g.id, v_me, v_me);
  end if;
  return jsonb_build_object('group_id', g.id, 'name', g.name, 'code', g.invite_code,
    'members', (select count(*) from public.chat_group_members where group_id = g.id), 'max', 8);
end;
$$;
revoke all on function public.squad_invite(boolean) from public, anon;
grant execute on function public.squad_invite(boolean) to authenticated;

-- a teammate opens the link
create or replace function public.join_squad_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid(); g public.chat_groups; v_count int;
begin
  if v_me is null then raise exception 'Please sign in first.'; end if;
  if exists(select 1 from public.banned_players where player_id = v_me) then raise exception 'Your account is banned.'; end if;
  select * into g from public.chat_groups where invite_code = lower(trim(coalesce(p_code, ''))) and is_squad;
  if not found then raise exception 'This squad invite link is not valid any more - ask your captain for a new one.'; end if;
  if public._group_member(g.id, v_me) then
    return jsonb_build_object('group_id', g.id, 'name', g.name, 'joined', false);
  end if;
  if g.created_by is not null and public._blocked_either(g.created_by, v_me) then
    raise exception 'You can''t join this squad chat.';
  end if;
  perform pg_advisory_xact_lock(hashtext('squadjoin:' || g.id::text));
  select count(*) into v_count from public.chat_group_members where group_id = g.id;
  if v_count >= 8 then raise exception 'This squad chat is full (8 players).'; end if;
  insert into public.chat_group_members (group_id, player_id, added_by, last_read_id)
    values (g.id, v_me, g.created_by, coalesce((select max(id) from public.group_messages where group_id = g.id), 0));
  perform public._group_system(g.id, public._chat_name(v_me) || ' joined with the invite link 👋');
  if g.created_by is not null then
    insert into public.notifications (player_id, title, body)
      values (g.created_by, '👥 ' || public._chat_name(v_me) || ' joined your squad chat', 'Open 💬 Messages to talk with your squad.');
  end if;
  return jsonb_build_object('group_id', g.id, 'name', g.name, 'joined', true);
end;
$$;
revoke all on function public.join_squad_invite(text) from public, anon;
grant execute on function public.join_squad_invite(text) to authenticated;
commit;

-- ── Admin refund button (owner, 28 Oct 2026) ──
-- One place to refund any charge a player paid with points: event entry, squad effect, Weekly Pass / Pro (bought or
-- taken from a prize), Optimizer plan, challenge stake, or a manual deduction. Rules:
--   * a charge can never be refunded for more than was taken (partial refunds add up to at most the full amount);
--     refunds already made for it - by this button or earlier fixes (passrefund / passprizefix) - count;
--   * refunding a Weekly Pass ends that pass and its effect; refunding an effect ends that effect;
--     entries / Optimizer plans / challenges keep their registration / plan / result (change those in their own panel);
--   * "custom" refunds (no charge picked) need a reason;
--   * every refund goes through _wallet_apply (security lock + sweep), notifies the player, ref adminrefund:...
begin;

create or replace function public._refunded_for(l public.wallet_ledger)
returns int language sql stable security definer set search_path = public as $$
  select coalesce((select sum(delta) from public.wallet_ledger where player_id = l.player_id and reason = 'refund'
                    and ref like 'adminrefund:' || l.id::text || '%'), 0)
       + case when l.reason = 'pass' then
           coalesce((select sum(r.delta) from public.wallet_ledger r join public.weekly_passes wp
                       on r.ref = 'passrefund:' || wp.id
                     where wp.player_id = l.player_id and (l.ref = wp.ref or l.ref like wp.ref || ':%')
                       and r.ref not like 'adminrefund:%'), 0)
         + coalesce((select sum(r.delta) from public.wallet_ledger r
                     where r.player_id = l.player_id and r.reason = 'refund' and l.ref like 'passprize:%'
                       and r.ref = 'passprizefix:' || substr(l.ref, 11)), 0)
         else 0 end
$$;
revoke all on function public._refunded_for(public.wallet_ledger) from public, anon, authenticated;

-- the player's recent charges and how much of each can still be refunded
create or replace function public.admin_refundables(p_player uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'created_at' desc), '[]'::jsonb) from (
    select jsonb_build_object('id', l.id, 'reason', l.reason, 'charged', -l.delta, 'ref', l.ref, 'note', l.note,
             'created_at', l.created_at,
             'refunded', public._refunded_for(l),
             'left', greatest(-l.delta - public._refunded_for(l), 0)) x
    from public.wallet_ledger l
    where l.player_id = p_player and l.delta < 0
      and l.reason in ('entry','effect','pass','optimizer','challenge_stake','adjust')
    order by l.created_at desc limit 60) s
$$;
revoke all on function public.admin_refundables(uuid) from public, anon, authenticated;
grant execute on function public.admin_refundables(uuid) to service_role;

create or replace function public.admin_refund(p_player uuid, p_ledger uuid, p_amount int, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l public.wallet_ledger;
  v_left int;
  v_amt int;
  v_bal int;
  v_n int;
  v_what text;
  v_ended text := '';
  v_ref text;
begin
  p_reason := nullif(trim(coalesce(p_reason, '')), '');
  if p_player is null or not exists (select 1 from public.players where id = p_player) then
    raise exception 'Player not found.';
  end if;
  perform pg_advisory_xact_lock(hashtext('refund:' || p_player::text));
  if p_ledger is null then   -- custom refund (e.g. paid by eSewa for something that never happened)
    if p_amount is null or p_amount < 1 then raise exception 'Enter how many points to refund.'; end if;
    if p_amount > 5000 then raise exception 'Custom refunds are capped at 5000 points - use several or check the amount.'; end if;
    if p_reason is null then raise exception 'Write why you are refunding (the player sees it).'; end if;
    v_ref := 'adminrefund:custom:' || gen_random_uuid()::text;
    v_amt := p_amount;
    v_what := 'Refund';
  else
    select * into l from public.wallet_ledger where id = p_ledger and player_id = p_player;
    if not found or l.delta >= 0 then raise exception 'That charge was not found for this player.'; end if;
    if l.reason not in ('entry','effect','pass','optimizer','challenge_stake','adjust') then
      raise exception 'This kind of transaction cannot be refunded here.';
    end if;
    v_left := -l.delta - public._refunded_for(l);
    if v_left <= 0 then raise exception 'This charge has already been fully refunded.'; end if;
    v_amt := coalesce(p_amount, v_left);
    if v_amt < 1 then raise exception 'Enter how many points to refund.'; end if;
    if v_amt > v_left then raise exception 'Only % points of this charge are left to refund.', v_left; end if;
    select count(*) into v_n from public.wallet_ledger where ref like 'adminrefund:' || l.id::text || '%';
    v_ref := 'adminrefund:' || l.id::text || ':' || (v_n + 1);
    v_what := case l.reason when 'entry' then 'Event entry' when 'effect' then 'Squad effect'
      when 'pass' then 'Weekly Pass' when 'optimizer' then 'Optimizer plan' when 'challenge_stake' then 'Challenge stake'
      else 'Deduction' end || ' refund';
    if l.reason = 'pass' and v_amt = v_left then
      update public.weekly_passes wp set starts_at = least(wp.starts_at, now()), expires_at = least(wp.starts_at, now())
        where wp.player_id = p_player and (l.ref = wp.ref or l.ref like wp.ref || ':%') and wp.expires_at > now();
      get diagnostics v_n = row_count;
      update public.effect_passes e set starts_at = least(e.starts_at, now()), expires_at = least(e.starts_at, now())
        where e.player_id = p_player and e.expires_at > now()
          and e.code in (select wp.ref from public.weekly_passes wp where wp.player_id = p_player
                          and (l.ref = wp.ref or l.ref like wp.ref || ':%'));
      if v_n > 0 then v_ended := ' The pass has ended.'; end if;
    elsif l.reason = 'effect' and v_amt = v_left and l.ref is not null then
      update public.effect_passes set expires_at = least(expires_at, greatest(starts_at, now()))
        where player_id = p_player and code = l.ref and expires_at > now();
      get diagnostics v_n = row_count;
      if v_n > 0 then v_ended := ' The effect has ended.'; end if;
    end if;
  end if;
  v_bal := public._wallet_apply(p_player, v_amt, 'refund', v_ref, left(v_what || coalesce(' - ' || p_reason, ''), 200));
  insert into public.notifications (player_id, title, body) values (p_player, '💸 ' || v_amt || ' points refunded',
    v_what || coalesce(': ' || p_reason, '') || '. Balance: ' || v_bal || ' points.' || v_ended);
  return jsonb_build_object('refunded', v_amt, 'balance', v_bal, 'ref', v_ref, 'what', v_what, 'ended', v_ended <> '');
end;
$$;
revoke all on function public.admin_refund(uuid, uuid, int, text) from public, anon, authenticated;
grant execute on function public.admin_refund(uuid, uuid, int, text) to service_role;
commit;

-- Prizes are always paid in full: _award_one no longer takes 50 points of a free-tournament prize
-- to buy a Weekly Pass for winners without one (28 Oct 2026). 'pass_cut' stays in the result, always 0.
begin;
CREATE OR REPLACE FUNCTION public._award_one(p_slug text, p_squad text, p_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$

declare

  v_player uuid;

  v_ref text := 'prize:' || p_slug || ':' || lower(trim(p_squad));

  v_bal int;


  v_cut int := 0;



  v_referrer uuid;

  v_note text := '';

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



  -- referral: the invited player's first prize -> +40 for them and +40 for the friend who invited them

  update public.referrals set bonus_paid_at = now() where referred_id = v_player and bonus_paid_at is null

    returning referrer_id into v_referrer;

  if v_referrer is not null then

    v_bal := public._wallet_apply(v_player, 40, 'referral', 'ref:' || v_player::text, 'Invite bonus - first win');

    perform public._wallet_apply(v_referrer, 40, 'referral', 'ref:' || v_player::text || ':by', 'Your invited friend won');

    insert into public.notifications (player_id, title, body) values (v_referrer, '🤝 +40 points: your friend won',

      coalesce((select coalesce(username, player_tag) from public.players where id = v_player), 'Your invited friend') ||

      ' won their first prize, so you both got +40 points. Invite more friends from your profile.');

    v_note := v_note || ' +40 invite bonus for your first win.';

  end if;



  insert into public.notifications (player_id, tournament_slug, title, body)

  values (v_player, p_slug, '🏆 Prize: +' || p_amount || ' JD points',

          'Congratulations! ' || p_squad || '''s prize for ' || p_slug || ' (' || p_amount || ' points) is in your wallet.' ||

          v_note || ' Balance: ' || v_bal || ' points. You can use it for entries or withdraw it to eSewa.');

  return jsonb_build_object('squad', p_squad, 'status', 'paid', 'amount', p_amount, 'player_id', v_player,

                            'pass_cut', v_cut, 'referral', v_referrer is not null);

end;

$function$;
commit;

-- ── Rule 9 (respect: no rude language) + rule 10 (the owner plays for fun) — 2026-10-29. Safe to run again. ──
-- Rule 9: rude words in player chat (DMs, group chats, Clash Squad match chats, JD Support) are replaced with *** by the
-- database itself (a filter in the browser could be bypassed). Each hit is a strike in chat_strikes. The player
-- gets one reminder a day; at 3 strikes in 7 days the owner is notified. Nobody is banned automatically - the admin
-- decides. Words live in chat_bad_words: add or remove them there (lower case; stem = also words that start with it).
-- Rule 10: the owner plays for fun and is never paid a prize: _award_one() skips the owner's squad (status
-- owner_plays_for_fun) and the admin gives that prize to the next squad.
begin;

create table if not exists public.chat_bad_words (
  word text primary key check (word = lower(word) and length(word) between 2 and 40),
  stem boolean not null default false
);
alter table public.chat_bad_words enable row level security;   -- no policies: only the filter (security definer) reads it
insert into public.chat_bad_words (word, stem) values
  ('fuck', true),
  ('motherfuck', true),
  ('shit', true),
  ('bitch', true),
  ('bastard', false),
  ('asshole', false),
  ('cunt', false),
  ('dick', false),
  ('pussy', false),
  ('slut', false),
  ('whore', false),
  ('retard', false),
  ('nigger', false),
  ('nigga', false),
  ('faggot', false),
  ('fag', false),
  ('wanker', false),
  ('twat', false),
  ('muji', false),
  ('machikne', false),
  ('chikne', false),
  ('randi', false),
  ('lado', false),
  ('puti', false),
  ('bhalu', false),
  ('gandu', false),
  ('chutiya', true),
  ('madarchod', false),
  ('maderchod', false),
  ('mc', false),
  ('bc', false),
  ('bhenchod', false),
  ('behenchod', false),
  ('bhosdi', true),
  ('lund', false),
  ('lawde', false),
  ('laude', false),
  ('harami', false)
on conflict (word) do nothing;

create table if not exists public.chat_strikes (
  id bigserial primary key,
  player_id uuid references public.players(id) on delete cascade,
  source text not null,
  words text[] not null,
  created_at timestamptz not null default now()
);
create index if not exists chat_strikes_player_idx on public.chat_strikes (player_id, created_at desc);
alter table public.chat_strikes enable row level security;     -- no policies: service role / admin tools only

-- one letter of a bad word: any case (flag i), common look-alikes (@ for a, 0 for o ...) and stretched (fuuuck)
create or replace function public._rude_letter(c text) returns text language sql immutable as $$
  select case c when 'a' then '[a@4]' when 'e' then '[e3]' when 'i' then '[i1!]' when 'o' then '[o0]'
                when 's' then '[s$5]' else c end || '+'
$$;

-- masked = p with every bad word replaced by ***; hits = the words found. Whole words only (class, assassin and
-- Scunthorpe stay as they are); letters may be split by . _ * - (f.u.c.k).
create or replace function public.jd_mask_rude(p text, out masked text, out hits text[])
language plpgsql stable security definer set search_path = public as $$
declare w record; core text; nxt text;
begin
  masked := p; hits := '{}';
  if p is null then return; end if;
  for w in select word, stem from public.chat_bad_words order by length(word) desc loop
    select string_agg(public._rude_letter(c), '[._*-]*' order by n) into core
      from regexp_split_to_table(w.word, '') with ordinality t(c, n);
    nxt := regexp_replace(masked, '(^|[^[:alnum:]])' || core || case when w.stem then '[[:alpha:]]*' else '' end
                                  || '(?![[:alnum:]])', '\1***', 'gi');
    if nxt <> masked then hits := hits || w.word; masked := nxt; end if;
  end loop;
end;
$$;
revoke all on function public.jd_mask_rude(text) from public, anon, authenticated;

create or replace function public._chat_respect() returns trigger
language plpgsql security definer set search_path = public as $$
declare r record; v_admin uuid; v_n int; v_sender uuid; j jsonb := to_jsonb(new);
begin
  -- dm / group / challenge messages have a sender; the JD Support chat (jd_messages) has player_id + from_staff
  v_sender := case when j ? 'from_staff' then case when (j->>'from_staff')::boolean then null else (j->>'player_id')::uuid end
                   else (j->>'sender')::uuid end;
  if coalesce(j->>'kind', 'text') <> 'text' or v_sender is null then return new; end if;
  select * into r from public.jd_mask_rude(new.body);
  if r.masked is not distinct from new.body then return new; end if;
  new.body := r.masked;
  -- reminder to the sender at most once a day (checked before this strike is logged)
  if not exists(select 1 from public.chat_strikes where player_id = v_sender and created_at > now() - interval '1 day') then
    insert into public.notifications (player_id, title, body)
    values (v_sender, '🤝 Rule 9: respect everyone',
            'Rude words in your message were hidden (***). JD Arena chat is for friendly play - repeated rude language can get your account banned by the admin.');
  end if;
  insert into public.chat_strikes (player_id, source, words) values (v_sender, tg_table_name, r.hits);
  select count(*) into v_n from public.chat_strikes where player_id = v_sender and created_at > now() - interval '7 days';
  if v_n = 3 then
    select id into v_admin from public.players where lower(email) = 'ayerprabin95@gmail.com' limit 1;
    if v_admin is not null then
      insert into public.notifications (player_id, title, body)
      select v_admin, '⚠️ Rude language: 3 strikes in 7 days',
             coalesce('@' || p.username, 'A player') || ' used rude words 3 times this week (rule 9). You decide: warn or ban. '
             || 'Words: ' || array_to_string(r.hits, ', ')
        from public.players p where p.id = v_sender;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists chat_respect on public.dm_messages;
create trigger chat_respect before insert on public.dm_messages for each row execute function public._chat_respect();
drop trigger if exists chat_respect on public.group_messages;
create trigger chat_respect before insert on public.group_messages for each row execute function public._chat_respect();
drop trigger if exists chat_respect on public.challenge_messages;
create trigger chat_respect before insert on public.challenge_messages for each row execute function public._chat_respect();
drop trigger if exists chat_respect on public.jd_messages;
create trigger chat_respect before insert on public.jd_messages for each row execute function public._chat_respect();

-- rule 10: the live _award_one (read from the database on 2026-10-29) + the owner check
CREATE OR REPLACE FUNCTION public._award_one(p_slug text, p_squad text, p_amount integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_player uuid;
  v_ref text := 'prize:' || p_slug || ':' || lower(trim(p_squad));
  v_bal int;
  v_cut int := 0;
  v_referrer uuid;
  v_note text := '';
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
  -- rule 10: the owner plays for fun and is never paid; the admin gives this prize to the next squad
  if exists(select 1 from public.players where id = v_player and lower(email) = 'ayerprabin95@gmail.com') then
    return jsonb_build_object('squad', p_squad, 'status', 'owner_plays_for_fun', 'amount', p_amount);
  end if;
  v_bal := public._wallet_apply(v_player, p_amount, 'prize', v_ref, p_slug);
  -- referral: the invited player's first prize -> +40 for them and +40 for the friend who invited them
  update public.referrals set bonus_paid_at = now() where referred_id = v_player and bonus_paid_at is null
    returning referrer_id into v_referrer;
  if v_referrer is not null then
    v_bal := public._wallet_apply(v_player, 40, 'referral', 'ref:' || v_player::text, 'Invite bonus - first win');
    perform public._wallet_apply(v_referrer, 40, 'referral', 'ref:' || v_player::text || ':by', 'Your invited friend won');
    insert into public.notifications (player_id, title, body) values (v_referrer, '🤝 +40 points: your friend won',
      coalesce((select coalesce(username, player_tag) from public.players where id = v_player), 'Your invited friend') ||
      ' won their first prize, so you both got +40 points. Invite more friends from your profile.');
    v_note := v_note || ' +40 invite bonus for your first win.';
  end if;
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (v_player, p_slug, '🏆 Prize: +' || p_amount || ' JD points',
          'Congratulations! ' || p_squad || '''s prize for ' || p_slug || ' (' || p_amount || ' points) is in your wallet.' ||
          v_note || ' Balance: ' || v_bal || ' points. You can use it for entries or withdraw it to eSewa.');
  return jsonb_build_object('squad', p_squad, 'status', 'paid', 'amount', p_amount, 'player_id', v_player,
                            'pass_cut', v_cut, 'referral', v_referrer is not null);
end;
$function$;

commit;

-- -- Weekly Pass switched OFF for now (owner, 29 Oct 2026) --
-- JD Frag Engine (every version) only needs Optimizer Pro / Max; nobody can buy a pass. To switch back on, make
-- _weekly_pass_on() return true: _optimizer_pass_ok and buy_weekly_pass follow it.
begin;
create or replace function public._weekly_pass_on() returns boolean language sql stable as $$ select false $$;

create or replace function public._optimizer_pass_ok(p_player uuid)
 returns boolean language sql stable security definer set search_path to 'public'
as $function$
  select not public._weekly_pass_on()
      or public.weekly_pass_tier(p_player, greatest(now(), timestamptz '2026-10-27 00:00:00+05:45')) is not null
      or exists (select 1 from public.players p
                 where p.id = p_player
                   and (lower(p.email) = 'ayerprabin95@gmail.com'
                        or lower(p.email) in (select lower(email) from public.moderators where role = 'staff')))
$function$;

CREATE OR REPLACE FUNCTION public.buy_weekly_pass(p_tier text, p_effect text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_price int;
  v_cur public.weekly_passes;
  v_launch constant timestamptz := timestamptz '2026-10-27 00:00:00+05:45';
  v_start timestamptz := greatest(now(), timestamptz '2026-10-27 00:00:00+05:45');  -- bought early: the week starts on launch day
  v_bonus interval := interval '0';
  v_exp timestamptz;
  v_bal int;
  v_ref text := 'pass:' || gen_random_uuid()::text;
  v_fx jsonb;
begin
  if auth.uid() is null then raise exception 'Please sign in first.'; end if;
  if not public._weekly_pass_on() then raise exception 'The Weekly Pass is switched off for now - nothing to buy. Free JD tournaments and JD Frag Engine work without it.'; end if;
  if p_tier not in ('basic','pro') then raise exception 'Pick Weekly Pass or Weekly Pro.'; end if;
  if exists(select 1 from public.banned_players where player_id = auth.uid()) then
    raise exception 'Your account is banned from JD tournaments.';
  end if;
  v_price := case p_tier when 'basic' then 50 else 80 end;
  if p_effect is not null and not public.fx_tier_ok(case p_tier when 'basic' then 'lite' else 'pro' end, p_effect) then
    raise exception 'That effect is not included in this pass.';
  end if;
  perform pg_advisory_xact_lock(hashtext('pass:' || auth.uid()::text));
  select * into v_cur from public.weekly_passes where player_id = auth.uid() and expires_at > now()
    order by expires_at desc limit 1;
  if found then
    if v_cur.tier = 'basic' and p_tier = 'pro' then   -- upgrade: the lite effect of the old pass ends here
      update public.effect_passes set expires_at = least(expires_at, greatest(starts_at, now()))
        where player_id = auth.uid() and code in (select ref from public.weekly_passes
          where player_id = auth.uid() and tier = 'basic' and expires_at > now() and ref is not null);
    end if;
    if v_cur.tier = 'basic' and p_tier = 'pro' and now() < v_launch then   -- upgrade before launch: same week, now Pro
      update public.weekly_passes set expires_at = starts_at where id = v_cur.id;
      v_price := 30;                                                         -- pays only the difference
    elsif v_cur.tier = p_tier or (v_cur.tier = 'pro' and p_tier = 'basic') then
      v_start := v_cur.expires_at;                                  -- stack after the current pass
    else                                                            -- basic -> pro upgrade now
      v_bonus := (v_cur.expires_at - greatest(now(), v_cur.starts_at)) * (50.0 / 80.0)::float8;
      update public.weekly_passes set expires_at = now() where player_id = auth.uid() and tier = 'basic' and expires_at > now();
    end if;
  end if;
  v_exp := v_start + interval '7 days' + v_bonus;
  v_bal := public._wallet_apply(auth.uid(), -v_price, 'pass', v_ref,
                                case p_tier when 'basic' then 'Weekly Pass' else 'Weekly Pro' end);
  insert into public.weekly_passes (player_id, tier, starts_at, expires_at, price, ref) values (auth.uid(), p_tier, v_start, v_exp, v_price, v_ref);
  if p_effect is not null then
    v_fx := public._apply_effect_plan(auth.uid(), case p_tier when 'basic' then 'fx_lite_week' else 'fx_week' end, p_effect, null, v_ref);
    update public.effect_passes set starts_at = v_start, expires_at = v_exp where code = v_ref;   -- effect runs with the pass week
    v_fx := v_fx || jsonb_build_object('starts_at', v_start, 'expires_at', v_exp);
  end if;
  insert into public.notifications (player_id, title, body) values (auth.uid(),
    case p_tier when 'basic' then '🎟 Weekly Pass active' else '👑 Weekly Pro active' end,
    case when v_start > now() then 'Starts ' || to_char(v_start at time zone 'Asia/Kathmandu', 'Dy DD Mon') || ', valid until ' else 'Valid until ' end || to_char(v_exp at time zone 'Asia/Kathmandu', 'Dy DD Mon, HH12:MI AM') || ' NPT. ' ||
    case p_tier when 'basic' then 'You can join every free JD tournament this week.'
                else 'Free tournaments, Pro effect, 24 h early registration, waitlist priority and your PRO badge.' end);
  return jsonb_build_object('tier', p_tier, 'starts_at', v_start, 'expires_at', v_exp, 'balance', v_bal, 'effect', v_fx);
end;
$function$;

commit;

-- ── Open #10 moved to Fri 30 Oct 9:30 PM NPT: 4 notifications to every player (owner, 29 Oct 2026) ──
-- 1 now, 2 at 10:00 NPT, 3 at 20:30 NPT, 4 at 21:15 NPT on 30 Oct. Each cron job runs once and removes itself.
begin;
create or replace function public._open10_notice(p_n int) returns int
language plpgsql security definer set search_path to 'public' as $$
declare v_title text; v_body text; v_n int;
begin
  select t, b into v_title, v_body from (values
    (1, '📅 Open #10 is TOMORROW',
        'JD Free Fire Open #10 moved to tomorrow, Fri 30 Oct, 9:30 PM NPT. Free entry · 200 points prize · 3 matches (Nexterra, Alpine, Kalahari). Already registered? Your slot is kept. Join on jdesport.co.uk/events'),
    (2, '🔥 Open #10 is TONIGHT',
        'JD Free Fire Open #10 starts tonight at 9:30 PM NPT. Free to join, 200 points prize. Get your squad in on jdesport.co.uk/events'),
    (3, '⏰ 1 hour to Open #10',
        'JD Free Fire Open #10 starts at 9:30 PM NPT - 1 hour to go. Registered teams: confirm your slot and watch for the room code.'),
    (4, '🎮 Open #10 starts in 15 minutes',
        'Room code comes to registered teams just before 9:30 PM NPT. Be online and ready in Free Fire. Good luck!')
  ) v(n, t, b) where n = p_n;
  if v_title is null then return 0; end if;
  insert into public.notifications (player_id, tournament_slug, title, body)
  select id, 'JD Free Fire Open #10', v_title, v_body from public.players;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public._open10_notice(int) from public, anon, authenticated;

select cron.schedule('open10-notice-2', '15 4 30 10 *',  $c$select public._open10_notice(2); select cron.unschedule('open10-notice-2')$c$);
select cron.schedule('open10-notice-3', '45 14 30 10 *', $c$select public._open10_notice(3); select cron.unschedule('open10-notice-3')$c$);
select cron.schedule('open10-notice-4', '30 15 30 10 *', $c$select public._open10_notice(4); select cron.unschedule('open10-notice-4')$c$);
commit;

-- ── Open #10 reminders every 8 hours (owner, 29 Oct 2026): notice 1 went out 18:47 UTC, so 02:45 UTC (8:30 NPT)
-- and 10:45 UTC (16:30 NPT) on 30 Oct, then the 1-hour and 15-minute warnings stay as they were. ──
begin;
create or replace function public._open10_notice(p_n int) returns int
language plpgsql security definer set search_path to 'public' as $$
declare v_title text; v_body text; v_n int;
begin
  select t, b into v_title, v_body from (values
    (1, '📅 Open #10 is TOMORROW',
        'JD Free Fire Open #10 moved to tomorrow, Fri 30 Oct, 9:30 PM NPT. Free entry · 200 points prize · 3 matches (Nexterra, Alpine, Kalahari). Already registered? Your slot is kept. Join on jdesport.co.uk/events'),
    (2, '🔥 Open #10 is TONIGHT',
        'JD Free Fire Open #10 starts tonight at 9:30 PM NPT. Free to join, 200 points prize. Get your squad in on jdesport.co.uk/events'),
    (3, '⏰ 1 hour to Open #10',
        'JD Free Fire Open #10 starts at 9:30 PM NPT - 1 hour to go. Registered teams: confirm your slot and watch for the room code.'),
    (4, '🎮 Open #10 starts in 15 minutes',
        'Room code comes to registered teams just before 9:30 PM NPT. Be online and ready in Free Fire. Good luck!'),
    (5, '⚡ 5 hours to Open #10',
        'JD Free Fire Open #10 is tonight at 9:30 PM NPT. Free entry, 200 points prize, Nexterra · Alpine · Kalahari. Last chance to join on jdesport.co.uk/events')
  ) v(n, t, b) where n = p_n;
  if v_title is null then return 0; end if;
  insert into public.notifications (player_id, tournament_slug, title, body)
  select id, 'JD Free Fire Open #10', v_title, v_body from public.players;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public._open10_notice(int) from public, anon, authenticated;

select cron.unschedule('open10-notice-2');
select cron.schedule('open10-notice-2', '45 2 30 10 *',  $c$select public._open10_notice(2); select cron.unschedule('open10-notice-2')$c$);
select cron.schedule('open10-notice-5', '45 10 30 10 *', $c$select public._open10_notice(5); select cron.unschedule('open10-notice-5')$c$);
commit;

-- ── Season board logos (30 Oct 2026): the latest logo each squad name used on a confirmed / approved entry ──
-- Same data get_squad_logos(slug) already shows per event, for every event at once.
begin;
create or replace function public.get_season_logos()
 returns table(squad_name text, logo text)
 language sql stable security definer set search_path to 'public'
as $$
  select distinct on (lower(trim(r.squad_name))) r.squad_name, coalesce(nullif(r.squad_logo, ''), p.squad_logo) as logo
  from public.registrations r
  join public.players p on p.id = r.player_id
  where r.status in ('confirmed','approved')
    and coalesce(nullif(r.squad_logo, ''), p.squad_logo) is not null
  order by lower(trim(r.squad_name)), r.created_at desc;
$$;
grant execute on function public.get_season_logos() to anon, authenticated;
commit;
-- ── Open #10 restore (owner, 29 Oct 2026): the date moved to 30 Oct, so the 24-hour confirm sweep at 20:25 UTC
-- removed 9 unconfirmed squads and promoted 9 from the waitlist. Owner: put the 9 back, keep 12 slots, so the
-- 9 promoted go back to the waitlist. Re-add first (count stays >= slots, so promote_from_waitlist does nothing),
-- then demote. ──
begin;
alter table public.jd_no_show_log add column if not exists restored_at timestamptz;

insert into public.registrations (tournament_slug, player_id, squad_name, squad_logo, status, verified_at)
select l.tournament_slug, l.player_id, l.squad_name, p.squad_logo, 'confirmed', now()
from public.jd_no_show_log l join public.players p on p.id = l.player_id
where l.tournament_slug = 'JD Free Fire Open #10' and l.removed_at = '2026-10-29 20:25:00.314602+00'
  and not exists (select 1 from public.registrations r where r.tournament_slug = l.tournament_slug and r.player_id = l.player_id);

update public.jd_no_show_log set restored_at = now()
where tournament_slug = 'JD Free Fire Open #10' and removed_at = '2026-10-29 20:25:00.314602+00';

insert into public.notifications (player_id, tournament_slug, title, body)
select player_id, tournament_slug, '✅ You''re back in JD Free Fire Open #10',
  'Sorry, "' || squad_name || '" was removed by mistake when the date changed. Your slot is back: Fri 30 Oct, 9:30 PM NPT. Open your ticket and tap "Confirm you''re playing".'
from public.jd_no_show_log
where tournament_slug = 'JD Free Fire Open #10' and removed_at = '2026-10-29 20:25:00.314602+00';

with d as (
  update public.registrations set status = 'waitlisted', promoted_at = null
  where tournament_slug = 'JD Free Fire Open #10' and status = 'confirmed' and promoted_at = '2026-10-29 20:25:00.314602+00'
  returning player_id, squad_name)
insert into public.notifications (player_id, tournament_slug, title, body)
select player_id, 'JD Free Fire Open #10', '⏳ Back on the waitlist: JD Free Fire Open #10',
  'Sorry, squads were removed by mistake when the date changed and they have their slots back, so "' || squad_name || '" is on the waitlist again. You''re near the front: if a squad drops out you move up automatically.'
from d;
commit;
-- ── Removed squads → Add back (owner, 29 Oct 2026): the 24-hour confirm sweep stays on, but mods and the admin
-- see every squad taken out of an event (sweep, mod/admin remove, or the player leaving) and can put it back. ──
begin;
-- every removal is logged; the sweep already writes its own row (did_not_confirm) in the same transaction
create or replace function public._log_registration_removed() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if old.status not in ('confirmed','approved','waitlisted') then return old; end if;
  if exists (select 1 from public.jd_no_show_log where tournament_slug = old.tournament_slug
               and player_id = old.player_id and removed_at = now()) then return old; end if;
  insert into public.jd_no_show_log (tournament_slug, player_id, squad_name, reason)
  values (old.tournament_slug, old.player_id, old.squad_name,
          case when auth.uid() is not null and auth.uid() = old.player_id then 'left' else 'removed' end);
  return old;
end $$;
drop trigger if exists registrations_log_removed on public.registrations;
create trigger registrations_log_removed before delete on public.registrations
  for each row execute function public._log_registration_removed();

-- mods (hosts: only their own events) and the owner
create or replace function public._staff_can_event(p_slug text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from public.moderators m
    where m.email = lower((select email from auth.users where id = auth.uid()))
      and (coalesce(m.role,'staff') <> 'host' or exists (
        select 1 from public.site_content s, jsonb_array_elements(s.content->'tournaments') t
        where s.key = 'tournaments' and t->>'name' = p_slug
          and lower(regexp_replace(coalesce(t->>'host',''), '^@', '')) = lower(regexp_replace(coalesce(m.handle,''), '^@', ''))
          and coalesce(m.handle,'') <> '')));
$$;
revoke all on function public._staff_can_event(text) from public, anon, authenticated;

create or replace function public.staff_removed_squads(p_slug text)
returns table(id bigint, squad_name text, captain text, reason text, removed_at timestamptz, restored_at timestamptz, back boolean)
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public._staff_can_event(p_slug) then raise exception 'Moderators only.'; end if;
  return query
  select l.id, l.squad_name, coalesce('@' || p.username, p.player_tag), l.reason, l.removed_at, l.restored_at,
         exists (select 1 from public.registrations r where r.tournament_slug = l.tournament_slug and r.player_id = l.player_id)
  from public.jd_no_show_log l left join public.players p on p.id = l.player_id
  where l.tournament_slug = p_slug
  order by l.removed_at desc, l.id;
end $$;
revoke all on function public.staff_removed_squads(text) from public, anon;
grant execute on function public.staff_removed_squads(text) to authenticated;

-- put a removed squad back in a slot (it can go over the slot count: the mod decides who plays)
create or replace function public.staff_restore_removed(p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare l public.jd_no_show_log; v_slots int; v_taken int;
begin
  select * into l from public.jd_no_show_log where jd_no_show_log.id = p_id;
  if not found then raise exception 'Not found.'; end if;
  if not public._staff_can_event(l.tournament_slug) then raise exception 'Moderators only.'; end if;
  if exists (select 1 from public.registrations r where r.tournament_slug = l.tournament_slug and r.player_id = l.player_id) then
    raise exception '% is already registered for this event.', l.squad_name;
  end if;
  insert into public.registrations (tournament_slug, player_id, squad_name, squad_logo, status, verified_at)
  select l.tournament_slug, l.player_id, l.squad_name, p.squad_logo, 'confirmed', now()
  from public.players p where p.id = l.player_id;
  update public.jd_no_show_log set restored_at = now() where jd_no_show_log.id = p_id;
  insert into public.notifications (player_id, tournament_slug, title, body)
  values (l.player_id, l.tournament_slug, '✅ You''re back in ' || l.tournament_slug,
    'A JD moderator put "' || l.squad_name || '" back in ' || l.tournament_slug || '. Open your ticket and tap "Confirm you''re playing".');
  select slots into v_slots from public.tournament_capacity where tournament_slug = l.tournament_slug;
  select count(*) into v_taken from public.registrations where tournament_slug = l.tournament_slug and status in ('confirmed','approved');
  return jsonb_build_object('squad', l.squad_name, 'slots', v_slots, 'taken', v_taken);
end $$;
revoke all on function public.staff_restore_removed(bigint) from public, anon;
grant execute on function public.staff_restore_removed(bigint) to authenticated;
commit;
