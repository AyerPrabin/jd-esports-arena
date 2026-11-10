// Public (no admin gate — every visitor's browser calls this, not just admin).
// ZULU's last resort: called from zuluRespond() in index.html ONLY when the local
// pattern-matched systems (zuluPersonalMatch/zuluPublic) have nothing, instead of the
// old dead-end "I don't have that one yet" message. Tries multiple free-tier AI
// providers (see _shared/ai.ts) with a system prompt scoping it to JD Esports Arena
// topics -- Groq first (fast, generous free tier), falling back to Gemini and others,
// so this isn't limited to one provider's small daily quota.
//
// Rate-limited via zulu_ai_reply_log (schema.sql): a per-IP burst cap (stop one client
// hammering it) and a global daily cap (stop the shared free quota -- also used by
// generate-match-recap and zulu_server.py's own council calls -- being exhausted by
// public chat traffic alone). Both limits fail OPEN on a logging/count error (a Supabase
// hiccup shouldn't take chat down) but fail CLOSED once a real cap is hit. Over a cap
// returns {reply: null} with HTTP 200, same shape as "no provider configured"/"AI error"
// below -- index.html's zuluAsk() already treats a null reply as "fall back to the local
// canned answer", so a maxed-out quota degrades gracefully instead of erroring visibly.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { askAI, lastAIError, streamGemini, streamOpenAICompat, type AIMessage } from '../_shared/ai.ts';
import { kbFallback, kbPrompt, kbReplyLang, kbSmallTalk } from '../_shared/zulu_kb.ts';
import { contextVersion, safeReply, teamAnswers, zuluSystemPrompt } from '../_shared/zulu.ts';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const BURST_CAP = Number(Deno.env.get('ZULU_AI_REPLY_BURST_CAP') || '8');       // per IP
const BURST_WINDOW_SEC = Number(Deno.env.get('ZULU_AI_REPLY_BURST_WINDOW_SEC') || '60');
// Chat: Flash-Lite first (answers in ~2s; full Flash "thinks" and took ~19s in testing),
// with Flash as the fallback when Lite's quota runs out (per-model fallback in _shared/ai.ts).
const CHAT_GEMINI_MODELS = (Deno.env.get('ZULU_CHAT_GEMINI_MODELS') || 'gemini-flash-lite-latest,gemini-flash-latest,gemini-2.5-flash-lite')
  .split(',').map((m) => m.trim()).filter(Boolean);
const DAILY_CAP = Number(Deno.env.get('ZULU_AI_REPLY_DAILY_CAP') || '300');     // global, all IPs
// ^ 300 sits well under the free chain's combined allowance (Gemini Flash-Lite alone is
// ~1,000+/day, Groq ~1,000/day), leaving headroom for generate-match-recap and
// zulu_server.py's admin-review council calls that share the same keys. It was 15 when
// Gemini 2.5 Flash (~20/day) was the only provider.
const MODEL_TIMEOUT_MS = Number(Deno.env.get('ZULU_CHAT_MODEL_TIMEOUT_MS') || '9000');

// Answer cache for first questions (no history, no account): the same FAQ asked by many
// players ("next tournament?", "what is weekly pass?") is answered instantly and costs no
// quota. Short TTL because answers quote live seat counts. Per warm isolate, bounded.
const ANSWER_TTL_MS = 90000;
const answers = new Map<string, { at: number; reply: string; provider: string }>();
const answerKey = (lang: string, q: string) => lang + '|' + q.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
// ── who is asking: player, JD mod (staff), host mod or the admin ──
// Checked here from the login token, never from what the person types, so "I'm a mod" in a
// message changes nothing. Only the matching guide goes into the prompt.
const OWNER_EMAIL = (Deno.env.get('ADMIN_EMAIL') || 'ayerprabin95@gmail.com').toLowerCase();
type Role = 'admin' | 'staff' | 'host' | null;
async function whoIsAsking(req: Request, supabase: any): Promise<Role> {
  const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim();
  if (!jwt || jwt.split('.').length !== 3) return null;
  try {
    const { data: { user } } = await supabase.auth.getUser(jwt);
    const email = String(user?.email || '').toLowerCase();
    if (!email) return null;
    if (email === OWNER_EMAIL) return 'admin';
    const { data: mod } = await supabase.from('moderators').select('role').eq('email', email).maybeSingle();
    return mod ? (mod.role === 'host' ? 'host' : 'staff') : null;
  } catch { return null; }
}

