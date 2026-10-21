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
import { askAI, type AIMessage } from '../_shared/ai.ts';
import { zuluSystemPrompt } from '../_shared/zulu.ts';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const BURST_CAP = Number(Deno.env.get('ZULU_AI_REPLY_BURST_CAP') || '5');       // per IP
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
const json = (body: unknown) => new Response(JSON.stringify(body), { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });

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

  const cacheKey = !history.length && !account ? answerKey(lang, message) : '';
  const hit = cacheKey ? answers.get(cacheKey) : undefined;
  if (hit && Date.now() - hit.at < ANSWER_TTL_MS) return json({ reply: hit.reply, provider: hit.provider + ':cached' });
  // Built while the rate-limit checks run, not after them.
  const promptP = zuluSystemPrompt(lang);

  const ip = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim() || 'unknown';
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

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

  const systemPrompt = await promptP;

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

  try {
    const result = await askAI(messages, undefined, { geminiModels: CHAT_GEMINI_MODELS, timeoutMs: MODEL_TIMEOUT_MS });
    if (!result) {
      return new Response(JSON.stringify({ reply: null, note: 'No AI provider configured or all failed -- set at least one of GEMINI_API_KEY, GROQ_API_KEY, MISTRAL_API_KEY, CEREBRAS_API_KEY, OPENROUTER_API_KEY in Edge Function secrets.' }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }
    if (cacheKey) {
      if (answers.size > 200) answers.delete(answers.keys().next().value!);
      answers.set(cacheKey, { at: Date.now(), reply: result.text, provider: result.provider });
    }
    return json({ reply: result.text, provider: result.provider });
  } catch (e) {
    return new Response(JSON.stringify({ reply: null, note: e instanceof Error ? e.message : String(e) }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
});
