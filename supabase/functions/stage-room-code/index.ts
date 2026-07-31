// Admin-only: stages a room code for a tournament so tournament-reminders can
// auto-release it ~5 minutes before start, instead of the admin needing a
// second "Send Room Code" click timed exactly right. GET returns the current
// staged state (the admin panel uses this to show whether one's already
// staged or sent for the tournament currently selected); POST stages/updates
// one. Doesn't send anything itself — see tournament-reminders/index.ts for
// the actual release, and send-room-code/index.ts for the manual/instant path.
import { createClient } from 'npm:@supabase/supabase-js@2';

// Browser calls this cross-origin with a custom x-admin-secret header, which makes the
// browser send a CORS preflight OPTIONS request first — without these headers that
// preflight gets rejected and the real request never goes out, surfacing to the admin
// as a plain "Failed to fetch".
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET');
  if (!ADMIN_SECRET || req.headers.get('x-admin-secret') !== ADMIN_SECRET) {
    return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  if (req.method === 'GET') {
    const tournament_slug = new URL(req.url).searchParams.get('tournament_slug');
    if (!tournament_slug) return new Response('tournament_slug is required', { status: 400, headers: CORS_HEADERS });
    const { data, error } = await supabase
      .from('tournament_room_codes')
      .select('room_id, room_pass, staged_at, sent_at')
      .eq('tournament_slug', tournament_slug)
      .maybeSingle();
    if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
    return new Response(JSON.stringify(data), { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
  }

  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return new Response('Bad JSON', { status: 400, headers: CORS_HEADERS });
  }
  const { tournament_slug, room_id, room_pass } = payload;
  if (!tournament_slug || !room_id) {
    return new Response('tournament_slug and room_id are required', { status: 400, headers: CORS_HEADERS });
  }

  // Re-staging always clears sent_at — typing a fresh code here means either
  // nothing's gone out yet, or the admin is correcting one that has, and either
  // way the new code should be the one that (eventually) gets released.
  const { data, error } = await supabase
    .from('tournament_room_codes')
    .upsert(
      { tournament_slug, room_id, room_pass: room_pass || null, staged_at: new Date().toISOString(), sent_at: null },
      { onConflict: 'tournament_slug' },
    )
    .select('room_id, room_pass, staged_at, sent_at')
    .single();
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });

  return new Response(JSON.stringify(data), { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
});
