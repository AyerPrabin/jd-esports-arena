// ZULU answers players in the JD Esports chat (zulu_auto.sql, jd_chat.sql). Called by the
// jd_messages_push trigger (pg_net) whenever a player writes there. For each player it waits a
// moment, then replies with the AI using the player's own account (squad, points, tickets, recent
// alerts) and the live JD schedule. It stays quiet when a moderator wrote in that chat in the last
// 20 minutes (a human is handling it) or when the newest player message already has a ZULU answer.
// The reply is a staff message (staff_email 'zulu-ai', push on) that the player sees as ZULU inside
// JD Esports; moderators still see every player message as unread in /mod/ → Chats.
// Must be deployed with --no-verify-jwt (the pg_net caller has no JWT, only x-cron-secret).
//   body: { ids: number[] }   header: x-cron-secret
import { createClient } from 'npm:@supabase/supabase-js@2';
import { askAI, type AIMessage } from '../_shared/ai.ts';
import { zuluSystemPrompt } from '../_shared/zulu.ts';

const HUMAN_QUIET_MS = 20 * 60000;
const PER_PLAYER_DAILY = 25;
const GLOBAL_DAILY = 400;
const GEMINI_MODELS = (Deno.env.get('ZULU_CHAT_GEMINI_MODELS') || 'gemini-flash-lite-latest,gemini-flash-latest,gemini-2.5-flash-lite')
  .split(',').map((m) => m.trim()).filter(Boolean);

const RULES = `

You are answering inside the player's official "JD Esports" chat, on behalf of the JD Esports team. Moderators read this chat too.
- Keep it short: 1–4 sentences, friendly, plain words. Reply in the player's language (English, Nepali, or romanized Nepali).
- Use the MY ACCOUNT note for their points, tickets, confirmations and alerts. Never invent numbers, slots, room IDs or passwords.
- You cannot change anything yourself (points, slots, confirmations, refunds, withdrawals, bans, results). For those, or if they ask for a person, are upset, or you are not sure, say a JD moderator will reply here soon.
- If they say their squad is ready / confirm, tell them to tap "Confirm you're playing" on their ticket, and that a moderator can also mark it.
- Never ask for passwords, OTPs or eSewa PINs.`;

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  let ids: number[] = [];
  try { ids = ((await req.json()).ids || []).map(Number).filter((x: number) => Number.isFinite(x)).slice(0, 100); } catch { /* empty */ }
  if (!ids.length) return Response.json({ queued: 0 });

  const work = (async () => {
    await new Promise((r) => setTimeout(r, 2500));      // let a quick burst of messages land first
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: rows } = await db.from('jd_messages').select('player_id').in('id', ids).eq('from_staff', false);
    const players = [...new Set((rows || []).map((r: any) => r.player_id))];
    const day = new Date(); day.setUTCHours(0, 0, 0, 0);
    const { count: globalCount } = await db.from('jd_messages').select('id', { count: 'exact', head: true })
      .eq('staff_email', 'zulu-ai').gte('created_at', day.toISOString());
    let used = globalCount ?? 0;
    for (const pid of players) {
      try { if (await answer(db, pid, day, used)) used++; } catch (e) { console.error('zulu-auto', pid, e); }
    }
  })().catch((e) => console.error('zulu-auto', e));
  // @ts-ignore EdgeRuntime is provided by Supabase Edge Functions
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(work); else await work;
  return Response.json({ queued: ids.length });
});

