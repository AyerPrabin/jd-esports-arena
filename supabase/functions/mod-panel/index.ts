// Moderator panel backend. Two kinds of caller:
//  * A MODERATOR signed in with their JD account (Authorization: Bearer <user JWT>). They may:
//      { action: 'whoami' }                    -> { ok, email }
//      { action: 'registrations', slug }       -> squads + WhatsApp + status for one tournament (for reminders)
//      { action: 'notify', title, body, slug? }-> send a push/announcement (everyone, or that tournament's players)
//      { action: 'room_code', slug, room_id, room_pass? } -> send Room ID/password to that tournament's registered squads
//      { action: 'set_confirmed', id, on }    -> mark a squad confirmed / not confirmed (mod override of the 48h window)
//      { action: 'remove_team', id, reason? } -> remove a squad (player notified; the waitlist trigger promotes the next)
//      { action: 'notify_player', id, title, body } -> push + in-app message to that squad's captain only
//      { action: 'chat_inbox' }                -> JD Esports chat threads (newest first, unread player replies)
//      { action: 'chat_thread', player_id | id | who } -> one player's JD Esports chat (marks their replies read)
//      { action: 'chat_send', player_id | id | who, body } -> write in that chat; the player sees "JD Esports" ✓
//      The chat_* actions also accept the admin secret (x-admin-secret) so the admin can answer from /admin/.
//      Every change is written to mod_actions (who, what, when) so the admin can see it.
//  * The ADMIN (x-admin-secret) manages the moderator list:
//      { action: 'mod_list' } | { action: 'mod_add', email, note?, role?, handle? } | { action: 'mod_remove', email }
// Moderators can NOT touch money, bans, tournaments, plans or anything else.
// Roles (mod_roles.sql): 'staff' = the owner's own mods, everything above. 'host' = an invited scrim host: only the
// events whose "host" field is their handle (squads, room code, notify those squads, results without prizes),
// no JD Esports chat. "All players" notifications are the owner's only. Host mods also create and edit THEIR OWN
// events ({ action: 'event_save', ... }: free entry only, never JD's prize money), and everything they send to
// players is signed with their own @handle instead of "JD".
import { createClient } from 'npm:@supabase/supabase-js@2';

