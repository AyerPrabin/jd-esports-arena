// Player-triggered (not admin-gated): permanently deletes the calling player's own
// account. Reached only after they clicked a Supabase magic-link confirmation email
// (see authRequestDelete()/authConfirmDeleteAccount() in jd-arena.html) and then
// explicitly clicked "Yes, permanently delete" — this function does not run on the
// email link itself, only on that button's click.
//
// Trust model: the Authorization bearer token is the browser's live Supabase session,
// which only exists because the user just clicked the emailed magic link (proving
// control of the account's email) and then chose to delete. We re-verify that token
// server-side (never trust a client-supplied user id) before deleting anything.
import { createClient } from 'npm:@supabase/supabase-js@2';

// Browser calls this cross-origin with an Authorization header, which makes the browser
// send a CORS preflight OPTIONS request first — without these headers that preflight gets
// rejected and the real request never goes out, surfacing to the player as a plain
// "Failed to fetch".
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
  const auth = req.headers.get('authorization') || '';
  const token = auth.replace(/^Bearer\s+/i, '');
  if (!token) {
    return new Response('Missing bearer token', { status: 401, headers: CORS_HEADERS });
  }

  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: userErr } = await anon.auth.getUser(token);
  if (userErr || !user) {
    return new Response('Invalid or expired session — request a new deletion link.', { status: 401, headers: CORS_HEADERS });
  }

  const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  // Cascades to players/registrations/notifications via each table's
  // `references ... on delete cascade` in supabase/schema.sql.
  const { error: delErr } = await admin.auth.admin.deleteUser(user.id);
  if (delErr) {
    return new Response(delErr.message, { status: 500, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ deleted: true }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
