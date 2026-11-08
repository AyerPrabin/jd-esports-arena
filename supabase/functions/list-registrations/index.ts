// Admin-only: returns the roster of players registered for one tournament.
// Used by both the "Room Codes" panel (no status filter — sees everyone) and
// the "Pending Payments" panel (?status=pending) in the admin panel (/admin/).
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
  const url = new URL(req.url);
  const tournament_slug = url.searchParams.get('tournament_slug');
  const status = url.searchParams.get('status');
  // ?lite=1&slugs=["A","B"]: every open event's statuses in ONE call (admin dashboard, was one call per event)
  if (url.searchParams.get('lite') === '1' && url.searchParams.get('slugs')) {
    let slugs: string[] = [];
    try { slugs = (JSON.parse(url.searchParams.get('slugs')!) as unknown[]).map(String).slice(0, 60); } catch { /* bad list */ }
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data, error } = await db.from('registrations').select('tournament_slug, status, verified_at').in('tournament_slug', slugs);
    if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
    return new Response(JSON.stringify({ by_slug: data || [] }), { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
  }
  if (!tournament_slug) return new Response('tournament_slug is required', { status: 400, headers: CORS_HEADERS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  // ?lite=1: the admin dashboard only counts statuses, so no logos or screenshots (was ~540 KB a load, 8 Nov 2026)
  if (url.searchParams.get('lite') === '1') {
    const { data, error } = await supabase.from('registrations').select('status, verified_at').eq('tournament_slug', tournament_slug);
    if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
    return new Response(JSON.stringify(data || []), { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
  }
  let q = supabase
    .from('registrations')
    .select('id, squad_name, squad_logo, status, payment_screenshot, device_type, checked_in_at, verified_at, lineup, lineup_at, created_at, whatsapp, players(player_tag, username, email, squad_logo, squad_name)')
    .eq('tournament_slug', tournament_slug)
    .order('slot_key', { ascending: true });
  if (status) q = q.eq('status', status);
  const { data, error } = await q;
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
  // Squad logos are saved once on the player's profile (players.squad_logo), not per registration.
  const rows = (data || []).map((r: any) => {
    const { squad_logo: profileLogo, ...player } = r.players || {};
    return { ...r, squad_logo: r.squad_logo || profileLogo || null, players: r.players ? player : null };
  });
  return new Response(JSON.stringify(rows), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
