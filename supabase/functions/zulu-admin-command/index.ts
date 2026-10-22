// Admin-only: ZULU turns the organiser's plain-language command ("make next event Friday
// 10pm prize 500", "send room 8829371 pass jd22 for #8", "what's pending?") into a short reply
// plus a list of STRUCTURED actions from a fixed whitelist.
//
// This function never changes anything itself. The admin page shows every action as a
// preview card and only runs it after the organiser taps Confirm, through the same admin
// code paths (and admin secret) the buttons already use. The AI never sees the secret,
// and anything outside the whitelist or with bad fields is dropped here before the browser
// ever sees it.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { askAI, type AIMessage } from '../_shared/ai.ts';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

type Json = Record<string, unknown>;

const DEVICES = ['mobile', 'mixed', 'emulator'];
const MAPS = ['bermuda', 'purgatory', 'kalahari', 'alpine', 'nexterra'];
const SECTIONS = ['tournaments', 'history', 'teams', 'pending-payments', 'wallets', 'reports', 'ban-list', 'room-codes',
  'announce', 'challenges', 'reviews', 'optimizer', 'moderators'];

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const str = (v: unknown, max = 300) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const num = (v: unknown, lo: number, hi: number) => {
  const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  return Number.isFinite(n) && n >= lo && n <= hi ? Math.round(n) : undefined;
};
const isDate = (v: string) => /^\d{4}-\d{2}-\d{2}$/.test(v);
const isTime = (v: string) => /^([01]\d|2[0-3]):[0-5]\d$/.test(v);
const pick = (v: unknown, allowed: string[]) => (typeof v === 'string' && allowed.includes(v.toLowerCase()) ? v.toLowerCase() : undefined);

function eventFields(src: Json): Json {
  const out: Json = {};
  const date = str(src.date, 10), time = str(src.time, 5);
  if (isDate(date)) out.date = date;
  if (isTime(time)) out.time = time;
  const prize = num(src.prize, 0, 1_000_000); if (prize !== undefined) out.prize = prize;
  const entry = num(src.entry_points, 0, 100_000); if (entry !== undefined) out.entry_points = entry;
  const slots = num(src.slots, 2, 200); if (slots !== undefined) out.slots = slots;
  const matches = num(src.matches, 1, 12); if (matches !== undefined) out.matches = matches;
  const device = pick(src.device, DEVICES); if (device) out.device = device;
  const map = pick(src.map, MAPS); if (map) out.map = map;
  return out;
}

// Whitelist + field validation. Unknown types and malformed actions are dropped.
function cleanAction(a: Json): Json | null {
  const type = str(a.type, 40);
  switch (type) {
    case 'create_event': {
      const f = eventFields(a);
      if (!f.date || !f.time) return null;
      const name = str(a.name, 80);
      return { type, ...(name ? { name } : {}), ...f, publish: a.publish !== false };
    }
    case 'edit_event': {
      const event = str(a.event, 80);
      const set = eventFields((a.set as Json) || {});
      if (!event || !Object.keys(set).length) return null;
      return { type, event, set, publish: a.publish !== false };
    }
    case 'finish_event': {
      const event = str(a.event, 80);
      if (!event) return null;
      const winner = str(a.winner, 60);
      return { type, event, ...(winner ? { winner } : {}), publish: a.publish !== false };
    }
    case 'cancel_event': {
      const event = str(a.event, 80);
      return event ? { type, event, publish: a.publish !== false } : null;
    }
    case 'room_code': {
      const event = str(a.event, 80), room_id = str(a.room_id, 30).replace(/\s+/g, ''), room_pass = str(a.room_pass, 40);
      if (!event || !/^[A-Za-z0-9-]{3,30}$/.test(room_id)) return null;
      return { type, event, room_id, room_pass, when: a.when === 'stage' ? 'stage' : 'now' };
    }
    case 'announce': {
      const title = str(a.title, 90), message = str(a.message, 600), audience = str(a.audience, 80) || 'everyone';
      if (!title || !message) return null;
      return { type, title, message, audience };
    }
    case 'publish':
    case 'pay_prizes':
      return { type };
    // money actions (v2): ids come from the pending lists in the snapshot; the admin page re-checks them
    case 'approve_load': {
      const id = str(a.id, 40);
      if (!UUID.test(id)) return null;
      const amount = num(a.amount, 1, 100_000);
      return { type, id, ...(amount !== undefined ? { amount } : {}) };
    }
    case 'reject_load': {
      const id = str(a.id, 40);
      return UUID.test(id) ? { type, id, note: str(a.note, 200) } : null;
    }
    case 'pay_withdrawal': {
      const id = str(a.id, 40), payout_ref = str(a.payout_ref, 60);
      return UUID.test(id) ? { type, id, payout_ref } : null;
    }
    case 'reject_withdrawal': {
      const id = str(a.id, 40);
      return UUID.test(id) ? { type, id } : null;
    }
    case 'credit_points': {
      const player = str(a.player, 40).replace(/^@/, ''), amount = num(a.amount, 1, 100_000), note = str(a.note, 120);
      return player && amount !== undefined ? { type, player, amount, note } : null;
    }
    case 'open': {
      const section = pick(a.section, SECTIONS);
      return section ? { type, section } : null;
    }
    default:
      return null;
  }
}

