// ZULU answers players in an invited host's chat, only for hosts who turned it on (host_zulu.sql, Mod panel → Help).
// Called by the host_messages_zulu trigger (pg_net) when a player writes to such a host. Same shape as zulu-auto:
// wait a moment, then answer the newest unanswered message with the AI, using the host's own events and the
// player's tickets for them. Replies are host_messages rows from_staff, starting "ZULU · " so players can see
// it is the AI. Big issues (prizes, disputes, "a person please"), or a host who replied in person in the last
// 12 hours: ZULU pings the host instead. Hosts pay their own prizes; ZULU never promises JD money.
// Deploy: npx supabase functions deploy zulu-host --no-verify-jwt   (the caller has only x-cron-secret)
//   body: { ids: number[] }   header: x-cron-secret
import { createClient } from 'npm:@supabase/supabase-js@2';
import { askAI, type AIMessage } from '../_shared/ai.ts';
import { safeReply, zuluSystemPrompt } from '../_shared/zulu.ts';

const TAG = 'ZULU · ';
const HOST_HOLD_MS = 12 * 3600000;
const PER_PLAYER_DAILY = 15;
const GLOBAL_DAILY = 200;
const GEMINI_MODELS = (Deno.env.get('ZULU_CHAT_GEMINI_MODELS') || 'gemini-flash-lite-latest,gemini-flash-latest,gemini-2.5-flash-lite')
  .split(',').map((m) => m.trim()).filter(Boolean);
const FLAG = /\[FLAG\]/gi;
const exact = (v: unknown) => String(v ?? '').replace(/[\\%_]/g, '\\$&');   // ilike without wildcards: an _ in an email must not match any letter

const rules = (h: string, name: string) => `

You are ZULU, JD Arena's AI, answering inside a player's chat with @${h}${name ? ` ("${name}")` : ''}, an independent event host invited by JD. The host turned you on to help their players.
- You speak for the host's events only. Use HOST EVENTS and MY TICKETS below. Never invent times, slots, room IDs, passwords or prize amounts.
- The host runs and pays their own events: JD does NOT pay host prizes and can't move points for them. Never promise money, prizes, refunds or slots.
- Room ID and password come from the host about 5 minutes before the start, in the player's Alerts.
- Short and friendly (usually 1–3 sentences), in the player's language and style (English, Nepali or romanized Nepali). No greeting every time.
- If asked, be honest: you are ZULU, an AI, and the host reads this chat too.
- Never ask for passwords, OTPs or eSewa PINs.
- Lines marked (host) were written by the host in person. Stay consistent with them.
- End with [FLAG] when the host must step in: prize or payment questions, result disputes, cheating reports, a player asking for the host, anger, or anything you can't answer from the notes.`;

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  let ids: number[] = [];
  try { ids = ((await req.json()).ids || []).map(Number).filter((x: number) => Number.isFinite(x)).slice(0, 100); } catch { /* empty */ }
  if (!ids.length) return Response.json({ queued: 0 });
  const work = (async () => {
    await new Promise((r) => setTimeout(r, 600));
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: rows } = await db.from('host_messages').select('player_id, host_handle').in('id', ids).eq('from_staff', false);
    const pairs = [...new Map((rows || []).map((r: any) => [r.player_id + '|' + r.host_handle, r])).values()];
    const day = new Date(); day.setUTCHours(0, 0, 0, 0);
    const { count: g } = await db.from('host_messages').select('id', { count: 'exact', head: true })
      .eq('from_staff', true).like('body', TAG + '%').gte('created_at', day.toISOString());
    let used = g ?? 0;
    for (const r of pairs) {
      try { if (await answer(db, r.player_id, r.host_handle, day, used, ids)) used++; } catch (e) { console.error('zulu-host', r, e); }
    }
  })().catch((e) => console.error('zulu-host', e));
  // @ts-ignore EdgeRuntime is provided by Supabase Edge Functions
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(work); else await work;
  return Response.json({ queued: ids.length });
});

