// Moderator panel backend. Two kinds of caller:
//  * A MODERATOR signed in with their JD account (Authorization: Bearer <user JWT>). They may:
//      { action: 'whoami' }                    -> { ok, email }
//      { action: 'registrations', slug }       -> squads + WhatsApp + status for one tournament (for reminders)
//      { action: 'notify', title, body, slug? }-> send a push/announcement (everyone, or that tournament's players)
//      { action: 'room_code', slug, room_id, room_pass? } -> send Room ID/password to that tournament's registered squads
//      { action: 'set_confirmed', id, on }    -> mark a squad confirmed / not confirmed (mod override of the 48h window)
//      { action: 'remove_team', id, reason? } -> remove a squad (player notified; the waitlist trigger promotes the next)
//      { action: 'notify_player', id, title, body } -> push + in-app message to that squad's captain only
//      Every change is written to mod_actions (who, what, when) so the admin can see it.
//  * The ADMIN (x-admin-secret) manages the moderator list:
//      { action: 'mod_list' } | { action: 'mod_add', email, note? } | { action: 'mod_remove', email }
// Moderators can NOT touch money, bans, tournaments, plans or anything else.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type, apikey',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}
function fail(msg: string, status = 400) {
  return new Response(msg, { status, headers: CORS_HEADERS });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') return fail('Method not allowed', 405);

  const URL_ = Deno.env.get('SUPABASE_URL')!;
  const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET') || '';
  const admin = createClient(URL_, SERVICE);

  let p: any;
  try { p = await req.json(); } catch { return fail('Bad JSON'); }
  const action = String(p.action || '');

  // ── admin-only: manage the moderator list ──
  const adminHeader = req.headers.get('x-admin-secret');
  if (['mod_list', 'mod_add', 'mod_remove'].includes(action)) {
    if (!ADMIN_SECRET || adminHeader !== ADMIN_SECRET) return fail('Unauthorized', 401);
    if (action === 'mod_list') {
      const { data, error } = await admin.from('moderators').select('email, note, added_at').order('added_at', { ascending: false });
      if (error) return fail(error.message, 500);
      return json(data || []);
    }
    if (action === 'mod_add') {
      const email = String(p.email || '').trim().toLowerCase();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return fail('Enter a valid email');
      const { error } = await admin.from('moderators').upsert({ email, note: String(p.note || '').slice(0, 120) || null });
      if (error) return fail(error.message, 500);
      return json({ ok: true, email });
    }
    if (action === 'mod_remove') {
      const email = String(p.email || '').trim().toLowerCase();
      const { error } = await admin.from('moderators').delete().eq('email', email);
      if (error) return fail(error.message, 500);
      return json({ ok: true });
    }
  }

  // ── moderator actions: require a signed-in moderator ──
  const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  if (!jwt) return fail('Sign in first', 401);
  const { data: { user }, error: uErr } = await admin.auth.getUser(jwt);
  const email = user?.email?.toLowerCase();
  if (uErr || !email) return fail('Sign in first', 401);
  const { data: mod } = await admin.from('moderators').select('email').eq('email', email).maybeSingle();
  if (!mod) return fail('Your account is not a moderator. Ask the JD admin to add you.', 403);

  if (action === 'whoami') return json({ ok: true, email });

  if (action === 'registrations') {
    const slug = String(p.slug || '');
    if (!slug) return fail('slug required');
    const { data, error } = await admin.from('registrations')
      .select('id, squad_name, status, whatsapp, checked_in_at, verified_at, created_at, players(username, player_tag)')
      .eq('tournament_slug', slug).order('created_at', { ascending: true });
    if (error) return fail(error.message, 500);
    return json((data || []).map((r: any) => ({
      id: r.id, squad_name: r.squad_name, status: r.status, whatsapp: r.whatsapp || null,
      checked_in: !!r.checked_in_at, verified: !!r.verified_at,
      captain: r.players?.username ? '@' + r.players.username : (r.players?.player_tag || null),
    })));
  }

  if (action === 'room_code') {
    const slug = String(p.slug || '').trim();
    const room_id = String(p.room_id || '').trim();
    const room_pass = String(p.room_pass || '').trim();
    if (!slug) return fail('Pick the tournament first');
    if (!room_id) return fail('Enter the Room ID');
    // hand off to the admin-only room-code sender (service creds stay server-side).
    // No player_tags -> it goes to that tournament's confirmed/approved squads only.
    const r = await fetch(`${URL_}/functions/v1/send-room-code`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-admin-secret': ADMIN_SECRET,
                 'Authorization': `Bearer ${SERVICE}`, 'apikey': SERVICE },
      body: JSON.stringify({ tournament_slug: slug, room_id, room_pass: room_pass || undefined }),
    });
    const text = await r.text();
    if (!r.ok) return fail('Could not send room code: ' + text, 502);
    let out: any; try { out = JSON.parse(text); } catch { out = {}; }
    return json({ ok: true, sent_to: out.sent ?? 0, unresolved: out.unresolved || [] });
  }

  const log = (what: string, detail: string) =>
    admin.from('mod_actions').insert({ mod_email: email, action: what, detail: detail.slice(0, 500) }).then(() => {}, () => {});
  const regById = async (id: string) => {
    if (!/^[0-9a-f-]{36}$/i.test(id)) return null;
    const { data } = await admin.from('registrations')
      .select('id, squad_name, tournament_slug, player_id, status, checked_in_at, players(player_tag)').eq('id', id).maybeSingle();
    return data as any;
  };

  if (action === 'set_confirmed') {
    const r = await regById(String(p.id || ''));
    if (!r) return fail('Squad not found');
    const on = !!p.on;
    const { error } = await admin.from('registrations').update({ checked_in_at: on ? new Date().toISOString() : null }).eq('id', r.id);
    if (error) return fail(error.message, 500);
    await log(on ? 'confirm' : 'unconfirm', `${r.squad_name} · ${r.tournament_slug}`);
    return json({ ok: true, confirmed: on });
  }

  if (action === 'remove_team') {
    const r = await regById(String(p.id || ''));
    if (!r) return fail('Squad not found');
    const reason = String(p.reason || '').trim().slice(0, 200);
    await admin.from('notifications').insert({
      player_id: r.player_id, push: true, tournament_slug: r.tournament_slug,
      title: `Removed from ${r.tournament_slug}`.slice(0, 120),
      body: `Your squad "${r.squad_name}" was removed from ${r.tournament_slug} by a JD moderator.` +
            (reason ? ` Reason: ${reason}.` : '') + ' You can join the next event from the Events page.',
    });
    const { error } = await admin.from('registrations').delete().eq('id', r.id);   // trg_promote_from_waitlist moves the next squad up
    if (error) return fail(error.message, 500);
    await log('remove', `${r.squad_name} · ${r.tournament_slug}${reason ? ' · ' + reason : ''}`);
    return json({ ok: true });
  }

  if (action === 'notify_player') {
    const r = await regById(String(p.id || ''));
    if (!r) return fail('Squad not found');
    const title = String(p.title || '').trim(), body = String(p.body || '').trim();
    if (!title || !body) return fail('Title and message are required');
    const { error } = await admin.from('notifications').insert({
      player_id: r.player_id, push: true, tournament_slug: r.tournament_slug,
      title: `[JD] ${title}`.slice(0, 120), body: body.slice(0, 1000),
    });
    if (error) return fail(error.message, 500);
    await log('notify_player', `${r.squad_name} · ${title}`);
    return json({ ok: true });
  }

  if (action === 'notify') {
    const title = String(p.title || '').trim();
    const body = String(p.body || '').trim();
    if (!title || !body) return fail('Title and message are required');
    let player_tags: string[] | undefined;
    if (p.slug) {
      const { data } = await admin.from('registrations')
        .select('players(player_tag)').eq('tournament_slug', String(p.slug))
        .in('status', ['confirmed', 'approved']); // only active squads — not no_show/pending/rejected
      player_tags = [...new Set((data || []).map((r: any) => r.players?.player_tag).filter(Boolean))];
      if (!player_tags.length) return fail('No registered players found for that tournament.');
    }
    // hand off to the existing notification sender (push + in-app + email + Discord)
    const r = await fetch(`${URL_}/functions/v1/send-notification`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-admin-secret': ADMIN_SECRET,
                 'Authorization': `Bearer ${SERVICE}`, 'apikey': SERVICE },
      body: JSON.stringify({ title: `[JD] ${title}`.slice(0, 120), body, player_tags }),
    });
    const text = await r.text();
    if (!r.ok) return fail('Could not send: ' + text, 502);
    return json({ ok: true, sent_to: player_tags ? player_tags.length : 'everyone' });
  }

  return fail('Unknown action');
});
