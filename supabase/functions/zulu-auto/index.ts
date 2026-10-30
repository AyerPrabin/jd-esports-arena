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
import { safeReply, teamAnswers, zuluSystemPrompt } from '../_shared/zulu.ts';

const HUMAN_QUIET_MS = 20 * 60000;
const PER_PLAYER_DAILY = 25;
const GLOBAL_DAILY = 400;
const GEMINI_MODELS = (Deno.env.get('ZULU_CHAT_GEMINI_MODELS') || 'gemini-flash-lite-latest,gemini-flash-latest,gemini-2.5-flash-lite')
  .split(',').map((m) => m.trim()).filter(Boolean);

// what the app's "Talk to a person" button sends (chat.js HUMAN_ASK): answered at once, without the AI
const HUMAN_ASK = /talk to a person from the JD team/i;

const RULES = `

You are answering inside the player's official "JD Esports" / "JD Support" chat, on behalf of the JD Esports team. Moderators read this chat too.
- Sound like a friendly person from the team texting back, not a help-desk robot: short (usually 1–3 sentences), warm, casual, no "As an AI", no "I hope this helps", no long lists, no greeting at the start of every reply.
- Talk the way THIS player talks (see PLAYER STYLE): the same language mix (English, Nepali, romanized Nepali like "kaile", "huncha", "bro"), about the same length, the same level of slang and emoji. If they write short and casual, you write short and casual. Never copy rude words.
- Reply in the player's language.
- If they ask whether you are a bot or a real person, be honest: you are ZULU, JD Arena's AI, and and you bring in a JD team member whenever the issue needs one.
- Never say a human checked something when nobody did.
- Use the MY ACCOUNT note for their points, tickets, confirmations and alerts. Never invent numbers, slots, room IDs or passwords.
- You cannot change anything yourself (points, slots, confirmations, refunds, withdrawals, bans, results). For those, or if they ask for a person, are upset, or you are not sure, say a JD team member will reply here soon AND end with [FLAG].
- If they say their squad is ready / confirm, tell them to tap "Confirm you're playing" on their ticket, and that a moderator can also mark it.
- Never ask for passwords, OTPs or eSewa PINs.
- You handle this chat on your own. The JD team only joins when you flag it. Flag ONLY big issues: points/payment not received, prize or withdrawal problems, refunds, result disputes, bans, cheating/hacker reports, a hacked account, a very upset player, or anything you truly cannot solve. To flag, end your reply with the exact tag [FLAG] and tell them a JD team member will reply here soon. Never flag simple questions.`;
const FLAG = /\[FLAG\]/gi;

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  let ids: number[] = [];
  try { ids = ((await req.json()).ids || []).map(Number).filter((x: number) => Number.isFinite(x)).slice(0, 100); } catch { /* empty */ }
  if (!ids.length) return Response.json({ queued: 0 });

  const work = (async () => {
    await new Promise((r) => setTimeout(r, 600));       // let a quick burst of messages land first (was 1.2 s)
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
    .eq('player_id', pid).eq('channel', 'jd').order('id', { ascending: false }).limit(14);
  const msgs = (hist || []).reverse();
  if (!msgs.length) return false;
  const last = msgs[msgs.length - 1];
  if (last.from_staff) return false;                                            // already answered
  const human = msgs.filter((m: any) => m.from_staff && !String(m.staff_email || '').startsWith('zulu'));
  if (human.length && Date.now() - new Date(human[human.length - 1].created_at).getTime() < HUMAN_QUIET_MS) return false;

  // flagged: player messages stay unread in /mod/ and the moderators get a push (dm-push kind 'staff');
  // handled by ZULU: marked read, so the team's inbox only lights up for the big issues
  const flag = () => fetch(Deno.env.get('SUPABASE_URL') + '/functions/v1/dm-push', {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'x-cron-secret': Deno.env.get('CRON_SECRET')! },
    body: JSON.stringify({ kind: 'staff', ids: msgs.filter((m: any) => !m.from_staff).map((m: any) => m.id) }),
  }).catch((e) => console.error('zulu-auto flag', e));
  const handled = () => db.from('jd_messages').update({ read_at: new Date().toISOString() })
    .eq('player_id', pid).eq('channel', 'jd').eq('from_staff', false).is('read_at', null);
  const say0 = (body: string) => db.from('jd_messages').insert({ player_id: pid, from_staff: true, staff_email: 'zulu-ai', body, push: true });
  if (HUMAN_ASK.test(String(last.body))) {   // the app's hand-off button: instant, no AI; moderators see it unread in /mod/
    await say0('Got it 👍 A JD team member will reply right here as soon as they can. You can keep writing what the problem is - send your username and a screenshot if it is about points, prizes or results.');
    await flag();
    return false;
  }

  const { count: mine } = await db.from('jd_messages').select('id', { count: 'exact', head: true })
    .eq('player_id', pid).eq('channel', 'jd').eq('staff_email', 'zulu-ai').gte('created_at', day.toISOString());
  const say = (body: string) => say0(body.slice(0, 1000));
  if ((mine ?? 0) >= PER_PLAYER_DAILY || used >= GLOBAL_DAILY) {
    // out of AI for today: one hand-off note, then quiet
    const lastZulu = [...msgs].reverse().find((m: any) => m.staff_email === 'zulu-ai');
    if (!lastZulu || !/moderator will reply/.test(lastZulu.body)) { await say('Thanks! A JD moderator will reply here soon.'); await flag(); }
    return false;
  }

  // started now, in parallel with the account reads below (faster replies)
  const lang = /[ऀ-ॿ]/.test(last.body) ? 'ne' : 'en';
  const promptP = zuluSystemPrompt(lang);
  const learnedP = teamAnswers(msgs.filter((m: any) => !m.from_staff).slice(-3).map((m: any) => m.body).join(' '), pid);
  // the player's own account, the same kind of note their app sends to ZULU in Messages
  const [{ data: pl }, { data: wal }, { data: regs }, { data: notes }, { data: own }] = await Promise.all([
    db.from('players').select('username, player_tag, squad_name').eq('id', pid).maybeSingle(),
    db.from('wallets').select('balance').eq('player_id', pid).maybeSingle(),
    db.from('registrations').select('tournament_slug, squad_name, status, checked_in_at, whatsapp').eq('player_id', pid).order('created_at', { ascending: false }).limit(5),
    db.from('notifications').select('title, created_at').eq('player_id', pid).is('room_id', null).order('created_at', { ascending: false }).limit(5),
    // how this player writes: only their own messages in this chat (never their private chats with other players)
    db.from('jd_messages').select('body').eq('player_id', pid).eq('channel', 'jd').eq('from_staff', false).order('id', { ascending: false }).limit(40),
  ]);
  const samples = (own || []).map((m: any) => String(m.body || '').trim()).filter((b: string) => b && !HUMAN_ASK.test(b)).slice(0, 12);
  const words = samples.join(' ');
  const style = samples.length ? [
    'PLAYER STYLE (their own recent messages here, newest first - match this tone, never copy rude words):',
    ...samples.map((b: string) => '- ' + b.slice(0, 140)),
    `Typical length: about ${Math.round(words.length / samples.length)} characters` +
      (/[\u0900-\u097F]/.test(words) ? '; writes in Nepali script' : '') +
      (/\b(cha|chha|huncha|hunchha|kaile|kina|ho|haina|bro|dai|vai|bhai|yaar|ni|ta)\b/i.test(words) ? '; mixes romanized Nepali with English' : '') +
      (/\p{Extended_Pictographic}/u.test(words) ? '; uses emoji' : '; rarely uses emoji'),
  ].join('\n') : 'PLAYER STYLE: new player, no earlier messages - friendly and simple.';
  const account = [
    `Player: @${pl?.username || '?'} (${pl?.player_tag || ''})${pl?.squad_name ? ', squad ' + pl.squad_name : ''}`,
    `Points balance: ${wal?.balance ?? 0}`,
    'Tickets: ' + ((regs || []).map((r: any) => `${r.tournament_slug} – ${r.squad_name || ''} – ${r.status}${r.checked_in_at ? ', confirmed playing' : ', not confirmed yet'}${r.whatsapp ? '' : ', no WhatsApp number'}`).join('; ') || 'none'),
    'Recent alerts: ' + ((notes || []).map((n: any) => n.title).join('; ') || 'none'),
  ].join('\n');

  const turns: AIMessage[] = [];
  for (const m of msgs) {
    const role = m.from_staff ? 'assistant' : 'user';
    const content = (m.from_staff && !String(m.staff_email || '').startsWith('zulu') ? '(JD moderator) ' : '') + String(m.body).slice(0, 600);
    if (turns.length && turns[turns.length - 1].role === role) turns[turns.length - 1].content += '\n' + content;
    else turns.push({ role, content });
  }
  if (turns[0]?.role === 'assistant') turns.unshift({ role: 'user', content: '(opened the JD Esports chat)' });
  const messages: AIMessage[] = [
    { role: 'system', content: (await promptP) + (await learnedP) + RULES },
    { role: 'user', content: 'MY ACCOUNT (from the JD server):\n' + account + '\n\n' + style },
    { role: 'assistant', content: 'Got it.' },
    ...turns,
  ];
  const r = await askAI(messages, undefined, { geminiModels: GEMINI_MODELS, timeoutMs: 9000 });
  // a newer player message may have arrived while the AI was thinking: that one triggers its own answer
  const { data: newest } = await db.from('jd_messages').select('id, from_staff').eq('player_id', pid).eq('channel', 'jd').order('id', { ascending: false }).limit(1).maybeSingle();
  if (!newest || newest.id !== last.id) return false;
  const raw = String(r?.text || '').trim();
  let big = !raw || /\[FLAG\]/i.test(raw) || /(moderator|team member|JD team).{0,30}(reply|join|check|contact)/i.test(raw);
  const safe = safeReply(raw.replace(FLAG, '').trim()), text = safe.text.trim();
  if (safe.risky) big = true;   // a promise only a person may make: the team checks it
  await say(text || 'Thanks! A JD moderator will reply here soon.');
  if (big) await flag(); else await handled();
  return !!raw;
}
