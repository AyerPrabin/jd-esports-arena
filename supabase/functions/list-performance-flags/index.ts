// Admin-only: returns anomaly flags (kills spiking past a squad's own history --
// see archive-results) for review. Never public, never auto-enforced.
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
  const unreviewedOnly = url.searchParams.get('unreviewed') === '1';

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  let q = supabase.from('performance_flags').select('*').order('created_at', { ascending: false });
  if (unreviewedOnly) q = q.eq('reviewed', false);
  const { data, error } = await q;
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
  return new Response(JSON.stringify(data || []), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
