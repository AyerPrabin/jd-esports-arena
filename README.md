# JD Esports Arena

Tournament hub for **JD Esports Arena** (Free Fire) — live at [jdesport.co.uk](https://jdesport.co.uk/). Players browse tournaments, register, and get room codes; admins create tournaments, manage squads/rosters, and approve registrations from a password-gated admin panel.

## Stack

- **Frontend** — static HTML/JS, no build step. Each page is `<folder>/index.html` so GitHub Pages serves it at a clean, extension-less URL (`/`, `/about/`, `/admin/`, `/reset-password/`); the old flat filenames (`jd-arena.html`, `about.html`, etc.) are kept as tiny redirect stubs so nothing previously shared breaks. Installable as a PWA (`manifest.json`, `sw.js`).
- **Hosting** — GitHub Pages, served at the custom domain via `CNAME`.
- **Backend** — [Supabase](https://supabase.com/): Postgres with Row Level Security for `players` / `registrations` / `notifications`, plus Edge Functions for everything server-side (see `supabase/functions/`).
- **Admin** — `/admin/` (tournament/squad editor), `noindex` + `ADMIN_SECRET`-checked passcode — no longer a non-guessable path, so the passcode is the only real protection. `zulu-admin-650476e8.html` (the separate, private Zulu admin) is unaffected and keeps its non-guessable path.

## Edge functions (`supabase/functions/`)

| Function | Purpose |
|---|---|
| `send-room-code` | Delivers private room codes to registered players (push + email) |
| `send-notification` | Custom announcement to all players or a hand-picked list (push + email + Discord) |
| `publish-tournaments` | Writes tournament/squad data out to `tournaments.json` |
| `publish-results` | Publishes match results |
| `approve-registration` | Admin approval flow for pending registrations |
| `list-registrations` | Admin view of who's registered |
| `notify-admin-signup` | Pings admin on new player signup |
| `tournament-reminders` | Scheduled reminders before a tournament starts |
| `confirm-account-delete` | Magic-link confirmation for account deletion |

(Not exhaustive — see `supabase/functions/` for the full list.)

## Setup

First-time setup (Supabase project, DNS, email verification, secrets) is documented end-to-end in [`SUPABASE_SETUP.md`](./SUPABASE_SETUP.md).

## Repo layout

```
index.html                    Player-facing tournament site (served at /)
about/index.html               About page (served at /about/)
admin/index.html                Tournament/squad admin panel (served at /admin/)
reset-password/index.html       Password reset page (served at /reset-password/)
jd-arena.html, about.html,      Old flat filenames — redirect stubs only, kept so
jd-admin-970f8094.html,         previously shared links/bookmarks/QR codes still work
reset-password.html
zulu-website.html             Zulu (JD's AI persona) front end
zulu-admin-*.html              Zulu admin panel
supabase/schema.sql            Postgres schema + RLS policies
supabase/functions/            Edge Functions (Deno)
tournaments.json               Published tournament/squad data
gameplay/, gameplay.json       Public highlight clips
zulu_*.py                      Zulu's local/offline logic (Discord bot, personality, knowledge)
```

## Notes

- Real secrets (`zulu_secrets.py`, `zulu-key.js`), private strategy notes (`zulu_private.py`, `zulu-private.js`), and runtime state (registrations, feedback, payouts, raw recordings) are all gitignored — see `.gitignore`.
- This repo is private; the public site is the static output served through GitHub Pages.