const MOD_PANEL = `MOD PANEL (jdesport.co.uk/mod/ — sign in with the same account). Tabs: Events, Squads, Results, Chats, Room code, Notification, How it works.
- Pick tonight's event at the top first; every tab works on that event.
- Events: "+ New event" or "Edit this event", then "Save & publish" (or "Create & publish") — that is how an event change goes live. "Cancel event" cancels it.
- Squads: set Playing to Yes for squads that confirmed; WhatsApp button sends a ready reminder; Remove a squad that never confirms (waitlist moves up by itself); "Give slot" / "+ Add squad"; "Replace unconfirmed" swaps no-shows for waitlisted squads.
- Room code: type Room ID and password, tap "Send room code" about 5 minutes before start. Only squads in a slot get it. If you remove a squad after sending, change the password and send again.
- Notification: pick a template or write one, "Send notification" — goes only to squads in that event, never everyone.
- Results: type each squad's points per match, tap "Publish standings" after each match so the live leaderboard updates. After the last match tap "Finish & pay prizes": sets the winner, marks the event finished, saves the all-time leaderboard and pays prizes into winners' wallets (prizes go in the "Prizes" boxes; only registered squads, never more than the prize pool, each squad once, all logged for the admin).
- Chats (JD team only): Message a squad or type @username; players see "JD Esports" with a tick, never the mod's name or email.
- Mods can't change points balances, bans, withdrawals or other events' settings — those stay with the admin.`;

const ROLE_GUIDE: Record<string, string> = {
  staff: `

THE PERSON ASKING IS A VERIFIED JD MODERATOR (checked from their login, not from what they typed). Treat them as JD staff, not a player. When they say "publish", "results", "room", "remove", "slot", "notify", "finish" or "prize", they mean doing it in the Mod panel — never answer as if they were a player registering. Teach them step by step with the exact button names below, one short numbered list, and offer the next step. If something needs the admin (points, bans, withdrawals, refunds), say so plainly.
${MOD_PANEL}`,
  host: `

THE PERSON ASKING IS A VERIFIED HOST MOD (an invited scrim host, checked from their login). They use the Mod panel but only see the events the JD admin made them host of. They have no Chats tab and no JD prize payouts: their button is "Finish event", and prizes for their events are their own business, not JD points. Teach them step by step with exact button names; never answer as if they were a player.
${MOD_PANEL}`,
  admin: `

THE PERSON ASKING IS PRABIN, THE JD ADMIN AND OWNER (checked from their login). Answer as their assistant, not as if they were a player. Be direct and practical.
ADMIN PANEL (the private admin page): "🚀 Publish changes" is the one step that makes event edits live (it also pays any newly announced prizes). Sections: Tournaments (edit cards, "+ New event", "Create & publish", Finish → winner, Cancel), History, Teams, Payments (approve point loads from eSewa screenshots), Points (wallets, withdrawals, "🏆 Pay prizes now" only to retry), Optimizer, Mods (add/remove moderators and host mods by email), MEGA, Challenges, Room codes, Announce, Reports, Bans, Flags, Reviews. Results board: type points per match and the prize for 1st/2nd/3rd in each squad's prize box, tick Published, then Publish changes; prizes are paid once per squad. The admin page also has its own ZULU helper that can create/edit/finish events and publish after showing a preview.
Moderators use the Mod panel:
${MOD_PANEL}
If they ask how to teach a mod, give the mod-panel steps in plain words they can forward.`,
};

