# Accounts, room codes & notifications — one-time setup

This wires up player accounts (signup, email verification, forgot-password), in-app
tournament registration, and private room-code delivery — by push notification and
email — for JD Esports Arena. Everything runs free, serverless, 24/7 — nothing depends
on your laptop being on.

**Hosting**: the static site (root `index.html`, `admin/index.html`, `tournaments.json`)
is served by **GitHub Pages** at `https://jdesport.co.uk/`, and
every server-side piece (`send-room-code`, `publish-tournaments`, the payment/results
notifiers, etc.) is a **Supabase Edge Function**, not a Netlify Function — moved off
Netlify after hitting its free-tier usage limit. If you're reading old instructions
that mention Netlify env vars or `.netlify/functions/`, that's stale.

Do this once. Takes about 25–30 minutes.

## 0. Point jdesport.co.uk at GitHub Pages
This repo already has a `CNAME` file containing `jdesport.co.uk` — GitHub Pages reads
that automatically once the DNS below resolves, no repo change needed beyond what's
already committed. Two things left, both outside this repo:
1. **At your domain registrar** (wherever you bought jdesport.co.uk), add these DNS records:
   | Type | Host | Value |
   |---|---|---|
   | A | @ (apex/root) | `185.199.108.153` |
   | A | @ (apex/root) | `185.199.109.153` |
   | A | @ (apex/root) | `185.199.110.153` |
   | A | @ (apex/root) | `185.199.111.153` |
   | CNAME | `www` | `ayerprabin.github.io` |

   DNS can take anywhere from a few minutes to a few hours to propagate.
2. **GitHub → this repo → Settings → Pages** — under "Custom domain", confirm it shows
   `jdesport.co.uk` (it should pick this up from the `CNAME` file once you push). Once DNS
   resolves, tick **Enforce HTTPS** (greyed out until GitHub can issue the certificate —
   usually within an hour of DNS resolving).

Until DNS propagates, `https://ayerprabin.github.io/jd-esports-arena/` keeps working as a
fallback — GitHub doesn't turn that off just because a custom domain is configured.

## 0b. Clean URLs — no `.html` in the address bar
Every page lives in its own folder as `index.html`, which is what lets GitHub Pages serve
it at a clean path with no file extension — no server config needed, it's just how GitHub
Pages resolves a folder request:
| Page | File | Served at |
|---|---|---|
| Arena (home) | `index.html` (root) | `https://jdesport.co.uk/` |
| About | `about/index.html` | `https://jdesport.co.uk/about/` |
| Admin | `admin/index.html` | `https://jdesport.co.uk/admin/` |
| Password reset | `reset-password/index.html` | `https://jdesport.co.uk/reset-password/` |

The old flat filenames (`jd-arena.html`, `about.html`, `jd-admin-970f8094.html`,
`reset-password.html`) still exist, but only as tiny redirect stubs pointing at the clean
path above — so any link, bookmark, or QR code already shared with the old URL keeps
working, it just bounces through one redirect. Don't delete those stub files.

The admin panel used to live at a randomly-suffixed filename
(`jd-admin-970f8094.html`) specifically so it wouldn't be guessable — that's gone now
that it's at the clean, easy-to-find `/admin/`. The passcode gate and the server-side
`ADMIN_SECRET` check are the *only* thing protecting it going forward, not the URL —
worth knowing if you ever change your mind about that trade-off.

## 1. Create a Supabase project
1. Go to supabase.com → New project (free tier is enough for this).
2. Once it's created, go to **Project Settings → API**. Copy:
   - **Project URL**
   - **anon / public** key
   - **service_role** key (⚠ secret — never put this in a file that gets committed)

## 2. Run the schema
1. In Supabase, open **SQL Editor → New query**.
2. Paste the contents of `supabase/schema.sql` from this repo and run it.
3. This creates the `players`, `registrations`, and `notifications` tables with
   Row Level Security, so a player can only ever see their own data.

