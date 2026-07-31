// Admin-only: returns every registered player (account signups), each with how many
// tournaments they've registered for. Used by the "Users" popup in the admin panel
// (/admin/) to show registered-player details alongside the live "online now" count,
// which comes from Supabase Realtime Presence in the browser instead (no DB row for that).
import { createClient } from 'npm:@supabase/supabase-js@2';

// Browser calls this cross-origin with a custom x-admin-secret header, which makes the
// browser send a CORS preflight OPTIONS request first — without these headers that
// preflight gets rejected and the real request never goes out, surfacing to the admin
// as a plain "Failed to fetch".
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET');
  if (!ADMIN_SECRET || req.headers.get('x-admin-secret') !== ADMIN_SECRET) {
    return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: players, error } = await supabase
    .from('players')
    .select('id, player_tag, username, email, discord_username, created_at')
    .order('created_at', { ascending: false });
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });

  // Counted here in JS rather than via a `registrations(count)` embedded aggregate —
  // that PostgREST feature is opt-in per-project (db-aggregates-enabled) and fails on
  // projects where it's off, which would silently break this whole list. A plain
  // player_id select + tally works everywhere and is plenty fast at this table's size.
  // Only confirmed/approved count — same definition get_public_roster() uses for the
  // live site's "registered" figure, so this list and that one never disagree.
  const { data: regs, error: regErr } = await supabase
    .from('registrations')
    .select('player_id')
    .in('status', ['confirmed', 'approved']);
  if (regErr) return new Response(regErr.message, { status: 500, headers: CORS_HEADERS });
  const counts = new Map<string, number>();
  for (const r of regs || []) counts.set(r.player_id, (counts.get(r.player_id) || 0) + 1);

  // last_sign_in_at lives on auth.users, not public.players — the admin API is the
  // supported way to read it (no direct table grant needed). Paginated defensively even
  // though this project is nowhere near perPage=1000 today.
  const lastSignIn = new Map<string, string | null>();
  for (let page = 1; ; page++) {
    const { data: pageData, error: authErr } = await supabase.auth.admin.listUsers({ page, perPage: 1000 });
    if (authErr) break; // don't fail the whole list over this — last-seen is a nice-to-have
    for (const u of pageData?.users || []) lastSignIn.set(u.id, u.last_sign_in_at || null);
    if (!pageData || pageData.users.length < 1000) break;
  }

  const result = (players || []).map(p => ({
    ...p,
    reg_count: counts.get(p.id) || 0,
    last_sign_in_at: lastSignIn.get(p.id) || null,
  }));
  return new Response(JSON.stringify(result), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
