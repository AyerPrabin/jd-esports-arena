// Admin-only: marks an ai_recommendations row resolved AFTER a human has already taken the
// real action through the normal admin functions (approve-registration, action-report,
// review-flag, or publish-tournaments for cancellations). This function itself changes
// NOTHING except the recommendation's own status/audit trail -- it never touches
// registrations/reports/performance_flags/tournaments.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const VALID_STATUSES = ['confirmed', 'overridden', 'dismissed'];

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
  const id = String(payload.id || '');
  const status = String(payload.status || '');
  if (!id || !VALID_STATUSES.includes(status)) {
    return new Response(`id is required and status must be one of: ${VALID_STATUSES.join(', ')}`, {
      status: 400, headers: CORS_HEADERS,
    });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { error } = await supabase
    .from('ai_recommendations')
    .update({ status, resolved_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