function extractJson(text: string): Json | null {
  const start = text.indexOf('{'), end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    return JSON.parse(text.slice(start, end + 1)) as Json;
  } catch {
    return null;
  }
}

// Everything live in one call (supabase/zulu_admin_context.sql): money today / 7 days, pending loads and
// withdrawals with ids, upcoming events' seats, Weekly Pass, referrals, Optimizer, ZULU usage. Falls back to
// the old counts if the RPC is missing.
async function liveStats(): Promise<string> {
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data, error } = await sb.rpc('zulu_admin_context');
    if (!error && data) {
      return 'LIVE SNAPSHOT (JSON, from the database right now). money_today / money_7d are wallet ledger totals per reason: ' +
        'load = points bought by players (Rs in), withdraw = points cashed out (Rs out, the 1% fee stays), entry = paid ' +
        'tournament entries, pass = Weekly Pass sales (negative = spent by players), prize = prizes paid, referral = invite ' +
        'bonuses, optimizer = JD-Optimiers plans, effect = squad effects, challenge_* = Clash Squad stakes:\n' +
        JSON.stringify(data).slice(0, 9000);
    }
  } catch { /* old counts below */ }
  try {
    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const count = async (table: string, filter: (q: any) => any) => {
      const { count: c } = await filter(sb.from(table).select('id', { count: 'exact', head: true }));
      return c ?? 0;
    };
    const [loads, withdrawals, payments, reports, players] = await Promise.all([
      count('wallet_load_requests', (q) => q.eq('status', 'pending')),
      count('withdraw_requests', (q) => q.eq('status', 'pending')),
      count('registrations', (q) => q.eq('status', 'pending')),
      count('reports', (q) => q.eq('status', 'pending')).catch(() => 0),
      count('players', (q) => q),
    ]);
    return `Live numbers right now: ${loads} point-load request(s) waiting for verification, ${withdrawals} withdrawal(s) waiting, ` +
      `${payments} paid-entry payment(s) waiting, ${reports} report(s) to review, ${players} registered players.`;
  } catch {
    return 'Live numbers unavailable right now.';
  }
}

