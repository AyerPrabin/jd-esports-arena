// Admin-only: called by zulu_server.py's /admin/ai-review after council_vote() reaches a
// conclusive majority. Writes ONLY a recommendation row -- this function never touches
// registrations/reports/performance_flags/tournaments itself. The admin panel's Confirm
// button is what actually calls approve-registration/action-report/review-flag/
// publish-tournaments, exactly as if a human had done it directly.
//
// Supersedes (marks 'stale') any earlier still-pending recommendation for the same
// (kind, target) before inserting the new one, so re-running /admin/ai-review doesn't pile
// up duplicate cards for an item nobody has actioned yet.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const VALID_KINDS = ['cancel_tournament', 'approve_payment', 'resolve_report', 'review_flag'];

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

  const kind = String(payload.kind || '');
  if (!VALID_KINDS.includes(kind)) {
    return new Response(`kind must be one of: ${VALID_KINDS.join(', ')}`, { status: 400, headers: CORS_HEADERS });
  }
  const recommended_action = String(payload.recommended_action || '').trim();
  const agreement = String(payload.agreement || '').trim();
  if (!recommended_action || !agreement) {
    return new Response('recommended_action and agreement are required', { status: 400, headers: CORS_HEADERS });
  }
  const target_id = payload.target_id ?? null;
  const target_slug = payload.target_slug ?? null;
  const family_votes = payload.family_votes ?? {};
  const context_snapshot = payload.context_snapshot ?? {};

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  let staleQuery = supabase.from('ai_recommendations').update({ status: 'stale' }).eq('kind', kind).eq('status', 'pending');
  staleQuery = target_id ? staleQuery.eq('target_id', target_id) : staleQuery.eq('target_slug', target_slug);
  const { error: staleError } = await staleQuery;
  if (staleError) return new Response(staleError.message, { status: 500, headers: CORS_HEADERS });

  const { data, error } = await supabase
    .from('ai_recommendations')
    .insert({ kind, target_id, target_slug, recommended_action, agreement, family_votes, context_snapshot })
    .select('id')
    .single();
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });

  return new Response(JSON.stringify(data), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
