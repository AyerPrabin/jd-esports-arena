// Admin-only: resolves a report by either dismissing it or banning a specific real
// account. The admin explicitly types which player_tag/username/email to ban (the
// report's free-text "reported" field is whatever the reporter typed and may not
// exactly match a real account) -- same resolution pattern send-notification uses
// for its player_tags lookup.
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
  // report_id is optional -- the admin panel's "Ban directly" flow (not tied to any
  // report) calls this same endpoint with report_id omitted/null.
  const report_id = payload.report_id ? String(payload.report_id).trim() : '';
  const action = String(payload.action || '').trim(); // 'ban' | 'dismiss'
  const resolution_note = payload.resolution_note ? String(payload.resolution_note).trim() : null;
  if (action !== 'ban' && action !== 'dismiss') return new Response("action must be 'ban' or 'dismiss'", { status: 400, headers: CORS_HEADERS });
  if (action === 'dismiss' && !report_id) return new Response('report_id is required to dismiss a report', { status: 400, headers: CORS_HEADERS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  if (action === 'dismiss') {
    const { error } = await supabase
      .from('reports')
      .update({ status: 'dismissed', resolved_at: new Date().toISOString(), resolution_note })
      .eq('id', report_id);
    if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
  }

  // action === 'ban'
  const ban_identifier = String(payload.ban_identifier || '').trim(); // player_tag, username, or email
  const reason = String(payload.reason || '').trim();
  if (!ban_identifier) return new Response('ban_identifier (player_tag/username/email to ban) is required', { status: 400, headers: CORS_HEADERS });
  if (!reason) return new Response('reason is required', { status: 400, headers: CORS_HEADERS });

  const [byTag, byUser, byEmail] = await Promise.all([
    supabase.from('players').select('id').eq('player_tag', ban_identifier).maybeSingle(),
    supabase.from('players').select('id').eq('username', ban_identifier).maybeSingle(),
    supabase.from('players').select('id').eq('email', ban_identifier).maybeSingle(),
  ]);
  const playerId = byTag.data?.id || byUser.data?.id || byEmail.data?.id;
  if (!playerId) return new Response(`No player found matching "${ban_identifier}".`, { status: 404, headers: CORS_HEADERS });

  const { error: banErr } = await supabase
    .from('banned_players')
    .upsert({ player_id: playerId, reason, report_id: report_id || null }, { onConflict: 'player_id' });
  if (banErr) return new Response(banErr.message, { status: 500, headers: CORS_HEADERS });

  if (report_id) {
    const { error: repErr } = await supabase
      .from('reports')
      .update({ status: 'actioned', resolved_at: new Date().toISOString(), resolution_note })
      .eq('id', report_id);
    if (repErr) return new Response(repErr.message, { status: 500, headers: CORS_HEADERS });
  }

  return new Response(JSON.stringify({ ok: true, banned_player_id: playerId }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
