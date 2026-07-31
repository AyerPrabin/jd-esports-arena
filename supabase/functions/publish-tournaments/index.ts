// Admin-only: commits tournaments.json straight to GitHub server-side, using a
// GitHub token that lives only in this function's own secret — never in the
// browser, never typed by the admin, never in localStorage.
//
// Also mirrors each tournament's "slots" and "platform_mode" into
// public.tournament_capacity so the database (not just the jd-arena.html UI)
// knows the registration cap AND enforces mobile-only/emulator-only brackets —
// see register_for_tournament() in schema.sql. This only runs through this
// button; the manual "download and replace tournaments.json in GitHub yourself"
// path does NOT update the DB.
import { Buffer } from 'node:buffer';
import { createClient } from 'npm:@supabase/supabase-js@2';

const GITHUB_OWNER = 'AyerPrabin';
const GITHUB_REPO = 'jd-esports-arena';
const GITHUB_BRANCH = 'master';
const GITHUB_PATH = 'tournaments.json';

// Browser calls this cross-origin with a custom x-admin-secret header, which makes the
// browser send a CORS preflight OPTIONS request first — without these headers that
// preflight gets rejected and the real request never goes out, surfacing to the admin
// as a plain "Failed to fetch".
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function githubErr(status: number): string {
  if (status === 401) return 'GITHUB_TOKEN is missing, wrong, or expired.';
  if (status === 403) return 'GITHUB_TOKEN lacks permission — it needs Contents: Read and write on this repo.';
  if (status === 404) return 'Repo or path not found — check GITHUB_OWNER/GITHUB_REPO in this file.';
  return `GitHub error ${status}.`;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
  }
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET');
  if (!ADMIN_SECRET || req.headers.get('x-admin-secret') !== ADMIN_SECRET) {
    return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  }
  const githubToken = Deno.env.get('GITHUB_TOKEN');
  if (!githubToken) {
    return new Response("GITHUB_TOKEN is not set in this function's secrets.", { status: 500, headers: CORS_HEADERS });
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return new Response('Bad JSON', { status: 400, headers: CORS_HEADERS });
  }
  const { content } = payload;
  if (typeof content !== 'string' || !content.trim()) {
    return new Response('content (the generated tournaments.json text) is required', { status: 400, headers: CORS_HEADERS });
  }

  const api = `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${GITHUB_PATH}`;
  const authHeaders = { Authorization: `Bearer ${githubToken}`, Accept: 'application/vnd.github+json' };

  try {
    let sha: string | null = null;
    const getRes = await fetch(`${api}?ref=${GITHUB_BRANCH}`, { headers: authHeaders });
    if (getRes.status === 200) {
      sha = (await getRes.json()).sha;
    } else if (getRes.status !== 404) {
      return new Response(githubErr(getRes.status), { status: 502, headers: CORS_HEADERS });
    }

    const body: Record<string, unknown> = {
      message: 'Update tournaments.json via jd-admin',
      content: Buffer.from(content, 'utf8').toString('base64'),
      branch: GITHUB_BRANCH,
    };
    if (sha) body.sha = sha;

    const putRes = await fetch(api, {
      method: 'PUT',
      headers: { ...authHeaders, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!putRes.ok) {
      const errBody = await putRes.json().catch(() => ({}));
      if (putRes.status === 409) {
        return new Response('Someone/something else changed the file at the same moment — try again.', { status: 409, headers: CORS_HEADERS });
      }
      return new Response(errBody.message || githubErr(putRes.status), { status: 502, headers: CORS_HEADERS });
    }
  } catch (e) {
    return new Response(e instanceof Error ? e.message : String(e), { status: 500, headers: CORS_HEADERS });
  }

  // GitHub commit succeeded — the site will go live either way, so a capacity-sync
  // hiccup here is reported as a warning rather than failing the whole publish.
  let warning: string | undefined;
  try {
    const parsed = JSON.parse(content);
    const tournaments: any[] = Array.isArray(parsed?.tournaments) ? parsed.tournaments : [];
    const now = new Date().toISOString();
    const named = tournaments.filter((t) => t && typeof t.name === 'string');
    const allNames = named.map((t) => t.name as string);
    // Every named tournament gets a row now, even with no slot cap — platform_mode
    // needs somewhere to live for ALL tournaments, not just capped ones.
    const rows = named.map((t) => ({
      tournament_slug: t.name as string,
      slots: Number(t.slots) > 0 ? Math.floor(Number(t.slots)) : null,
      platform_mode: ['mobile', 'emulator', 'mixed'].includes(t.platform_mode) ? t.platform_mode : 'mixed',
      updated_at: now,
    }));

    const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    if (rows.length) {
      const { error } = await supabase.from('tournament_capacity').upsert(rows, { onConflict: 'tournament_slug' });
      if (error) warning = `Published to GitHub, but syncing tournament settings failed: ${error.message}`;
    }
    // Clean up rows for tournaments removed from tournaments.json entirely (not just
    // ones with no slot cap — those still need a row now, for platform_mode).
    const { data: existing, error: listErr } = await supabase.from('tournament_capacity').select('tournament_slug');
    if (!listErr) {
      const stale = (existing || []).map((r) => r.tournament_slug).filter((slug) => !allNames.includes(slug));
      if (stale.length) {
        const { error } = await supabase.from('tournament_capacity').delete().in('tournament_slug', stale);
        if (error && !warning) warning = `Published to GitHub, but clearing old tournament settings failed: ${error.message}`;
      }
    }
  } catch (e) {
    warning = `Published to GitHub, but syncing tournament settings failed: ${e instanceof Error ? e.message : String(e)}`;
  }

  return new Response(JSON.stringify({ ok: true, ...(warning ? { warning } : {}) }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