## 3. Turn on email verification
1. **Authentication → Providers → Email** — make sure "Confirm email" is ON.
2. **Authentication → URL Configuration** — set the Site URL to
   `https://jdesport.co.uk/`.
3. **Same page → Redirect URLs** — add `https://jdesport.co.uk/*`
   as an allowed pattern too. Supabase only honors `redirectTo` links (used by the
   verify email, the password-reset email, and the account-deletion magic link) if
   they match something in this allowlist — Site URL alone isn't enough. Skip this
   and those links can silently fail or land on the wrong page. **If you're migrating
   from a Netlify deploy, replace the old `your-site.netlify.app` pattern here — it
   won't work anymore once Netlify is torn down.**

   ⚠ **Check this isn't still the Supabase default.** A brand-new project ships with
   Site URL set to `http://localhost:3000`. If step 2/3 here was never actually done in
   the dashboard, every verify/reset/delete link silently redirects to `localhost` for
   real users instead of `jdesport.co.uk` — it looks like a broken/blank page to them,
   with no error in your own logs (Supabase auth logs will show `referer:
   "http://localhost:3000"` on every request, which is the tell). Fix it by setting the
   Site URL and Redirect URLs above for real, not just reading past this step.

## 3b. Password reset lands on its own page
Unlike verify-email (which lands back on the site root), the "Forgot password?" email
points at `/reset-password/` (see 0b's clean-URL table) —
a standalone page with just a "Reset your password" form. It uses the same
`SUPABASE_URL`/`SUPABASE_ANON_KEY` constants (edit both files if you ever rotate the
anon key) and reads the recovery session Supabase's client puts in the URL, same
mechanism as everything else here. It's covered by the `https://jdesport.co.uk/*`
wildcard from step 3 — no separate Redirect URLs entry needed.

## 4. Point Supabase at Gmail so verify/reset emails actually send
Supabase's built-in email sender is capped to a handful of emails/hour — fine for one
test signup, not enough for real players. It needs a real SMTP provider. Use your own
Gmail (`ayerprabin95@gmail.com` or a dedicated one) — it's free, needs no domain, and
sends to anyone immediately (unlike some transactional services that only deliver to
your own inbox until you verify a domain).
1. Turn on 2-Step Verification on the Gmail account (required for the next step):
   myaccount.google.com/security.
2. Create an **App Password**: myaccount.google.com/apppasswords → app "Mail" → copy
   the 16-character password it gives you (not your normal Gmail password).
3. In Supabase: **Project Settings → Auth → SMTP Settings** → enable custom SMTP:
   - Host: `smtp.gmail.com`, Port: `587`, Username: your full Gmail address,
     Password: the App Password from step 2
   - Sender email: same Gmail address
4. This only carries account emails (verify + reset) — Supabase's own SMTP, direct to
   Gmail, is a stable server-to-server connection, so no laptop or extra hosting is
   involved. (A note on why *not* to route this through a general-purpose Python host
   like PythonAnywhere: their free tier only allows Gmail SMTP as a special-cased
   exception, and their own docs warn it can silently break when Google rotates IPs
   until they patch their firewall — strictly more fragile than what this does.)

## Room-code email is optional
Room codes already reach players two ways without any email service at all: the push
alert (step 5 below) and the in-app Notification History. Email is a third, optional
channel for players who haven't enabled push. If you want it, get a free Resend
account and set `RESEND_API_KEY` in step 6 — **but Resend's default sender only
delivers to your own account's email until you verify a sending domain**, so skip it
entirely if you don't have a domain; nothing else breaks without it.

## 5. Get a free OneSignal account (for device push alerts)
This is what puts a room-code alert on a player's lock screen, not just in their inbox.
1. Go to onesignal.com → sign up free → **New App/Website**.
2. Platform: **Web Push**. Site URL: `https://jdesport.co.uk/`.
3. For "Service Worker Setup", choose the option for an existing/custom service worker
   — this repo already merges OneSignal into `sw.js` (see the `importScripts` line near
   the top of that file), so you don't need OneSignal to create its own worker file.
4. Once the app is created, go to **Settings → Keys & IDs**. Copy:
   - **OneSignal App ID**
   - **REST API Key**
5. Heads up on mobile: Android gets push whether or not the site is installed as an
   app. **iOS only delivers push if the player installed the site to their home
   screen first** (Safari 16.4+, via the "🍎 Download for iOS" button already on the
   site). Since some players won't have installed it, email + Notification History
   stay as the fallback — don't treat push as the only channel.

## 6. Set Supabase Edge Function secrets
`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and `SUPABASE_ANON_KEY` are injected into
every Edge Function automatically — you don't set those. Everything else needs to be
set once, in **Supabase Dashboard → Edge Functions → Secrets** (this is the *one* step
in this whole doc that has no MCP/CLI equivalent I can do for you — it has to be done
by hand in the dashboard):
| Key | Value |
|---|---|
| `RESEND_API_KEY` | optional — only if you want room-code email too (see "Room-code email is optional" above) |
| `ONESIGNAL_APP_ID` | the OneSignal App ID from step 5 |
| `ONESIGNAL_API_KEY` | the OneSignal REST API Key from step 5 |
| `ADMIN_SECRET` | any long random password you make up — this is the single passcode you'll type at `/admin/` to unlock it (see step 8: it's the same value, not a separate one) |
| `GITHUB_TOKEN` | a GitHub **fine-grained** Personal Access Token, scoped to only the `jd-esports-arena` repo with **Contents: Read and write** permission (create one at github.com → Settings → Developer settings → Fine-grained tokens). Powers the "🚀 Publish to GitHub" button in jd-admin — lives only here, never in any browser |
| `CRON_SECRET` | a long random value — guards the `tournament-reminders` function (see step 10) so only the scheduled job can trigger it, not the public internet |
| `DISCORD_BOT_TOKEN` | optional — same token as `zulu_discord.py`'s `DISCORD_TOKEN` (Developer Portal → your app → Bot). Lets `send-room-code`/`publish-results` DM players directly on Discord (see step 14). Leave unset and everything else here still works — that delivery channel just stays off |

No redeploy step needed — Edge Function secrets take effect immediately, unlike
Netlify's old "trigger a redeploy" requirement.

## 7. Give the site its public config
Send me (or edit directly) these constants near the top of the `<script>` block in
the root `index.html`:
- `SUPABASE_URL` / `SUPABASE_ANON_KEY` — the Project URL + anon key from step 1.
- `ONESIGNAL_APP_ID` — the App ID from step 5 (the REST API Key does NOT go here —
  that one stays server-side only, in Edge Function secrets).

These are safe to be public; Supabase's side is protected by the Row Level Security
policies from the schema, same trust model as the other config constants already in
that file (`WHATSAPP_NUMBER`, `TOURNAMENTS_URL`, etc).

Set the same `ONESIGNAL_APP_ID` in `admin/index.html`'s `<script>` block too (search for
`const ONESIGNAL_APP_ID=''`) — that's what lets the "Enable admin alerts" button in
step 9 below subscribe your own device.

## 8. Use it
- **Players**: "Sign in" in the top bar → create account → verify email → log in →
  tap "📲 Enable push alerts" once → "＋ Register in-app" on a tournament. Their room
  code shows up as a push alert, an email, and under "📜 Notification History" once
  you release it.
- **You (admin)**: open `/admin/` and type the `ADMIN_SECRET` value as the passcode
  on the door screen — that's the only passcode, it unlocks the editor and is what Room
  Codes / Notify players send as `x-admin-secret`, remembered on this device from then on
  (a "🔑 Change passcode" button clears it if you need to re-enter it). Then, for Room
  Codes: pick a tournament, hit "Load self-registered roster" (or type in player IDs by
  hand — e.g. for players who registered over WhatsApp instead), review/edit the
  recipient list, enter the Room ID + password, hit send. It's instant whether or not
  your laptop is on.

## Verify it end to end
1. Sign up with a **friend's real email, not your own** — Gmail SMTP sends to anyone,
   so this is a genuine test, not a self-test. Confirm the verification email arrives
   (check spam) → click it → log in.
2. Trigger "Forgot password?" on that account → confirm the reset email arrives and
   resets successfully.
3. On that account, tap "📲 Enable push alerts" and allow the browser permission prompt.
4. Register that account for a tournament → use the admin panel to send a room code →
   confirm the push alert arrives on that device and it shows up in that account's
   Notification History — and confirm neither happens for a second, unregistered test
   account. If you set up Resend too, confirm the email arrives as well (and if you
   didn't verify a domain there, confirm you understand it'll only reach your own
   Resend account's address, not real players).

## 9. (Optional) Get a push alert yourself whenever someone signs up
This is separate from step 5 — step 5 lets the site push room codes to *players*; this
lets *you* (admin) get a push naming the username every time someone new creates an
account, without checking the admin panel manually.
1. Do step 7's note above (set `ONESIGNAL_APP_ID` in `admin/index.html` too) if you haven't.
2. Open `/admin/` on the device you want alerts on (your phone works fine), scroll
   to **Admin Alerts**, tap **🔔 Enable admin alerts**, and allow the browser permission
   prompt. This subscribes that device with a fixed OneSignal ID (`admin`) — do this once
   per device you want alerted.
3. In Supabase: **Database → Webhooks → Create a new webhook**.
   - Table: `players`. Events: **Insert** only.
   - Type: **HTTP Request**. Method: `POST`.
   - URL: `https://cnoxvqvpmgowdiyrrusv.supabase.co/functions/v1/notify-admin-signup`
   - HTTP Headers: add `x-admin-secret` → the same `ADMIN_SECRET` value from step 6
     (this is what stops randoms from hitting that URL directly and spamming your phone —
     only Supabase, which you've handed the secret to, can trigger it).
4. Test: sign up a new test account on the site → a push naming that username should
   land on the device(s) from step 2 within a few seconds.

## 10. (Optional, done ✅) Email registered players 24h and 1h before their match
The `tournament-reminders` Edge Function emails everyone registered in-app for a
tournament once when it's ~24 hours away and again at ~1 hour away — reading
`tournaments.json` for the `start` time and the `registrations` table for who to email.
Players who never registered in-app get nothing, ever. Needs:
- Steps 1–4 done (accounts working) and step 2's schema actually applied — this reads
  the `registrations` and `notifications` tables.
- `RESEND_API_KEY` and `CRON_SECRET` set (step 6).

**Scheduling** — Netlify's `netlify.toml` cron config doesn't exist here anymore;
scheduling is now `pg_cron` + `pg_net`, run once in Supabase's SQL Editor (replace the
placeholder secret with the real value you set as `CRON_SECRET` in step 6):
```sql
create extension if not exists pg_cron;
create extension if not exists pg_net;

select vault.create_secret('https://cnoxvqvpmgowdiyrrusv.supabase.co', 'project_url');
select vault.create_secret('<same value as the CRON_SECRET Edge Function secret>', 'cron_secret');

select cron.schedule(
  'tournament-reminders',
  '*/5 * * * *', -- 5 min, not 15: room-code auto-release below targets 5-min-before-start,
                 -- and a slower tick would let it land anywhere up to ~10 min after kickoff
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/tournament-reminders',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body := '{}'::jsonb
  );
  $$
);
```
Check it's running with `select * from cron.job;`. No site config needed — it's fully
server-side once the secrets above are set.

**Piggybacking on the same 5-minute tick** (no extra setup — same cron job, same secrets):
- **Room code auto-release**: in jd-admin's Room Codes panel, "💾 Stage for auto-release"
  saves a code via the `stage-room-code` Edge Function instead of sending it immediately;
  `tournament-reminders` releases it to everyone registered ~5 minutes before start. The
  admin can still hit "Send Room Code now" for an instant manual send at any time — doing
  so marks the staged row sent too, so the timer won't double-send it later. Backed by the
  `tournament_room_codes` table (schema.sql).
- **Results notification chaining**: publishing tournaments.json (🚀 Publish changes) now
  auto-calls `publish-results` the moment `bo3.published` flips from false to true, instead
  of requiring a separate, order-dependent "🔔 Notify players" click after the fact. That
  button still works too, e.g. to resend.

## 11. (Optional) Let players attach a squad logo when they register in-app
Added a `squad_logo` column to `registrations` after the schema doc above was first
written. If you ran `schema.sql` before this note existed, run this once in the SQL
Editor to add it (safe — it's just one new nullable column, no data loss):
```sql
alter table public.registrations add column if not exists squad_logo text;
```
The player picks an image on the in-app "Register" form; it's resized to ~128px and
stored as a small base64 string, then shown back to them on their own registered
tournament card. It does **not** appear on the public tournament roster — that stays
admin-managed in `tournaments.json`, per the "Known gap" note below.

## 12. Players can delete their own account

Live once steps 1–4 and 6 (including the new `SUPABASE_ANON_KEY` var above) are done —
no extra Supabase or OneSignal setup needed, since it reuses the same magic-link email
Supabase already sends for "Forgot password?" (step 4's Gmail SMTP), not the optional
Resend channel. That matters: Resend without a verified sending domain only delivers to
your own inbox, so a critical, irreversible action like this must not depend on it.

Flow, both steps requiring an explicit click (never fires from just opening the email):
1. Player taps "Delete account" in the account panel → confirms a popup → the site calls
   `supabase.auth.signInWithOtp()`, which emails them a normal-looking sign-in link.
2. Clicking that link re-authenticates their browser and lands them back on the site on
   a "Confirm account deletion" panel. Only tapping **Yes, permanently delete** there
   calls the `confirm-account-delete` Edge Function, which re-verifies their session
   server-side and calls `supabase.auth.admin.deleteUser()` — this cascades to their
   `players`, `registrations`, and `notifications` rows automatically (same `on delete
   cascade` foreign keys from `schema.sql`).

No new Supabase config is needed: the redirect URL is
`https://jdesport.co.uk/?confirm_delete=1`, which is
already covered by the wildcard pattern from step 3's Redirect URLs allowlist.

This can't be verified locally — like Room Codes and reminders, it only works against
the live deploy with real secrets set, so test it on your actual deployed site with a
throwaway test account, not by opening the HTML file directly.

## 13. Paid tournaments: payment-screenshot verification before a registration counts

Added `status` and `payment_screenshot` columns to `registrations` after the schema doc
above was first written. If you ran `schema.sql` before this note existed, run this once
in the SQL Editor (safe — new nullable/defaulted columns, no data loss; existing rows get
`status = 'confirmed'` so nothing already registered is affected):
```sql
alter table public.registrations
  add column if not exists status text not null default 'confirmed',
  add column if not exists payment_screenshot text;
alter table public.registrations
  add constraint registrations_status_check check (status in ('pending','confirmed','approved','rejected'));
```

How it works: a tournament counts as "paid" on the client whenever its `entry` field in
`tournaments.json` is anything other than `Free` (case-insensitive) — no new JSON field
needed. Registering in-app for a free tournament still inserts instantly with
`status: 'confirmed'`, same as before. For a paid one, the register form additionally
requires a payment-screenshot upload (resized client-side, same pattern as the squad-logo
upload from step 11) and inserts with `status: 'pending'` — the player sees "Payment
pending verification" until you act on it.

**You approve/reject from `/admin/`'s new "Pending Payments" section**: pick a
tournament, load its pending registrations (screenshot thumbnails included), tap Approve
or Reject. This calls the `approve-registration` Edge Function, which is the *only*
path that can ever set `status` to `approved`/`rejected` — players have no UPDATE
permission on their own rows (see the RLS policy comments in `schema.sql`), so a player
can't self-approve by tampering with the client. A player *can* insert `status:
'confirmed'` directly for a paid tournament by bypassing the UI (there's no server-side
check tying `status` to whether a tournament is actually free) — same soft-trust model as
the rest of this admin panel (e.g. the passcode gate), and you still get a final look at
who's in the roster before sending room codes, same as today.

Room Codes, the 24h/1h reminders, and the results-notify function now all skip
`pending`/`rejected` registrations — so nobody gets a room code or a "results are up"
ping until you've approved their payment.

⚠ **Known gap: approving a payment doesn't recheck capacity.** `approve-registration`
does a bare `status` update with no slot-count check — unlike `register_for_tournament()`
(step 15), which does enforce the cap on the free-tournament path. If a paid tournament's
`pending` pile has more people than there are slots left, approving them all can push the
real count past `slots`. Small-event scale makes this low-risk in practice (you're looking
at the roster before sending room codes anyway), but it's a real gap, not something this
session's capacity/waitlist work fixed — worth knowing, not silently assumed safe.

## 14. Discord: general !ask, proactive announcements, and Room ID DMs

`zulu_discord.py` (separate process from this website — see that file's own setup notes)
picked up three upgrades:

- **`!ask`** now falls back to Gemini for anything outside the built-in Nepal/chemistry/
  physics/maths knowledge base, if `GOOGLE_API_KEY` is set (env var, or in `zulu_secrets.py`
  — the same key `zulu_server.py` uses, but this is a fully separate call with its own
  plain community-bot prompt; nothing from the private `zulu_personality.py`/`zulu_private.py`
  system is reachable from here).
- **Proactive announcements**: set `ZULU_ANNOUNCE_CHANNEL_ID` (right-click a channel → Copy
  Channel ID, needs Developer Mode on) and the bot posts on its own when a tournament goes
  live, fills up, or results are published. Unset = feature stays off.
- **Room ID delivery over Discord**: a player links their account once (account panel on
  the site → "🔗 Link Discord" → generates a short-lived code → `!link <code>` in Discord).
  From then on, `send-room-code` and `publish-results` DM them directly, alongside the
  existing email/push channels — set `DISCORD_BOT_TOKEN` (table above) for this to actually
  send; the linking UI/`!link` command work either way, they just won't result in a DM
  until that secret is set.

Linking lives in three new `schema.sql` pieces: `discord_link_codes` (short-lived, single-use
codes — RLS locked down, only reachable through the two RPCs below), and
`players.discord_user_id`/`discord_username`. `create_discord_link_code()` (player-authenticated)
mints a code; `link_discord_account()` (called by the bot with just the anon key — a Discord
user has no Supabase session) redeems it. The code's 128-bit randomness + single-use +
10-minute expiry *is* the security on that second RPC being anon-callable — matches the
soft-trust posture already accepted elsewhere in this schema (e.g. step 13's payment status).
The direction stays safe regardless: a code can only ever be minted by someone already logged
into the account it links, so it can at most let someone link Discord to their *own* account
faster than intended — never someone else's.

## 15. Waitlist + auto-promote (free tournaments only)

When a **free** tournament is full, registering no longer fails — `register_for_tournament()`
inserts the row with `status = 'waitlisted'` instead of raising an error, and the player sees
"You're on the waitlist" with the same ticket they'd get if confirmed. The moment a confirmed
slot frees up (a player deletes their own registration, or you reject/change an approved paid
one), a new trigger — `promote_from_waitlist()`, `after update or delete on registrations` —
recomputes the real confirmed/approved count and promotes the oldest waitlisted row straight
to `confirmed`, with its own "you're off the waitlist" notification. The site's 45-second
poll also refreshes the player's own registrations/notifications now, not just the public
roster, so a promotion shows up without the player needing to reload.

**Paid tournaments don't waitlist yet** — still a hard "Tournament full" like before. Promoting
a paid waitlist entry straight to `confirmed` would skip payment verification entirely, and
promoting to `pending` breaks the trigger's one-promotion-per-freed-slot guarantee (a `pending`
row doesn't count toward the confirmed/approved total the trigger checks, so it would keep
matching and cascade-promote the rest of the waitlist for a single opening). Deliberately left
as a separate follow-up, not solved here.

## 16. Match check-in / no-show forfeit

Confirmed/approved players now see a **"✅ Check In Now"** button on their tournament card
starting 30 minutes before it begins. Tapping it calls `check_in_for_tournament()`, which
stamps `checked_in_at` on their own registration — nothing else changes about their slot.

`tournament-reminders` (the same 15-minute cron job that already sends the 24h/1h email
reminders) now does two more things on every tick:
- **Check-in nudge** — ~30 minutes before start, anyone confirmed/approved who hasn't checked
  in yet gets a notification (and email, if `RESEND_API_KEY` is set) telling them to.
- **Forfeit sweep** — once a tournament is within ~10 minutes of start (the exact moment
  depends on where the 15-minute cron tick lands, so this is never promised as a precise
  minute to players), anyone still not checked in gets moved to `status = 'no_show'`. That
  frees their slot exactly like a self-delete or admin rejection does, so the existing
  waitlist-promotion trigger (`promote_from_waitlist()`, see section 15) picks the next
  waitlisted player up automatically — no changes needed there.

  This sweep runs **exactly once per tournament**, tracked by a small marker table
  (`tournament_checkin_sweeps`). That's load-bearing, not incidental: a sweep re-run on every
  tick would strip-mine the waitlist, because a player promoted off the waitlist inherits
  `checked_in_at = null` with the check-in window already closed — a markerless sweep would
  forfeit them on the very next tick, and the one promoted after them on the tick after that,
  cascading through the whole waitlist one casualty per tick. The marker makes the first tick
  past cutoff forfeit every current no-show once, then stop for that tournament for good —
  anyone promoted afterward keeps their slot without needing to check in.

Applies to paid tournaments too (a paid no-show wastes a slot the same way a free one does),
but since paid tournaments don't waitlist (see above), a paid no-show just frees the slot with
nobody auto-filling it — same as today's manual-approval flow, no new gap introduced.

No admin-panel changes in this phase — a "X/Y checked in" view for admins is a natural small
follow-up, not built here.

## 17. Send Announcement — a custom message to anyone, anytime

Unlike Room Codes (fixed Room ID/password message) or the results notifier (fixed "results
are up" message), **Send Announcement** in `/admin/` lets you type any title and message and
send it whenever you want — not tied to a tournament at all. Leave "Only send to specific
players?" blank to reach **every player on the site**; fill it in (comma-separated player
tags, usernames, or emails — same lookup Room Codes uses) to reach just a few.

Backed by a new `send-notification` Edge Function, same shape as `send-room-code`: writes a
notifications row per player, emails via Resend if `RESEND_API_KEY` is set, pushes via
OneSignal if configured (a broadcast to everyone uses OneSignal's "Subscribed Users" segment
rather than listing every player, which is the correct way to reach literally everyone), and
DMs on Discord for anyone who's linked their account. No new secrets needed — it reuses
`ADMIN_SECRET`, `RESEND_API_KEY`, `ONESIGNAL_APP_ID`/`ONESIGNAL_API_KEY`, and
`DISCORD_BOT_TOKEN` from step 6.

## 18. (Optional) Auto-notify every player when a new squad registers
A lightweight social nudge — "🎉 New squad alert! [Squad] just registered for [Tournament] —
think you can beat them?" — sent automatically to every OTHER player (in-app notification +
OneSignal push) the moment a registration actually counts (confirmed or approved; pending/
waitlisted/rejected never trigger it, so a squad that hasn't secured a spot is never
announced). Deliberately skips email and Discord DM — those channels stay reserved for
essential info (room codes, results), not something that fires on every signup.

Same pattern as step 9 (admin-signup alerts): a Supabase Database Webhook calls a new
`notify-new-registration` Edge Function server-side, so this can only ever fire off a real
registration row — never something a client could fake by hitting the URL directly.

1. Do steps 5 and 6 (OneSignal + secrets) if you haven't — this reuses `ONESIGNAL_APP_ID`/
   `ONESIGNAL_API_KEY` and `ADMIN_SECRET`, no new secrets needed.
2. In Supabase: **Database → Webhooks → Create a new webhook**.
   - Table: `registrations`. Events: **Insert** only.
   - Type: **HTTP Request**. Method: `POST`.
   - URL: `https://cnoxvqvpmgowdiyrrusv.supabase.co/functions/v1/notify-new-registration`
   - HTTP Headers: add `x-admin-secret` → the same `ADMIN_SECRET` value from step 6.
3. Test: register a test squad in-app (or approve a pending one) → every other player with
   push enabled should get the alert within a few seconds, and see it in their own
   Notification History.

Note: if several teammates each register individually under the same squad name (this site's
squad-shares-stats model — see `get_player_career_stats()` in `schema.sql`), each of their
registration rows fires this webhook separately, so everyone else gets announced that squad
more than once. Not deduped on purpose, to keep this simple — worth knowing before enabling
it for a tournament where squads commonly self-register one member at a time.

## 19. (Optional) Google Gemini — powers two features
Both share the same `GEMINI_API_KEY`/`GEMINI_MODEL` secrets, so set these once:

1. Get a free API key at [aistudio.google.com](https://aistudio.google.com) → Get API key.
2. Set it in **Supabase Dashboard → Edge Functions → Secrets**:

| Key | Value |
|---|---|
| `GEMINI_API_KEY` | your Gemini API key |
| `GEMINI_MODEL` | optional — defaults to `gemini-2.5-flash` if unset |

**Match Recap** (BO3 panel, admin-triggered only): writes a hype/roast-style match
recap (English + Nepali) from a tournament's **archived** results (archive results
first — see the Archive results button above). Review the output and edit freely
before it goes anywhere near "Send to players" / Send Announcement.

**ZULU AI fallback** (the chat widget, live for every visitor): when a question
doesn't match any of ZULU's local patterns, it now asks Gemini instead of showing
the old dead-end "I don't have that one yet" — scoped to JD Arena topics only, told
never to invent specific room IDs/points/times it doesn't actually have access to.

Both draw from the **same free-tier daily quota** (~20 requests/day per
`zulu_secrets.py`'s own notes) — the chat fallback has no rate limit or per-visitor
cap of its own yet, so a busy day of unusual questions can burn through the quota
Match Recap also needs. Add a cap before this sees real traffic; not done here on
purpose, called out as a known gap for now.

3. Test: archive results for any tournament, then in `/admin/`'s **Match Recap**
   section, pick that tournament and click **🎙️ Generate recap**.

## Known gap: Best-of-3 squad names are still typed by hand
The public "x/12 squads" counter and roster on the tournament cards, and jd-admin's own
"Squads actually registered" line on each card, are all real now — they read live from
Supabase's `registrations` table (via `get_public_roster()`), not from `tournaments.json`.
A player registering in-app moves those numbers immediately, no admin action needed.
`teams` in `tournaments.json` (jd-admin's collapsed "Manual squad list") only matters as
an offline fallback if Supabase is ever unreachable.

The one place still hand-typed is the **Best-of-3 Results** table (kills/points per
round) — "Load squads from roster" pulls in the real registered squad names as a
starting point, but the names sitting in that table are just labels for score-tracking,
so if you rename a squad afterward it won't automatically re-match. Not a bug, just
worth knowing when the names look slightly off from the live roster.

## You can test in stages
- Steps 1–4, 6 (`SUPABASE_*` vars only), and 7 get signup/verify/login/forgot-password
  fully working — that's it, no other service needed for accounts.
- Add step 5 (OneSignal) for push alerts on room codes — this is what replaces "check
  your laptop is on," since it runs entirely in the cloud regardless of your device.
- Resend (see "Room-code email is optional" above) is the last, skippable piece.
