// Admin-only: creates a fully verified player account without Supabase Auth ever sending
// an email — sidesteps the default mailer's rate limit entirely (see list-players.ts for
// the sibling admin-list pattern this follows). Used from the "Users" popup in /admin/
// as a manual, one-at-a-time onboarding path: admin takes a username + email from a
// player (over Discord/FB/wherever they reached out), creates the account here with
// email_confirm already true, and hands the player back a magic sign-in link to click —
// no email deliverability involved on either end.
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

  const body = await req.json().catch(() => ({}));
  const username = String(body.username || '').trim();
  const email = String(body.email || '').trim().toLowerCase();
  if (!/^[A-Za-z0-9_]{3,20}$/.test(username)) {
    return new Response('Username must be 3-20 letters, numbers, or underscore.', { status: 400, headers: CORS_HEADERS });
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return new Response('Enter a valid email.', { status: 400, headers: CORS_HEADERS });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // Random temp password — the player never needs to know it if they sign in via the
  // magic link below, but it's returned too so the admin has a fallback to share.
  const tempPassword = crypto.randomUUID().replace(/-/g, '').slice(0, 16);

  const { data: created, error: createErr } = await supabase.auth.admin.createUser({
    email,
    password: tempPassword,
    email_confirm: true,
    user_metadata: { username },
  });
  if (createErr) return new Response(createErr.message, { status: 400, headers: CORS_HEADERS });

  const { data: linkData, error: linkErr } = await supabase.auth.admin.generateLink({
    type: 'magiclink',
    email,
  });
  if (linkErr) {
    // Account exists and is confirmed either way — the sign-in link is a convenience,
    // not a requirement, so don't fail the whole request over it.
    return new Response(JSON.stringify({
      player_id: created.user.id, email, username, temp_password: tempPassword, magic_link: null,
    }), { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
  }

  return new Response(JSON.stringify({
    player_id: created.user.id,
    email,
    username,
    temp_password: tempPassword,
    magic_link: linkData?.properties?.action_link || null,
  }), { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
});
