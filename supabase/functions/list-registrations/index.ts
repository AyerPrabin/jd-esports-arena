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
  if (!tournament_slug) return new Response('tournament_slug is required', { status: 400, headers: CORS_HEADERS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  let q = supabase
    .from('registrations')
    .select('id, squad_name, status, payment_screenshot, created_at, players(player_tag, username, email)')
    .eq('tournament_slug', tournament_slug)
    .order('created_at', { ascending: true });
  if (status) q = q.eq('status', status);
  const { data, error } = await q;
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
  return new Response(JSON.stringify(data || []), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
