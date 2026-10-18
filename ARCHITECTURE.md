# JD Esports Arena — Rebuild Architecture

This is the target architecture for the **full rebuild** (branch `rebuild/vite`). The live
site on `master` (single-file HTML pages + Supabase Edge Functions) keeps running untouched
until the rebuild reaches parity and we cut over. Nothing here is served by GitHub Pages yet.

## Why rebuild
The live site works but every page is one large hand-written HTML file with inline JS, the
Supabase URL/keys are hard-coded in each page, UI and business logic are interleaved, and there
is no shared component or state layer. That's fine for a solo MVP but hard to scale. This rebuild
separates concerns, removes duplication, and makes new features cheap and safe to add.

## Stack (decision — change before much is built if you disagree)
- **Vite** — dev server + build (no more hand-managed scripts).
- **Vue 3 + TypeScript** — component model, typed props/stores. Chosen over React/Svelte because
  it's the gentlest for a solo maintainer and has first-class TS + Pinia support. Swappable now.
- **Pinia** — state management (session/auth, tournaments, wallet).
- **Vue Router** — one SPA, real routes (`/`, `/leaderboard`, `/wallet`, `/optimizer`, `/mod`, `/admin`).
- **Supabase JS** — same backend (DB + Edge Functions). No backend rewrite; we restructure the
  *client* calls into a typed API layer.

## Folder structure (`app/`)
```
app/
  index.html              # SPA shell (one entry)
  .env.example            # which env vars exist (no secrets committed)
  src/
    main.ts               # bootstraps Vue + Pinia + Router
    App.vue               # layout shell (nav, error banner, router-view)
    router.ts             # routes (lazy-loaded views)
    config/
      env.ts              # reads import.meta.env — the ONLY place env is read
    lib/
      supabase.ts         # the single Supabase client
    api/                  # BUSINESS LOGIC — every backend call lives here, typed
      client.ts           # rpc()/query() wrappers with uniform error handling
      tournaments.ts      # getTournaments(), getBo3(), ...
      wallet.ts           # getWallet(), requestWithdrawal(), moneyFlow(), ...
      registration.ts     # register(), confirmAttendance(), ...
    stores/               # Pinia — shared reactive state
      session.ts          # current user/player, sign in/out
      tournaments.ts      # tournament list + live refresh
    components/ui/        # REUSABLE, presentational components (no business logic)
      BaseButton.vue  BaseCard.vue  BaseModal.vue
    views/                # one per route; compose api + stores + components
      LeaderboardView.vue # example, migrated first
    styles/
      tokens.css          # design tokens (colors, spacing) — single source of truth
```

## Rules (naming + conventions)
- **UI never talks to Supabase directly.** Components/views call `api/*` functions; those return
  typed data or throw a `ApiError`. State that's shared lives in a Pinia store.
- **Files:** components `PascalCase.vue`, everything else `kebab-case.ts`. Stores export
  `useXStore`. API functions are verbs: `getX`, `createX`, `updateX`.
- **No hard-coded secrets or URLs** outside `config/env.ts` (which reads `import.meta.env.VITE_*`).
- **Errors:** `api/client.ts` wraps every call; a thrown `ApiError` carries a human message. Views
  show it via the global error banner (App.vue) or inline. No silent `catch {}`.
- **Types:** shared DB shapes in `src/api/types.ts` (added as we migrate).

## Environment config
All runtime config comes from Vite env files, never the source:
- `app/.env.example` lists the vars. Copy to `.env.local` (git-ignored) with real values.
- `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` (publishable key — safe in the client).
- Admin/service secrets stay **server-side only** (Edge Function secrets), never in `VITE_*`.

## State management
- `session` store: Supabase auth session + the player's profile; exposes `signIn`, `signOut`,
  `isModerator`, `isAdmin`. One `onAuthStateChange` subscription, app-wide.
- `tournaments` store: the tournament list (from `site_content`/`tournaments.json`), refreshed on
  an interval; views read from it instead of each fetching their own copy.

## API structure (scalable)
`api/client.ts` centralizes: auth header, the `apikey`, ret/error shaping, and an `edge()` helper
for Edge Function calls. Each domain gets its own module so endpoints are discoverable and typed.
Adding a feature = add a typed function in the right `api/*` module + (if shared) a store action.

## Migration plan (page by page, lowest-risk first)
1. **Scaffold + Leaderboard** (read-only, no money) — *this commit*.
2. Tournaments list + registration + confirm flow.
3. Wallet (load/withdraw) — carefully, it moves money.
4. Optimizer page, Mod panel, Admin panel.
5. Cut over: point Pages (or a host) at the built SPA; keep old pages as fallback until stable.

Each step ships behind a staging deploy and is checked against the live site before the next.

## Running the rebuild
```
cd app
npm install
cp .env.example .env.local   # fill in the two VITE_ values
npm run dev                  # http://localhost:5173
npm run build                # dist/ (static, host anywhere)
```