const json = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
const text = (body: string) => new Response(body, { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'text/plain; charset=utf-8' } });

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return new Response('Bad JSON', { status: 400, headers: CORS_HEADERS });
  }
  const message = String(payload.message || '').trim().slice(0, 500); // cap input length -- keeps prompts (and quota use) small
  const lang = payload.lang === 'ne' ? 'ne' : 'en';
  // Last few turns of THIS chat (sent by the browser) so follow-ups like "and the entry
  // fee?" make sense. Capped hard: 8 turns x 500 chars. Player-typed text, so it only ever
  // goes in as conversation turns, never into the system prompt.
  const history: AIMessage[] = (Array.isArray(payload.history) ? payload.history : [])
    .slice(-8)
    .filter((h: any) => h && (h.role === 'user' || h.role === 'assistant') && typeof h.content === 'string' && h.content.trim())
    .map((h: any) => ({ role: h.role, content: String(h.content).slice(0, 500) }));
  if (!message) return new Response('message is required', { status: 400, headers: CORS_HEADERS });
  // Logged-in players chatting with ZULU in 💬 Messages (chat.js) also send a short summary
  // of their OWN account (squad, points balance, tickets, live challenges) so ZULU can answer
  // "how many points do I have?" or "when is my match?". It is the player's own data, typed
  // by their own app, so it only ever goes in as a user turn, never into the system prompt,
  // and it is capped hard. This is deliberately NOT in _shared/zulu.ts: @zulu in squad and
  // match chats (chat-push) must never see one player's account.
  const account = typeof payload.account === 'string' ? payload.account.replace(/[^\S\n]+/g, ' ').trim().slice(0, 2400) : '';

  // stream:true (new chat clients): the reply comes back as plain text written piece by piece,
  // so it appears word by word. Everyone else (Discord bot, @zulu in chats, old cached pages)
  // keeps getting the JSON {reply} as before. Limits and caps answer JSON in both modes.
  const stream = payload.stream === true;
  // "hlo", "thanks", "ok": answered at once from the answer book (no AI, no quota, never a wrong old topic)
  const prev = history[history.length - 1];
  const small = prev?.role === 'assistant' && /\?\s*$/.test(prev.content) ? null : kbSmallTalk(message);
  if (small) return stream ? text(small) : json({ reply: small, provider: 'kb' });
  // when every AI model fails, the answer book's checked answer is sent instead of nothing
  const fallback = () => { const f = kbFallback(message); return f ? f.text : null; };
  // keyed by the live-context fingerprint too: an event edit or a new squad makes old answers miss at once
  const authed = /^Bearer\s+\S+\.\S+\.\S+/i.test(req.headers.get('authorization') || '');   // signed in: may be a mod, so no shared cache
  const cacheKey = !history.length && !account && !authed ? (await contextVersion()) + '|' + answerKey(lang, message) : '';
  const hit = cacheKey ? answers.get(cacheKey) : undefined;
  if (hit && Date.now() - hit.at < ANSWER_TTL_MS) {
    if (stream) return text(hit.reply);
    return json({ reply: hit.reply, provider: hit.provider + ':cached' });
  }
  // Built while the rate-limit checks run, not after them.
  const promptP = zuluSystemPrompt(lang);
  const learnedP = teamAnswers(message);   // how the JD team answered similar questions

  const ip = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim() || 'unknown';
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const roleP = authed ? whoIsAsking(req, supabase) : Promise.resolve(null as Role);

  try {
    const sinceBurst = new Date(Date.now() - BURST_WINDOW_SEC * 1000).toISOString();
    const sinceDay = new Date(); sinceDay.setUTCHours(0, 0, 0, 0);
    const [{ count: burstCount, error: burstErr }, { count: dailyCount, error: dailyErr }] = await Promise.all([
      supabase.from('zulu_ai_reply_log').select('id', { count: 'exact', head: true }).eq('ip', ip).gte('created_at', sinceBurst),
      supabase.from('zulu_ai_reply_log').select('id', { count: 'exact', head: true }).gte('created_at', sinceDay.toISOString()),
    ]);
    if (!burstErr && (burstCount ?? 0) >= BURST_CAP) {
      return new Response(JSON.stringify({ reply: null, note: 'Rate limited -- slow down a moment.' }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    if (!dailyErr && (dailyCount ?? 0) >= DAILY_CAP) {
      return new Response(JSON.stringify({ reply: null, note: 'Daily AI quota reached -- try again tomorrow.' }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    // Logged as an attempt (before calling the AI, not after) so the cap bounds total
    // calls regardless of whether this particular one succeeds.
    supabase.from('zulu_ai_reply_log').insert({ ip }).then(() => {}, () => {}); // not awaited: lands long before the AI answers
  } catch {
    // Best-effort rate limiting: a Supabase hiccup here shouldn't take public chat down,
    // it just means this one request isn't counted/capped.
  }

  const role = await roleP;
  // the team's answers help but never hold a reply up
  const learned = await Promise.race([learnedP, new Promise<string>((r) => setTimeout(() => r(''), 500))]);
  const mine = [...history.filter((h) => h.role === 'user').map((h) => h.content), message];
  const systemPrompt = (await promptP) + learned + kbPrompt(message) + (role ? ROLE_GUIDE[role] : '') + kbReplyLang(mine, lang);

  const messages: AIMessage[] = [
    { role: 'system', content: systemPrompt + (account ? `

This player is signed in, and the conversation starts with a MY ACCOUNT note their own app sent. You may use it to answer questions about their own account (points, tickets, check-in, their challenges, and the notifications they were sent, e.g. warnings, removals, results) and to suggest a useful next step. It overrides the "no per-player data" rule for that player only. Never invent anything that isn't in it; if it doesn't say, tell them where to look.` : '') },
    ...(account ? [
      { role: 'user' as const, content: 'MY ACCOUNT (sent by my JD Arena app):\n' + account },
      { role: 'assistant' as const, content: 'Got it — I\'ll use that for questions about your account.' },
    ] : []),
    ...history,
    { role: 'user', content: message },
  ];

  if (stream) {
    const enc = new TextEncoder();
    const body = new ReadableStream({
      async start(ctrl) {
        let full = '', provider = '';
        try {
          const send = (t: string) => { full += t; ctrl.enqueue(enc.encode(t)); };
          // Groq first: its first word lands in well under a second; Gemini streams if Groq is down.
          const g = await streamOpenAICompat('groq', messages, send, MODEL_TIMEOUT_MS);
          const s = g || (full ? null : await streamGemini(messages, CHAT_GEMINI_MODELS, send));
          if (g) provider = 'groq:' + g.model + ':stream';
          else if (s) provider = 'gemini:' + s.model + ':stream';
          else if (!full) {                         // no model started: the normal chain, sent in one piece
            const r = await askAI(messages, undefined, { geminiModels: CHAT_GEMINI_MODELS, timeoutMs: MODEL_TIMEOUT_MS, fast: true });
            if (r) { full = safeReply(r.text).text; provider = r.provider; ctrl.enqueue(enc.encode(full)); }
            else {
              console.error('zulu-ai-reply: every AI model failed', JSON.stringify(lastAIError));
              const f = fallback();
              if (f) { full = f; ctrl.enqueue(enc.encode(f)); }
            }
          }
        } catch { /* whatever was sent stays; the page falls back if nothing came */ }
        if (cacheKey && full.trim() && provider) {
          if (answers.size > 200) answers.delete(answers.keys().next().value!);
          answers.set(cacheKey, { at: Date.now(), reply: safeReply(full.trim()).text, provider });
        }
        ctrl.close();
      },
    });
    return new Response(body, { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-cache', 'X-Content-Type-Options': 'nosniff' } });
  }

  try {
    const result = await askAI(messages, undefined, { geminiModels: CHAT_GEMINI_MODELS, timeoutMs: MODEL_TIMEOUT_MS, fast: true });
    if (!result) {
      console.error('zulu-ai-reply: every AI model failed', JSON.stringify(lastAIError));
      const f = fallback();
      if (f) return json({ reply: f, provider: 'kb' });
      return new Response(JSON.stringify({ reply: null, note: 'No AI provider configured or all failed -- set at least one of GEMINI_API_KEY, GROQ_API_KEY, MISTRAL_API_KEY, CEREBRAS_API_KEY, OPENROUTER_API_KEY in Edge Function secrets.' }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }
    const reply = safeReply(result.text).text;   // last safety check before the player sees it
    if (cacheKey) {
      if (answers.size > 200) answers.delete(answers.keys().next().value!);
      answers.set(cacheKey, { at: Date.now(), reply, provider: result.provider });
    }
    return json({ reply, provider: result.provider });
  } catch (e) {
    return new Response(JSON.stringify({ reply: null, note: e instanceof Error ? e.message : String(e) }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
});
