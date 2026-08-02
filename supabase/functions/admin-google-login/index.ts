// Hands the admin passcode (ADMIN_SECRET) back to the browser after verifying the caller
// signed in with Google as the one allowed admin email — lets admin/index.html offer
// "Sign in with Google" as a second way to populate the same localStorage value unlock()
// already uses, without touching how any other Edge Function checks x-admin-secret.
//
// The email check happens HERE, not in admin/index.html — that page is public source,
// so a client-side-only check would be trivially bypassed in DevTools. This function is
// the actual gate: it re-derives the caller's identity from their Supabase Auth JWT
// (via auth.getUser(), which validates the token against Supabase's own auth server) and
// only ever returns the secret when that verified email matches.
//
// verify_jwt is enabled for this function specifically (see deploy call) — unlike every
// other function in this project, this one genuinely expects a real Supabase Auth session,
// so requiring a valid JWT before the request even reaches this code is a reasonable extra
// layer, not something that risks breaking the x-admin-secret / x-cron-secret callers
// elsewhere, since none of them touch this function.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });

  const auth = req.headers.get('authorization') || '';
  const token = auth.replace(/^Bearer\s+/i, '');
  if (!token) return new Response('Not signed in.', { status: 401, headers: CORS_HEADERS });

  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error } = await anon.auth.getUser(token);
  if (error || !user?.email) return new Response('Invalid or expired session.', { status: 401, headers: CORS_HEADERS });

  const allowedEmail = (Deno.env.get('ADMIN_EMAIL') || 'ayerprabin95@gmail.com').toLowerCase();
  if (user.email.toLowerCase() !== allowedEmail) {
    return new Response('This Google account is not authorized for admin access.', { status: 403, headers: CORS_HEADERS });
  }

  const secret = Deno.env.get('ADMIN_SECRET');
  if (!secret) return new Response('Server not configured (ADMIN_SECRET missing).', { status: 500, headers: CORS_HEADERS });

  return new Response(JSON.stringify({ secret }), { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
});