async function answer(db: any, pid: string, h: string, day: Date, used: number, ids: number[]): Promise<boolean> {
  const { data: host } = await db.from('moderators').select('email, display_name, zulu_on').eq('role', 'host').ilike('handle', exact(h)).limit(1).maybeSingle();
  if (!host?.zulu_on) return false;                                                   // turned off since the message
  const { data: hist } = await db.from('host_messages').select('id, from_staff, body, created_at')
    .eq('player_id', pid).eq('host_handle', h).order('id', { ascending: false }).limit(14);
  const msgs = (hist || []).reverse();
  const last = msgs[msgs.length - 1];
  if (!last || last.from_staff || !ids.includes(last.id)) return false;               // answered, or a newer message has its own worker
  const isZulu = (m: any) => m.from_staff && String(m.body).startsWith(TAG);
  const { data: who } = await db.from('players').select('id').ilike('email', exact(host.email)).limit(1).maybeSingle();
  const { data: pl } = await db.from('players').select('username').eq('id', pid).maybeSingle();
  const ping = (title: string) => who ? db.from('notifications').insert({ player_id: who.id, push: true, title,
    body: `@${pl?.username || 'A player'} wrote to you. Open the Mod panel, then Chats.` }) : Promise.resolve();
  const say = async (body: string) => {
    const { count: waiting } = await db.from('host_messages').select('id', { count: 'exact', head: true })
      .eq('player_id', pid).eq('host_handle', h).eq('from_staff', true).is('read_at', null);
    await db.from('host_messages').insert({ player_id: pid, host_handle: h, from_staff: true, body: (TAG + body).slice(0, 1000) });
    if (!waiting) await db.from('notifications').insert({ player_id: pid, push: true, title: `New message from @${h}`, body: 'Open Messages to read it and reply.' });
  };

  // the host answered in person recently: stay out, and make sure they know a player is waiting
  const lastHost = [...msgs].reverse().find((m: any) => m.from_staff && !isZulu(m));
  if (lastHost && Date.now() - new Date(lastHost.created_at).getTime() < HOST_HOLD_MS) { await ping('[JD] New message in your host chat'); return false; }

  const { count: mine } = await db.from('host_messages').select('id', { count: 'exact', head: true })
    .eq('player_id', pid).eq('from_staff', true).like('body', TAG + '%').gte('created_at', day.toISOString());   // across every host
  if ((mine ?? 0) >= PER_PLAYER_DAILY || used >= GLOBAL_DAILY) {
    if (!msgs.some((m: any) => isZulu(m) && /host will reply/.test(m.body))) { await say(`Thanks! @${h} will reply here soon.`); await ping('[JD] A player is waiting in your host chat'); }
    return false;
  }

  const lang = /[ऀ-ॿ]/.test(last.body) ? 'ne' : 'en';
  const promptP = zuluSystemPrompt(lang);
  const [{ data: sc }, { data: regs }] = await Promise.all([
    db.from('site_content').select('content').eq('key', 'tournaments').maybeSingle(),
    db.from('registrations').select('tournament_slug, squad_name, status, checked_in_at').eq('player_id', pid).order('created_at', { ascending: false }).limit(20),
  ]);
  const evs = ((sc?.content?.tournaments || []) as any[]).filter((t) => String(t.host || '').replace(/^@+/, '').toLowerCase() === h);
  const names = new Set(evs.map((t) => t.name));
  const notes = [
    'HOST EVENTS (newest last): ' + (evs.slice(-8).map((t) => `${t.name} – ${t.date || t.start || 'date TBA'} ${t.time || ''} – prize ${t.prize || 'none'} (paid by the host) – entry ${t.entry || 'Free'} – ${t.slots || '?'} slots – ${t.winner ? 'finished, winner ' + t.winner : t.status || 'upcoming'}`).join('; ') || 'none listed'),
    'MY TICKETS for this host: ' + ((regs || []).filter((r: any) => names.has(r.tournament_slug)).map((r: any) => `${r.tournament_slug} – ${r.squad_name || ''} – ${r.status}${r.checked_in_at ? ', confirmed playing' : ', not confirmed yet'}`).join('; ') || 'none'),
    `Player: @${pl?.username || '?'}`,
  ].join('\n');

  const turns: AIMessage[] = [];
  for (const m of msgs) {
    const role = m.from_staff ? 'assistant' : 'user';
    const content = m.from_staff ? (isZulu(m) ? String(m.body).slice(TAG.length) : '(host) ' + m.body) : String(m.body);
    if (turns.length && turns[turns.length - 1].role === role) turns[turns.length - 1].content += '\n' + content.slice(0, 600);
    else turns.push({ role, content: content.slice(0, 600) });
  }
  if (turns[0]?.role === 'assistant') turns.unshift({ role: 'user', content: '(opened the host chat)' });
  const r = await askAI([
    { role: 'system', content: (await promptP) + rules(h, host.display_name || '') },
    { role: 'user', content: 'NOTES (from the JD server):\n' + notes },
    { role: 'assistant', content: 'Got it.' },
    ...turns,
  ], undefined, { geminiModels: GEMINI_MODELS, timeoutMs: 8000, fast: true });
  const { data: newest } = await db.from('host_messages').select('id').eq('player_id', pid).eq('host_handle', h).order('id', { ascending: false }).limit(1).maybeSingle();
  if (!newest || newest.id !== last.id) return false;
  const raw = String(r?.text || '').trim();
  let big = !raw || /\[FLAG\]/i.test(raw);
  const safe = safeReply(raw.replace(FLAG, '').trim()), text = safe.text.trim();
  if (safe.risky) big = true;
  await say(text || `Thanks! @${h} will reply here soon.`);
  if (big) await ping('[JD] A player needs you in your host chat');
  else await db.from('host_messages').update({ read_at: new Date().toISOString() }).eq('player_id', pid).eq('host_handle', h).eq('from_staff', false).is('read_at', null);
  return !!raw;
}
