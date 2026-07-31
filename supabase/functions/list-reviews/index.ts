// Admin-only: returns every review for one tournament, including each row's id (needed
// to delete-review a specific one) and the reviewer's username. Reviews themselves are
// public (get_tournament_reviews() is a plain anon-callable RPC), but that RPC deliberately
// omits the row id since a player-facing read has no business deleting anything -- this is
// the admin moderation counterpart, same shape as list-registrations.
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
  const tournament_slug = url.searchParams.get('tournament_slug');
  if (!tournament_slug) return new Response('tournament_slug is required', { status: 400, headers: CORS_HEADERS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data, error } = await supabase
    .from('tournament_reviews')
    .select('id, rating, comment, created_at, players(username)')
    .eq('tournament_slug', tournament_slug)
    .order('created_at', { ascending: false });
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
  return new Response(JSON.stringify(data || []), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
