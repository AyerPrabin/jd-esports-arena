// Admin-only: returns AI recommendations for the admin panel's "AI Recommendations" section,
// newest first. Advisory data only -- nothing in this table has ever executed an action; the
// admin panel still calls the existing approve-registration/action-report/review-flag/
// publish-tournaments functions when a human clicks Confirm on a recommendation.
import { createClient } from 'npm:@supabase/supabase-js@2';

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
  const status = url.searchParams.get('status'); // optional: pending/confirmed/overridden/dismissed/stale
  const kind = url.searchParams.get('kind'); // optional: cancel_tournament/approve_payment/resolve_report/review_flag

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  let q = supabase
    .from('ai_recommendations')
    .select('id, kind, target_id, target_slug, recommended_action, agreement, family_votes, context_snapshot, status, created_at, resolved_at')
    .order('created_at', { ascending: false });
  if (status) q = q.eq('status', status);
  if (kind) q = q.eq('kind', kind);
  const { data, error } = await q;
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
  return new Response(JSON.stringify(data || []), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
