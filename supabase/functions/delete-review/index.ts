// Admin-only: removes one review by id. Reviews are public and player-submitted
// (see submit_tournament_review() in schema.sql), so this is the moderation escape
// hatch for an abusive/spam one -- soft moderation, same posture as the rest of this
// site (no pre-approval queue, just a way to take something down after the fact).
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET');
  if (!ADMIN_SECRET || req.headers.get('x-admin-secret') !== ADMIN_SECRET) {
    return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  }

  let body: { review_id?: string };
  try {
    body = await req.json();
  } catch {
    return new Response('Invalid JSON body', { status: 400, headers: CORS_HEADERS });
  }
  const review_id = (body.review_id || '').trim();
  if (!review_id) return new Response('review_id is required', { status: 400, headers: CORS_HEADERS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { error } = await supabase.from('tournament_reviews').delete().eq('id', review_id);
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });

  return new Response(JSON.stringify({ deleted: true }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
