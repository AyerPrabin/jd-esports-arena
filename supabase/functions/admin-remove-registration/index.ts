// Admin-only: removes one registration from a tournament (the "✕ Remove" button in the
// admin panel's Registered Teams list). This deletes the registration row only, not the
// player's account. The existing trg_promote_from_waitlist trigger (schema.sql) fires on
// delete, so if this frees a slot the oldest waitlisted squad gets promoted on its own.
// The removed player gets an in-app notification (with the optional reason) so they
// aren't left wondering why their ticket disappeared.
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
  const { registration_id } = payload;
  const reason = String(payload.reason || '').trim().slice(0, 300);
  if (!registration_id) {
    return new Response('registration_id is required', { status: 400, headers: CORS_HEADERS });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: removed, error } = await supabase
    .from('registrations')
    .delete()
    .eq('id', registration_id)
    .select('player_id, tournament_slug, squad_name')
    .maybeSingle();
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
  if (!removed) return new Response('Registration not found (already removed?)', { status: 404, headers: CORS_HEADERS });

  // Best-effort: the removal already happened, so a failed notification insert
  // shouldn't turn this into an error the admin retries.
  await supabase.from('notifications').insert({
    player_id: removed.player_id,
    tournament_slug: removed.tournament_slug,
    title: '❌ Removed from ' + removed.tournament_slug,
    body: (removed.squad_name ? 'Your squad "' + removed.squad_name + '" was' : 'You were') +
      ' removed from this tournament by the organiser.' +
      (reason ? '\nReason: ' + reason : '') +
      '\nThink this is a mistake? Message us on WhatsApp or Discord.',
  });

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
