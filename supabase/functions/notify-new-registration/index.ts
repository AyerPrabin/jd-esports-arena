// Fires from a Supabase Database Webhook (INSERT on public.registrations -- see
// SUPABASE_SETUP.md's "auto-notify everyone on a new squad" section), so this only ever
// runs off a real registration row, never something a client could fake by calling this
// URL directly. Broadcasts a lightweight "new squad just registered" nudge to every OTHER
// player -- in-app notification + OneSignal push only, deliberately skipping email/Discord
// DM (those channels stay reserved for essential info like room codes/results, not social
// nudges that fire on every signup).
import { createClient } from 'npm:@supabase/supabase-js@2';

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
  const status = String(record.status || '');
  // Only a real, counted registration -- skip pending (payment not verified yet),
  // rejected, and waitlisted, so a squad that never actually secures a spot never
  // gets announced as one. Matches the same status filter get_public_roster() uses.
  if (status !== 'confirmed' && status !== 'approved') {
    return new Response(JSON.stringify({ sent: 0, pushed: false, note: 'Not a confirmed/approved registration.' }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
  const tournament_slug = String(record.tournament_slug || '').trim();
  const squad_name = String(record.squad_name || '').trim() || 'A new squad';
  const registeringPlayerId = record.player_id as string | undefined;
  if (!tournament_slug) {
    return new Response(JSON.stringify({ sent: 0, pushed: false, note: 'No tournament_slug on record.' }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  let q = supabase.from('players').select('id');
  if (registeringPlayerId) q = q.neq('id', registeringPlayerId); // don't announce a squad to the player who just registered it
  const { data: players, error } = await q;
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
  const targets = players || [];

  const title = '🎉 New squad alert!';
  const body = `${squad_name} just registered for ${tournament_slug} — think you can beat them?`;

  if (targets.length) {
    const rows = targets.map((t) => ({ player_id: t.id, tournament_slug, title, body }));
    const { error: insErr } = await supabase.from('notifications').insert(rows);
    if (insErr) return new Response(insErr.message, { status: 500, headers: CORS_HEADERS });
  }

  let pushed = false;
  const oneSignalAppId = Deno.env.get('ONESIGNAL_APP_ID');
  const oneSignalApiKey = Deno.env.get('ONESIGNAL_API_KEY');
  if (oneSignalAppId && oneSignalApiKey && targets.length) {
    try {
      const res = await fetch('https://api.onesignal.com/notifications', {
        method: 'POST',
        headers: { Authorization: `Key ${oneSignalApiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          app_id: oneSignalAppId,
          target_channel: 'push',
          include_aliases: { external_id: targets.map((t) => t.id) },
          headings: { en: title },
          contents: { en: body },
        }),
      });
      pushed = res.ok;
    } catch {
      // push failing shouldn't block the in-app notifications already written above
    }
  }

  return new Response(JSON.stringify({ sent: targets.length, pushed }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