const SYSTEM = (ctx: string, stats: string) => `You are ZULU, the admin assistant for JD Esports Arena (Free Fire tournaments in Nepal), talking to the organiser Prabin.
Turn the organiser's message into a short friendly reply and zero or more ACTIONS. You never execute anything: every action is shown to the organiser as a card and only runs after they tap Confirm.

Reply with ONLY one JSON object, no markdown, in this shape:
{"reply": "1-3 short sentences", "actions": [ ... ]}

Allowed actions (use exactly these fields; omit fields the organiser didn't give - the page fills sensible defaults from the last event):
- {"type":"create_event","name":"optional, leave out to auto-number","date":"YYYY-MM-DD","time":"HH:MM 24h Nepal time","prize":500,"entry_points":0,"slots":12,"matches":3,"device":"mobile|mixed|emulator","map":"bermuda|purgatory|kalahari|alpine|nexterra","publish":true}
- {"type":"edit_event","event":"event name or #number","set":{same fields as create_event except name},"publish":true}
- {"type":"finish_event","event":"...","winner":"optional squad name","publish":true}
- {"type":"cancel_event","event":"...","publish":true}
- {"type":"room_code","event":"...","room_id":"digits","room_pass":"...","when":"now|stage"}   (stage = released automatically ~5 min before start)
- {"type":"announce","title":"...","message":"...","audience":"everyone or an event name"}
- {"type":"publish"}
- {"type":"pay_prizes"}   (pays any unpaid announced prizes into winners' wallets)
- {"type":"open","section":"${SECTIONS.join('|')}"}
- {"type":"approve_load","id":"<id from pending_loads>","amount":optional number if the screenshot showed a different amount}
- {"type":"reject_load","id":"<id from pending_loads>","note":"short reason the player will see"}
- {"type":"pay_withdrawal","id":"<id from pending_withdrawals>","payout_ref":"eSewa transaction code the organiser gives"}
- {"type":"reject_withdrawal","id":"<id from pending_withdrawals>"}   (points go back to the player)
- {"type":"credit_points","player":"exact username or JD tag","amount":50,"note":"why"}   (adds points; never negative)

Rules:
- Resolve relative dates ("tomorrow", "Friday", "this Sat") against the current Nepal date below. "10pm" -> "22:00".
- Entry "free" -> entry_points 0. A number of points/rupees for entry -> entry_points.
- If something essential is missing (e.g. a room code without a Room ID, an event without any day), ask in "reply" and return no action for it.
- Questions (how many registered, what's pending, what's next, how much money came in today / this week, how many
  passes sold, who is waiting) -> answer in "reply" from the LIVE SNAPSHOT with real numbers, no action needed. For money
  questions give points (1 point = Rs 1) and say which reasons you added up. "Summary" / "how is it going" -> 3-5 short
  lines: players, money in vs out this week, passes, what needs action now.
- Pending loads / withdrawals: only use ids that are in the snapshot. "approve all loads" -> one approve_load per pending
  load. "Mark paid" needs the eSewa transaction code - if the organiser didn't give it, ask. Never approve or pay
  anything the organiser didn't ask for.
- If the organiser asks for something no action can do, say so plainly and point to the admin section (open action).
- Never invent squads, numbers or results that are not in the data. Never promise anything happened - say "tap Confirm to ...".
- Announcements: write them in clear, friendly English (or Nepali if the organiser writes Nepali), short enough for a phone notification.

${ctx}
${stats}`;

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
  // Either the admin passcode, OR a Google sign-in as the admin email (same server-side check as
  // admin-google-login) - so one Google sign-in is enough, no second passcode step.
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET');
  let authorized = !!ADMIN_SECRET && req.headers.get('x-admin-secret') === ADMIN_SECRET;
  if (!authorized) {
    const bearer = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
    if (bearer && bearer.split('.').length === 3) {
      const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
      const { data: { user } } = await anon.auth.getUser(bearer);
      const allowed = (Deno.env.get('ADMIN_EMAIL') || 'ayerprabin95@gmail.com').toLowerCase();
      authorized = !!user?.email && user.email.toLowerCase() === allowed;
    }
  }
  if (!authorized) return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  let payload: Json;
  try {
    payload = await req.json();
  } catch {
    return new Response('Bad JSON', { status: 400, headers: CORS_HEADERS });
  }
  const message = str(payload.message, 800);
  if (!message) return new Response('message is required', { status: 400, headers: CORS_HEADERS });
  const context = str(payload.context, 6000); // event list + "now" built by the admin page
  const history: AIMessage[] = (Array.isArray(payload.history) ? payload.history : [])
    .slice(-6)
    .filter((h: any) => h && (h.role === 'user' || h.role === 'assistant') && typeof h.content === 'string')
    .map((h: any) => ({ role: h.role, content: String(h.content).slice(0, 800) }));

  const messages: AIMessage[] = [
    { role: 'system', content: SYSTEM(context, await liveStats()) },
    ...history,
    { role: 'user', content: message },
  ];
  // admin replies need reasoning over numbers: full Flash first, Flash-Lite as the fallback
  const result = await askAI(messages, undefined, { geminiModels: ['gemini-flash-latest', 'gemini-flash-lite-latest', 'gemini-2.5-flash-lite'], timeoutMs: 25000 });
  const json = result ? extractJson(result.text) : null;
  const rawActions = json && Array.isArray(json.actions) ? (json.actions as Json[]) : [];
  const actions = rawActions.slice(0, 12).map(cleanAction).filter(Boolean);
  const reply = (json && str(json.reply, 900)) ||
    (result ? 'I could not turn that into an action - try saying it a bit differently.' : 'No AI provider answered right now - try again in a minute.');
  return new Response(JSON.stringify({ reply, actions, provider: result?.provider ?? null }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
