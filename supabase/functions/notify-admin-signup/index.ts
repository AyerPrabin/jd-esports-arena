import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush } from '../_shared/push.ts';
// Fires from a Supabase Database Webhook (INSERT on public.players — see
// SUPABASE_SETUP.md step 9), so this only ever runs off a real signup, never
// something a client could fake by calling this URL directly. Sends a
// Web Push to the admin's own devices (the admin account's saved subscriptions; formerly set by
// tapping "Enable admin alerts" on the admin panel) naming the new player's
// username.
//
// Not called from a browser (Supabase's own webhook delivery hits this server-to-server),
// but CORS headers are added anyway for consistency with the other admin-facing functions.
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
  const record = payload.record || {};
  const username = typeof record.username === 'string' ? record.username : '';
  if (!/^[A-Za-z0-9_]{3,20}$/.test(username)) {
    return new Response(JSON.stringify({ pushed: false, note: 'No valid username on record.' }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: admin } = await supabase.from('players').select('id').ilike('email', Deno.env.get('ADMIN_EMAIL') || 'ayerprabin95@gmail.com').maybeSingle();
  let pushed = false;
  if (admin) {
    try {
      pushed = (await sendPush(supabase, [admin.id], { title: 'New JD Arena signup', body: `@${username} just created an account.`, url: 'https://jdesport.co.uk/admin/', tag: 'jd-signup' })) > 0;
    } catch {
      // admin push failing shouldn't matter to Supabase's webhook delivery — nothing to retry into
    }
  }

  return new Response(JSON.stringify({ pushed }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