async function answer(db: any, pid: string, day: Date, used: number): Promise<boolean> {
  const { data: hist } = await db.from('jd_messages').select('id, from_staff, staff_email, body, created_at')
    .eq('player_id', pid).order('id', { ascending: false }).limit(14);
  const msgs = (hist || []).reverse();
  if (!msgs.length) return false;
  const last = msgs[msgs.length - 1];
  if (last.from_staff) return false;                                            // already answered
  const human = msgs.filter((m: any) => m.from_staff && !String(m.staff_email || '').startsWith('zulu'));
  if (human.length && Date.now() - new Date(human[human.length - 1].created_at).getTime() < HUMAN_QUIET_MS) return false;

  const { count: mine } = await db.from('jd_messages').select('id', { count: 'exact', head: true })
    .eq('player_id', pid).eq('staff_email', 'zulu-ai').gte('created_at', day.toISOString());
  const say = (body: string) => db.from('jd_messages').insert({ player_id: pid, from_staff: true, staff_email: 'zulu-ai', body: body.slice(0, 1000), push: true });
  if ((mine ?? 0) >= PER_PLAYER_DAILY || used >= GLOBAL_DAILY) {
    // out of AI for today: one hand-off note, then quiet
    const lastZulu = [...msgs].reverse().find((m: any) => m.staff_email === 'zulu-ai');
    if (!lastZulu || !/moderator will reply/.test(lastZulu.body)) await say('Thanks! A JD moderator will reply here soon.');
    return false;
  }

  // the player's own account, the same kind of note their app sends to ZULU in Messages
  const [{ data: pl }, { data: wal }, { data: regs }, { data: notes }] = await Promise.all([
    db.from('players').select('username, player_tag, squad_name').eq('id', pid).maybeSingle(),
    db.from('wallets').select('balance').eq('player_id', pid).maybeSingle(),
    db.from('registrations').select('tournament_slug, squad_name, status, checked_in_at, whatsapp').eq('player_id', pid).order('created_at', { ascending: false }).limit(5),
    db.from('notifications').select('title, created_at').eq('player_id', pid).is('room_id', null).order('created_at', { ascending: false }).limit(5),
  ]);
  const account = [
    `Player: @${pl?.username || '?'} (${pl?.player_tag || ''})${pl?.squad_name ? ', squad ' + pl.squad_name : ''}`,
    `Points balance: ${wal?.balance ?? 0}`,
    'Tickets: ' + ((regs || []).map((r: any) => `${r.tournament_slug} – ${r.squad_name || ''} – ${r.status}${r.checked_in_at ? ', confirmed playing' : ', not confirmed yet'}${r.whatsapp ? '' : ', no WhatsApp number'}`).join('; ') || 'none'),
    'Recent alerts: ' + ((notes || []).map((n: any) => n.title).join('; ') || 'none'),
  ].join('\n');

  const lang = /[ऀ-ॿ]/.test(last.body) ? 'ne' : 'en';
  const turns: AIMessage[] = [];
  for (const m of msgs) {
    const role = m.from_staff ? 'assistant' : 'user';
    const content = (m.from_staff && !String(m.staff_email || '').startsWith('zulu') ? '(JD moderator) ' : '') + String(m.body).slice(0, 600);
    if (turns.length && turns[turns.length - 1].role === role) turns[turns.length - 1].content += '\n' + content;
    else turns.push({ role, content });
  }
  if (turns[0]?.role === 'assistant') turns.unshift({ role: 'user', content: '(opened the JD Esports chat)' });
  const messages: AIMessage[] = [
    { role: 'system', content: (await zuluSystemPrompt(lang)) + RULES },
    { role: 'user', content: 'MY ACCOUNT (from the JD server):\n' + account },
    { role: 'assistant', content: 'Got it.' },
    ...turns,
  ];
  const r = await askAI(messages, undefined, { geminiModels: GEMINI_MODELS, timeoutMs: 12000 });
  // a newer player message may have arrived while the AI was thinking: that one triggers its own answer
  const { data: newest } = await db.from('jd_messages').select('id, from_staff').eq('player_id', pid).order('id', { ascending: false }).limit(1).maybeSingle();
  if (!newest || newest.id !== last.id) return false;
  const text = String(r?.text || '').trim();
  await say(text || 'Thanks! A JD moderator will reply here soon.');
  return !!text;
}