// only the owner may notify every player on JD Arena
const OWNER_EMAIL = (Deno.env.get('ADMIN_EMAIL') || 'ayerprabin95@gmail.com').toLowerCase();
const normHandle = (h: unknown) => String(h || '').trim().replace(/^@+/, '').toLowerCase();

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
      const { data, error } = await admin.from('moderators').select('email, note, role, handle, added_at').order('added_at', { ascending: false });
      if (error) return fail(error.message, 500);
      return json(data || []);
    }
    if (action === 'mod_add') {
      const email = String(p.email || '').trim().toLowerCase();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return fail('Enter a valid email');
      const role = p.role === 'host' ? 'host' : 'staff';
      const handle = normHandle(p.handle);
      if (role === 'host' && !/^[a-z0-9._]{2,30}$/.test(handle)) return fail('A host mod needs a handle, e.g. their TikTok name: goats.esp');
      const { error } = await admin.from('moderators').upsert({ email, note: String(p.note || '').slice(0, 120) || null,
        role, handle: handle || null });
      if (error) return fail(/moderators_handle_key|duplicate/i.test(error.message) ? 'Another mod already uses that handle.' : error.message, 500);
      return json({ ok: true, email, role, handle: handle || null });
    }
    if (action === 'mod_remove') {
      const email = String(p.email || '').trim().toLowerCase();
      const { error } = await admin.from('moderators').delete().eq('email', email);
      if (error) return fail(error.message, 500);
      return json({ ok: true });
    }
  }

  // ── moderator actions: require a signed-in moderator (the JD Esports chat also takes the admin secret) ──
  let email = '', role = 'staff', handle = '';
  if (action.startsWith('chat_') && ADMIN_SECRET && adminHeader === ADMIN_SECRET) email = 'admin';
  else {
    const jwt = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    if (!jwt) return fail('Sign in first', 401);
    const { data: { user }, error: uErr } = await admin.auth.getUser(jwt);
    email = user?.email?.toLowerCase() || '';
    if (uErr || !email) return fail('Sign in first', 401);
    const { data: mod } = await admin.from('moderators').select('email, role, handle').eq('email', email).maybeSingle();
    if (!mod) return fail('Your account is not a moderator. Ask the JD admin to add you.', 403);
    role = mod.role === 'host' ? 'host' : 'staff';
    handle = normHandle(mod.handle);
  }
  const isHost = role === 'host';
  const isOwner = email === 'admin' || email === OWNER_EMAIL;

  // host mods: only the events whose "host" field is their handle (live site_content, same doc the site shows)
  let _mine: Set<string> | null = null;
  const myEvents = async () => {
    if (_mine) return _mine;
    const { data: sc } = await admin.from('site_content').select('content').eq('key', 'tournaments').maybeSingle();
    const list: any[] = (sc?.content as any)?.tournaments || [];
    _mine = new Set(list.filter((t) => handle && normHandle(t.host) === handle).map((t) => String(t.name)));
    return _mine;
  };
  const canEvent = async (slug: string) => !isHost || (await myEvents()).has(slug);
  const notYours = () => fail("That event isn't yours. Ask the JD admin to set you as its host.", 403);
  const tagT = (t: string) => (isHost ? `[@${handle}] ${t}` : `[JD] ${t}`).slice(0, 120);   // who the player sees it from

  if (action === 'whoami') return json({ ok: true, email, role, handle: handle || null, owner: isOwner,
    events: isHost ? [...await myEvents()] : null });
  if (isHost && action.startsWith('chat_')) return fail('The JD Esports chat is for the JD team only. Use Message on a squad to send them a notification.', 403);

  if (action === 'registrations') {
    const slug = String(p.slug || '');
    if (!slug) return fail('slug required');
    if (!await canEvent(slug)) return notYours();
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
    if (!await canEvent(slug)) return notYours();
    // hand off to the admin-only room-code sender (service creds stay server-side).
    // No player_tags -> it goes to that tournament's confirmed/approved squads only.
    const r = await fetch(`${URL_}/functions/v1/send-room-code`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-admin-secret': ADMIN_SECRET,
                 'Authorization': `Bearer ${SERVICE}`, 'apikey': SERVICE },
      body: JSON.stringify({ tournament_slug: slug, room_id, room_pass: room_pass || undefined, from: isHost ? handle : undefined }),
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
    if (data && !await canEvent((data as any).tournament_slug)) return null;   // host mods: only their events' squads
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
      body: `Your squad "${r.squad_name}" was removed from ${r.tournament_slug} by ${isHost ? '@' + handle + ' (event host)' : 'a JD moderator'}.` +
            (reason ? ` Reason: ${reason}.` : '') + ' You can join the next event from the Events page.',
    });
    const { error } = await admin.from('registrations').delete().eq('id', r.id);   // trg_promote_from_waitlist moves the next squad up
    if (error) return fail(error.message, 500);
    await log('remove', `${r.squad_name} · ${r.tournament_slug}${reason ? ' · ' + reason : ''}`);
    // the removed squad must not keep the room details
    await admin.from('notifications').delete()
      .eq('player_id', r.player_id).eq('tournament_slug', r.tournament_slug).not('room_id', 'is', null);
    const { data: rc } = await admin.from('tournament_room_codes').select('sent_at').eq('tournament_slug', r.tournament_slug).maybeSingle();
    return json({ ok: true, room_code_was_sent: !!rc?.sent_at });
  }

  if (action === 'notify_player') {
    const r = await regById(String(p.id || ''));
    if (!r) return fail('Squad not found');
    const title = String(p.title || '').trim(), body = String(p.body || '').trim();
    if (!title || !body) return fail('Title and message are required');
    const { error } = await admin.from('notifications').insert({
      player_id: r.player_id, push: true, tournament_slug: r.tournament_slug,
      title: tagT(title), body: body.slice(0, 1000),
    });
    if (error) return fail(error.message, 500);
    await log('notify_player', `${r.squad_name} · ${title}`);
    return json({ ok: true });
  }

  // ── JD Esports chat (jd_chat.sql): players see every staff message as "JD Esports" ✓ ──
  // team = squad name (big in the chat list), name = @username (small); logo only when small enough to inline
  const card = (p: any, regSquad?: string | null) => p && ({ id: p.id, name: p.username ? '@' + p.username : (p.player_tag || 'Player'),
    tag: p.player_tag || null, squad: p.squad_name || regSquad || null,
    logo: typeof p.squad_logo === 'string' && p.squad_logo.length < 40000 && /^(https:|data:image\/)/.test(p.squad_logo) ? p.squad_logo : null,
    online: !!p.last_seen_at && Date.now() - new Date(p.last_seen_at).getTime() < 120000, seen: p.last_seen_at || null,
    app: !!p.app_installed_at, joined: p.created_at || null, avatar: null as string | null });
  const PCOLS = 'id, username, player_tag, squad_name, squad_logo, last_seen_at, app_installed_at, created_at';
  // profile photos live in the private avatars bucket: short-lived signed links, one call for the whole list
  const withAvatars = async (cards: any[]) => {
    const ids = cards.filter(Boolean).map((c) => c.id);
    if (!ids.length) return cards;
    try {
      const { data } = await admin.storage.from('avatars').createSignedUrls(ids.map((i) => i + '/avatar.jpg'), 3600);
      const ok = new Map((data || []).filter((x: any) => x.signedUrl && !x.error).map((x: any) => [String(x.path).split('/')[0], x.signedUrl]));
      for (const c of cards) if (c && ok.has(c.id)) c.avatar = ok.get(c.id);
    } catch { /* no photos: initials */ }
    return cards;
  };
  if (action === 'chat_inbox') {
    // newest conversations first; unread = player replies nobody on the team has opened yet
    const { data, error } = await admin.from('jd_messages')
      .select('id, player_id, from_staff, body, created_at, read_at').eq('channel', 'jd').order('id', { ascending: false }).limit(600);
    if (error) return fail(error.message, 500);
    const threads = new Map<string, any>();
    for (const m of data || []) {
      let t = threads.get(m.player_id);
      if (!t) { t = { player_id: m.player_id, last: m.body, last_at: m.created_at, last_staff: m.from_staff, unread: 0 }; threads.set(m.player_id, t); }
      if (!m.from_staff && !m.read_at) t.unread++;
    }
    const list = [...threads.values()].slice(0, 60);
    const { data: ps } = list.length
      ? await admin.from('players').select(PCOLS).in('id', list.map((t) => t.player_id))
      : { data: [] as any[] };
    // players with no saved squad: their latest registration's squad name
    const noSquad = (ps || []).filter((x: any) => !x.squad_name).map((x: any) => x.id);
    const regSq = new Map<string, string>();
    if (noSquad.length) {
      const { data: rs } = await admin.from('registrations').select('player_id, squad_name').in('player_id', noSquad).order('created_at', { ascending: false });
      for (const r of rs || []) if (r.squad_name && !regSq.has(r.player_id)) regSq.set(r.player_id, r.squad_name);
    }
    const cards = await withAvatars((ps || []).map((x: any) => card(x, regSq.get(x.id))));
    const by = new Map(cards.map((c: any) => [c.id, c]));
    return json(list.map((t) => ({ ...t, player: by.get(t.player_id) || { id: t.player_id, name: 'Player' } })));
  }
  if (action === 'chat_read_all') {   // "Mark all read" in the inbox
    const { error } = await admin.from('jd_messages').update({ read_at: new Date().toISOString() })
      .eq('channel', 'jd').eq('from_staff', false).is('read_at', null);
    if (error) return fail(error.message, 500);
    return json({ ok: true });
  }
  // resolve who to chat with: a squad row (registration id), a player id, or @username / JD tag
  const chatTarget = async (): Promise<any> => {
    if (p.id) { const r = await regById(String(p.id)); if (!r) return null; p.player_id = r.player_id; }
    if (p.player_id && /^[0-9a-f-]{36}$/i.test(String(p.player_id))) {
      const { data } = await admin.from('players').select(PCOLS).eq('id', String(p.player_id)).maybeSingle();
      return data;
    }
    const q = String(p.who || '').trim().replace(/^@/, '');
    if (!q) return null;
    const lit = q.replace(/[,()%*"\\]/g, '').replace(/_/g, '\\_');   // exact, case-insensitive match (no wildcards)
    if (!lit) return null;
    const { data } = await admin.from('players').select(PCOLS)
      .or(`username.ilike.${lit},player_tag.ilike.${lit}`).limit(1).maybeSingle();
    return data;
  };
  if (action === 'chat_thread') {
    const pl = await chatTarget();
    if (!pl) return fail('Player not found. Check the @username or JD tag.', 404);
    const [{ data, error }, { data: regs }] = await Promise.all([
      admin.from('jd_messages').select('id, from_staff, staff_email, body, created_at, read_at')
        .eq('player_id', pl.id).eq('channel', 'jd').order('id', { ascending: false }).limit(100),
      admin.from('registrations').select('tournament_slug, squad_name, status, checked_in_at, whatsapp, created_at')
        .eq('player_id', pl.id).order('created_at', { ascending: false }).limit(6),
    ]);
    if (error) return fail(error.message, 500);
    const pc = card(pl, (regs || []).find((r: any) => r.squad_name)?.squad_name);
    // mark their replies read in parallel with the photo lookup, but finish before replying: an un-awaited write
    // can be dropped when the function shuts down, and the chat then came back as unread on the next inbox poll
    await Promise.all([withAvatars([pc]), admin.from('jd_messages').update({ read_at: new Date().toISOString() })
      .eq('player_id', pl.id).eq('channel', 'jd').eq('from_staff', false).is('read_at', null).then(() => {}, () => {})]);
    return json({ player: pc, tickets: (regs || []).map((r: any) => ({ event: r.tournament_slug, squad: r.squad_name, status: r.status,
      confirmed: !!r.checked_in_at, whatsapp: r.whatsapp || null, at: r.created_at })), messages: (data || []).reverse().map((m: any) => ({
      id: m.id, staff: m.from_staff, by: m.from_staff ? (String(m.staff_email || '').startsWith('zulu') ? 'ZULU (auto)' : m.staff_email === email ? 'You' : m.staff_email === 'admin' ? 'Admin' : String(m.staff_email || 'JD team').split('@')[0]) : null,
      body: m.body, created_at: m.created_at, read_at: m.read_at })) });
  }
  if (action === 'chat_send') {
    const pl = await chatTarget();
    if (!pl) return fail('Player not found. Check the @username or JD tag.', 404);
    const body = String(p.body || '').trim();
    if (!body) return fail('Type a message first.');
    if (body.length > 1000) return fail('That message is too long (1000 characters max).');
    const { data, error } = await admin.from('jd_messages')
      .insert({ player_id: pl.id, from_staff: true, staff_email: email, body }).select('id, created_at').single();
    if (error) return fail(error.message, 500);
    await log('chat', `${card(pl)!.name} · ${body.slice(0, 120)}`);
    return json({ ok: true, id: data.id, created_at: data.created_at, player: card(pl) });
  }

  // ── results: standings, winner, finish, prizes ──
  // Same pipeline as the admin's BO3 board: publish-tournaments (GitHub + live site_content + award_prizes)
  // and, when final, archive-results (all-time leaderboard + career stats + prize payout). Guard rails for
  // moderators: total prizes can never exceed the event's prize pool, only registered squads are paid, and
  // a squad can't be paid twice (award_prizes' ledger ref). Everything is logged in mod_actions.
  if (action === 'results_get' || action === 'results_publish') {
    const slug = String(p.slug || '').trim();
    if (!slug) return fail('Pick the event first.');
    if (!await canEvent(slug)) return notYours();
    const { data: sc } = await admin.from('site_content').select('content').eq('key', 'tournaments').maybeSingle();
    const doc: any = sc?.content;
    const t = doc?.tournaments?.find((x: any) => x.name === slug);
    if (!t) return fail('That event is not on the site.', 404);
    const pool = Number(String(t.prize || '').replace(/,/g, '').match(/\d+/)?.[0] || 0);
    const matches = Math.min(6, Math.max(1, Number(String(t.format || '').match(/(\d+)\s*match/i)?.[1] || 3)));
    const { data: regs } = await admin.from('registrations').select('squad_name, status, created_at')
      .eq('tournament_slug', slug).in('status', ['confirmed', 'approved']).order('created_at');
    const squads = [...new Set((regs || []).map((r: any) => String(r.squad_name || '').trim()).filter(Boolean))];
    const board = doc?.bo3?.tournament === slug ? doc.bo3 : null;
    const { data: paid } = await admin.from('wallet_ledger').select('ref, delta').eq('reason', 'prize').like('ref', `prize:${slug}:%`);
    if (action === 'results_get') {
      return json({ event: slug, pool, prize: t.prize || null, matches, winner: t.winner || null, status: t.status || 'upcoming',
        squads, board: board ? { published: !!board.published, teams: board.teams || [] } : null,
        paid: (paid || []).map((x: any) => ({ squad: String(x.ref).split(':').slice(2).join(':'), amount: x.delta })) });
    }

    // results_publish { slug, teams: [{ team, pts: number[] }], final?: boolean, prizes?: { [team]: amount } }
    const final = !!p.final;
    const norm = (s: string) => s.trim().toLowerCase().replace(/\s+/g, ' ');
    const regSet = new Set(squads.map(norm));
    const inTeams: any[] = Array.isArray(p.teams) ? p.teams.slice(0, 40) : [];
    const teams = inTeams.map((x: any) => ({
      team: String(x.team || '').trim().slice(0, 60),
      pts: (Array.isArray(x.pts) ? x.pts : []).slice(0, matches).map((v: any) => Math.max(0, Math.min(300, Math.round(Number(v) || 0)))),
    })).filter((x) => x.team);
    if (!teams.length) return fail('Add at least one squad with points.');
    if (new Set(teams.map((x) => norm(x.team))).size !== teams.length) return fail('A squad is listed twice.');
    for (const x of teams) while (x.pts.length < matches) x.pts.push(0);
    const total = (x: any) => x.pts.reduce((a: number, b: number) => a + b, 0);
    const ranked = [...teams].sort((a, b) => total(b) - total(a));
    const prizes: Record<string, number> = {};
    if (final) {
      for (const [k, v] of Object.entries(p.prizes || {})) {
        const amt = Math.round(Number(v) || 0);
        if (amt <= 0) continue;
        if (isHost) return fail('Prize points are paid by the JD team. Finish without prizes; the admin pays the winners.', 403);
        const tm = teams.find((x) => norm(x.team) === norm(k));
        if (!tm) return fail(`${k} isn't in the standings.`);
        if (!regSet.has(norm(tm.team))) return fail(`${tm.team} isn't a registered squad in ${slug}, so it can't be paid.`);
        prizes[tm.team] = amt;
      }
      // a squad that was already paid is never paid again, so only new payouts count against the pool
      const paidSet = new Set((paid || []).map((x: any) => norm(String(x.ref).split(':').slice(2).join(':'))));
      const sum = Object.entries(prizes).filter(([k]) => !paidSet.has(norm(k))).reduce((a, [, v]) => a + v, 0);
      const already = (paid || []).reduce((a: number, x: any) => a + (x.delta || 0), 0);
      if (!pool && sum > 0) return fail(`${slug} has no prize amount on the site, so moderators can't pay prizes. Ask the admin.`);
      if (sum + already > pool) return fail(`Prizes add up to ${sum + already} points (${already} already paid), more than the ${pool}-point prize pool.`);
    }

    // the site has ONE live standings board: a host can't replace JD's while a JD event is still running
    if (isHost && board === null && doc?.bo3?.tournament && doc.bo3.published) {
      const cur = doc.tournaments?.find((x: any) => x.name === doc.bo3.tournament);
      if (cur && !normHandle(cur.host) && !cur.winner && !['completed', 'cancelled'].includes(String(cur.status || '').toLowerCase()))
        return fail(`JD's live standings for ${cur.name} are on the site right now. Publish yours after it finishes.`, 409);
    }
    const prevLogos = new Map(((board?.teams || []) as any[]).concat(t.teams || []).map((x: any) => [norm(String(x.team || x.name || '')), x.logo || '']));
    doc.bo3 = {
      tournament: slug, title: `${slug} – ${final ? 'Final Standings' : 'Standings'}`, published: true,
      teams: ranked.map((x) => ({ team: x.team, logo: prevLogos.get(norm(x.team)) || '',
        r: x.pts.map((v: number) => ({ kills: 0, pts: v })), ...(final && prizes[x.team] ? { prize_won: prizes[x.team] } : {}) })),
    };
    if (final) { t.winner = ranked[0].team; t.status = 'completed'; }
    doc._published_at = new Date().toISOString();

    const H = { 'Content-Type': 'application/json', 'x-admin-secret': ADMIN_SECRET, 'Authorization': `Bearer ${SERVICE}`, 'apikey': SERVICE };
    const pub = await fetch(`${URL_}/functions/v1/publish-tournaments`, { method: 'POST', headers: H, body: JSON.stringify({ content: JSON.stringify(doc, null, 2) }) });
    if (!pub.ok) return fail('Could not publish: ' + (await pub.text()), 502);
    let paidOut: any[] = [];
    if (final) {
      const ar = await fetch(`${URL_}/functions/v1/archive-results`, { method: 'POST', headers: H, body: JSON.stringify({
        tournament_slug: slug,
        results: ranked.map((x, i) => ({ squad_name: x.team, placement: i + 1, kills: 0, points: total(x), prize_won: prizes[x.team] || 0 })),
      }) });
      if (!ar.ok) return fail('Standings are live, but saving to the leaderboard failed: ' + (await ar.text()), 502);
      // what's really in the wallets now (publish + archive both pay once per squad)
      const { data: nowPaid } = await admin.from('wallet_ledger').select('ref, delta').eq('reason', 'prize').like('ref', `prize:${slug}:%`);
      const got = new Map((nowPaid || []).map((x: any) => [norm(String(x.ref).split(':').slice(2).join(':')), x.delta]));
      paidOut = Object.entries(prizes).map(([k, v]) => ({ squad: k, amount: got.get(norm(k)) ?? v, status: got.has(norm(k)) ? 'paid' : 'unmatched' }));
    }
    await log(final ? 'results_final' : 'results', `${slug} · #1 ${ranked[0].team} (${total(ranked[0])})` +
      (final ? ' · prizes ' + (Object.entries(prizes).map(([k, v]) => `${k} ${v}`).join(', ') || 'none') : ''));
    return json({ ok: true, final, winner: ranked[0].team,
      standings: ranked.map((x, i) => ({ place: i + 1, team: x.team, total: total(x) })),
      prizes: paidOut.map((x: any) => ({ squad: x.squad, status: x.status, amount: x.amount })) });
  }

  // ── host mods: create / edit their OWN events (free entry; JD never pays prizes for them) ──
  if (action === 'event_save') {
    if (!isHost) return fail('Staff create events in /admin/.', 403);
    const name = String(p.name || '').trim().replace(/\s+/g, ' ').slice(0, 60);
    if (name.length < 3) return fail('Give the event a name.');
    if (/\bjd\b|jd ?esports?/i.test(name)) return fail('Use your own name for the event, not JD.');
    const m = String(p.start || '').match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/);
    if (!m) return fail('Pick a day and a time.');
    const [, y, mo, d, h, mi] = m;
    const start = `${y}-${mo}-${d}T${h}:${mi}:00+05:45`;
    const status = p.status === 'cancelled' ? 'cancelled' : 'upcoming';
    if (status === 'upcoming' && Date.parse(start) <= Date.now()) return fail('That time is in the past.');
    const MAPS = ['bermuda', 'purgatory', 'kalahari', 'alpine', 'nexterra'];
    const DEV: Record<string, string> = { mobile: 'Mobile only', mixed: 'Mix Device', emulator: 'Emulator only' };
    const device = DEV[p.device] ? String(p.device) : 'mobile';
    const matches = Math.min(6, Math.max(1, Math.round(Number(p.matches) || 3)));
    const hh = +h % 12 || 12;
    const fields = {
      date: new Date(Date.UTC(+y, +mo - 1, +d)).toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' }),
      time: `${hh}:${mi} ${+h < 12 ? 'AM' : 'PM'} NPT`, start, status,
      prize: String(p.prize || '').trim().slice(0, 40) || 'Hosted by @' + handle,
      entry: 'Free', platform: DEV[device], platform_mode: device,
      slots: Math.min(48, Math.max(2, Math.round(Number(p.slots) || 12))),
      format: 'BR · ' + matches + (matches === 1 ? ' match' : ' matches'),
      map: MAPS.includes(p.map) ? p.map : 'bermuda', host: handle,
    };
    const { data: sc } = await admin.from('site_content').select('content').eq('key', 'tournaments').maybeSingle();
    const doc: any = sc?.content;
    if (!doc?.tournaments) return fail('Could not load the events. Try again.', 500);
    const ex = doc.tournaments.find((x: any) => String(x.name).trim().toLowerCase() === name.toLowerCase());
    if (ex && normHandle(ex.host) !== handle) return fail('An event with that name already exists. Pick another name.', 409);
    if (ex && (ex.winner || String(ex.status).toLowerCase() === 'completed')) return fail("That event is finished and can't be changed.", 409);
    if (ex) Object.assign(ex, fields);
    else doc.tournaments.push({ name, game: 'Free Fire BR · Squad', ...fields, winner: '', teams: [] });
    doc._published_at = new Date().toISOString();
    const H = { 'Content-Type': 'application/json', 'x-admin-secret': ADMIN_SECRET, 'Authorization': `Bearer ${SERVICE}`, 'apikey': SERVICE };
    const pub = await fetch(`${URL_}/functions/v1/publish-tournaments`, { method: 'POST', headers: H, body: JSON.stringify({ content: JSON.stringify(doc, null, 2) }) });
    if (!pub.ok) return fail('Could not publish: ' + (await pub.text()), 502);
    await log(ex ? 'event_edit' : 'event_create', `${name} · ${fields.date} ${fields.time} · ${status}`);
    return json({ ok: true, created: !ex, name });
  }

  if (action === 'notify') {
    const title = String(p.title || '').trim();
    const body = String(p.body || '').trim();
    if (!title || !body) return fail('Title and message are required');
    let player_tags: string[] | undefined;
    if (!p.slug && !isOwner) return fail('Pick an event: notifications go only to the squads in that event.', 403);
    if (p.slug && !await canEvent(String(p.slug))) return notYours();
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
      body: JSON.stringify({ title: tagT(title), body, player_tags }),
    });
    const text = await r.text();
    if (!r.ok) return fail('Could not send: ' + text, 502);
    return json({ ok: true, sent_to: player_tags ? player_tags.length : 'everyone' });
  }

  return fail('Unknown action');
});
