// Admin-only: review paid squad-effect requests (Rs 2 per tournament).
//   { action: 'list', tournament_slug? }      -> pending requests (newest first), with screenshot
//   { action: 'review', id, approve: bool }   -> approve: marks the request approved and sets
//                                                registrations.effect; reject: marks it rejected.
// Players can't set registrations.effect themselves (no UPDATE policy — see schema.sql),
// so this service-role function is the only way an effect goes live.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const EFFECT_LABELS: Record<string, string> = {
  gold: 'Champion', fire: 'On Fire', ice: 'Frozen', neon: 'Neon', rainbow: 'Prism',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
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
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  if (payload.action === 'list') {
    let q = supabase
      .from('effect_purchases')
      .select('id, registration_id, tournament_slug, squad_name, effect, amount_npr, payment_screenshot, status, created_at, players(username, player_tag, email)')
      .eq('status', 'pending')
      .order('created_at', { ascending: false });
    if (payload.tournament_slug) q = q.eq('tournament_slug', payload.tournament_slug);
    const { data, error } = await q;
    if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
    return json(data || []);
  }

  if (payload.action === 'review') {
    const { id, approve } = payload;
    if (!id || typeof approve !== 'boolean') {
      return new Response('id and approve (boolean) are required', { status: 400, headers: CORS_HEADERS });
    }
    const { data: p, error: pErr } = await supabase
      .from('effect_purchases').select('*').eq('id', id).maybeSingle();
    if (pErr) return new Response(pErr.message, { status: 500, headers: CORS_HEADERS });
    if (!p) return new Response('Request not found', { status: 404, headers: CORS_HEADERS });
    if (p.status !== 'pending') return new Response('This request was already reviewed', { status: 409, headers: CORS_HEADERS });
    if (approve && !p.registration_id) {
      return new Response('This squad has withdrawn from the tournament, so the effect cannot be applied', { status: 409, headers: CORS_HEADERS });
    }

    if (approve) {
      const { error } = await supabase.from('registrations').update({ effect: p.effect }).eq('id', p.registration_id);
      if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
    }
    const { error: uErr } = await supabase
      .from('effect_purchases')
      .update({ status: approve ? 'approved' : 'rejected', reviewed_at: new Date().toISOString() })
      .eq('id', id);
    if (uErr) return new Response(uErr.message, { status: 500, headers: CORS_HEADERS });

    const label = EFFECT_LABELS[p.effect] || p.effect;
    const title = approve ? `✨ Squad effect activated: ${label}` : 'Squad effect request declined';
    const body = approve
      ? `Your payment has been verified. ${p.squad_name || 'Your squad'} now shows the ${label} effect in the squad list for ${p.tournament_slug}.`
      : `We could not verify the payment for your ${label} effect on ${p.tournament_slug}. If you have already paid, please contact the organiser on Discord with your payment screenshot.`;
    await supabase.from('notifications').insert({ player_id: p.player_id, tournament_slug: p.tournament_slug, title, body });

    const appId = Deno.env.get('ONESIGNAL_APP_ID');
    const apiKey = Deno.env.get('ONESIGNAL_API_KEY');
    if (appId && apiKey) {
      try {
        await fetch('https://api.onesignal.com/notifications', {
          method: 'POST',
          headers: { Authorization: `Key ${apiKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            app_id: appId,
            target_channel: 'push',
            include_aliases: { external_id: [p.player_id] },
            headings: { en: title },
            contents: { en: body },
          }),
        });
      } catch {
        // push is best-effort; the in-app notification above already landed
      }
    }
    return json({ ok: true });
  }

  return new Response('Unknown action', { status: 400, headers: CORS_HEADERS });
});
