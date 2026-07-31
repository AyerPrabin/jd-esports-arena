// Admin-only: lifts a ban by player_tag/username/email.
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

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return new Response('Bad JSON', { status: 400, headers: CORS_HEADERS });
  }
  const identifier = String(payload.identifier || '').trim();
  if (!identifier) return new Response('identifier (player_tag/username/email) is required', { status: 400, headers: CORS_HEADERS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const [byTag, byUser, byEmail] = await Promise.all([
    supabase.from('players').select('id').eq('player_tag', identifier).maybeSingle(),
    supabase.from('players').select('id').eq('username', identifier).maybeSingle(),
    supabase.from('players').select('id').eq('email', identifier).maybeSingle(),
  ]);
  const playerId = byTag.data?.id || byUser.data?.id || byEmail.data?.id;
  if (!playerId) return new Response(`No player found matching "${identifier}".`, { status: 404, headers: CORS_HEADERS });

  const { error } = await supabase.from('banned_players').delete().eq('player_id', playerId);
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
