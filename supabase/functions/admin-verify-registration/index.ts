// Admin-only: marks (or un-marks) a registration as verified — the organiser has
// checked the squad's ticket code with them. Backs the "Mark verified" button in the
// admin panel's Registered Teams list; stored in registrations.verified_at so it's
// permanent and shared across every device the admin uses, and players see a
// "Verified" badge on their own ticket.
import { createClient } from 'npm:@supabase/supabase-js@2';

// Browser calls this cross-origin with a custom x-admin-secret header, which makes the
// browser send a CORS preflight OPTIONS request first — without these headers that
// preflight gets rejected and the real request never goes out, surfacing to the admin
// as a plain "Failed to fetch".
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
  }
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET');
  if (!ADMIN_SECRET || req.headers.get('x-admin-secret') !== ADMIN_SECRET) {
    return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return new Response('Bad JSON', { status: 400, headers: CORS_HEADERS });
  }
  const { registration_id, verified } = payload;
  if (!registration_id || typeof verified !== 'boolean') {
    return new Response('registration_id and verified (boolean) are required', { status: 400, headers: CORS_HEADERS });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const verified_at = verified ? new Date().toISOString() : null;
  const { data, error } = await supabase
    .from('registrations')
    .update({ verified_at })
    .eq('id', registration_id)
    .select('id')
    .maybeSingle();
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
  if (!data) return new Response('Registration not found (removed?)', { status: 404, headers: CORS_HEADERS });

  return new Response(JSON.stringify({ ok: true, verified_at }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
