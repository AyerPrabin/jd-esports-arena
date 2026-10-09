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

  const ip = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim() || 'unknown';
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  try {
    const sinceBurst = new Date(Date.now() - BURST_WINDOW_SEC * 1000).toISOString();
    const { count: burstCount, error: burstErr } = await supabase
      .from('zulu_ai_reply_log')
      .select('id', { count: 'exact', head: true })
      .eq('ip', ip)
      .gte('created_at', sinceBurst);
    if (!burstErr && (burstCount ?? 0) >= BURST_CAP) {
      return new Response(JSON.stringify({ reply: null, note: 'Rate limited -- slow down a moment.' }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const sinceDay = new Date(); sinceDay.setUTCHours(0, 0, 0, 0);
    const { count: dailyCount, error: dailyErr } = await supabase
      .from('zulu_ai_reply_log')
      .select('id', { count: 'exact', head: true })
      .gte('created_at', sinceDay.toISOString());
    if (!dailyErr && (dailyCount ?? 0) >= DAILY_CAP) {
      return new Response(JSON.stringify({ reply: null, note: 'Daily AI quota reached -- try again tomorrow.' }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    // Logged as an attempt (before calling the AI, not after) so the cap bounds total
    // calls regardless of whether this particular one succeeds.
    await supabase.from('zulu_ai_reply_log').insert({ ip });
  } catch {
    // Best-effort rate limiting: a Supabase hiccup here shouldn't take public chat down,
    // it just means this one request isn't counted/capped.
  }

  // Grounds the fallback in the real, current schedule instead of making it guess or
  // deflect every scheduling/prize/entry question — tournaments.json is the same public
  // file the site itself renders from (see TOURNAMENTS_URL in tournament-reminders),
  // so this is data the visitor could already see on the page, not anything private.
  // Best-effort: if the fetch fails, ZULU just answers without it (same as before).
  let scheduleContext = '';
  try {
    const r = await fetch('https://jdesport.co.uk/tournaments.json', { cache: 'no-store' });
    if (r.ok) {
      const d = await r.json();
      // Same rule as index.html's effectiveStatus(): a declared winner means it's over even
      // if the admin left status "upcoming", and a passed start time means it's live/started.
      const eff = (t: any) => {
        const s = (t.status || 'upcoming').toLowerCase();
        if (s !== 'cancelled' && String(t.winner || '').trim()) return 'completed';
        const ms = Date.parse(t.start);
        if (s === 'upcoming' && Number.isFinite(ms) && Date.now() >= ms) return Date.now() - ms > 12 * 3600e3 ? 'completed' : 'live';
        return s;
      };
      const startMs = (t: any) => Date.parse(t.start) || Number.MAX_SAFE_INTEGER; // TBA dates last
      const list = (d.tournaments || [])
        .map((t: any) => ({ ...t, status: eff(t) }))
        .filter((t: any) => !['completed', 'cancelled'].includes(t.status))
        .sort((a: any, b: any) => startMs(a) - startMs(b));
      if (list.length) {
        scheduleContext = '\n\nNow: ' + new Date().toLocaleString('en-GB', { timeZone: 'Asia/Kathmandu', dateStyle: 'full', timeStyle: 'short' }) + ' Nepal time.' +
          '\nLive and upcoming tournaments, soonest first (use this to answer schedule/prize/entry/slots/format questions accurately — do not contradict it):\n' +
          list.slice(0, 8).map((t: any) =>
            `- ${t.name || 'Tournament'}: status=${t.status || 'upcoming'}, date=${t.date || 'TBA'}, time=${t.time || 'TBA'}, prize=${t.prize || '—'}, entry=${t.entry || 'Free'}, slots=${t.slots ?? '—'}, format=${t.format || 'BR'}`
          ).join('\n');
      }
      // Latest results, so "who won last time?" gets a real answer.
      const done = (d.tournaments || []).filter((t: any) => eff(t) === 'completed').sort((a: any, b: any) => (Date.parse(b.start) || 0) - (Date.parse(a.start) || 0)).slice(0, 3);
      if (done.length) scheduleContext += '\nRecently completed: ' + done.map((t: any) => `${t.name} (${t.date || 'date n/a'})`).join('; ');
      const b = d.bo3;
      if (b && b.published && Array.isArray(b.teams) && b.teams.length) {
        const rows = b.teams
          // same totals as index.html's bo3Standings(): sum of each round's pts
          .map((t: any) => ({ name: t.team, total: (Array.isArray(t.r) ? t.r : []).reduce((a: number, x: any) => a + (+x?.pts || 0), 0) }))
          .filter((x: any) => x.name && x.total > 0)
          .sort((a: any, z: any) => z.total - a.total)
          .slice(0, 3);
        if (rows.length) scheduleContext += `\nLatest published standings (${b.title || b.tournament || 'last event'}): ` + rows.map((x: any, i: number) => `${i + 1}. ${x.name} ${x.total} pts`).join(', ');
      }
    }
  } catch {
    // tournaments.json fetch failing shouldn't block the reply — just answer without schedule grounding
  }

  const systemPrompt = `You are ZULU, the friendly assistant for JD Esports Arena — a Free Fire Battle Royale tournament platform in Nepal run solo by Prabin Ayer (AyerFire). Answer briefly (2-4 sentences), in a warm, casual tone. Give the exact steps when someone asks how to do something, and never invent prices, dates or rules that aren't listed here or in the tournaments list.
Rules:
- Only discuss JD Arena, Free Fire tournaments, how to join/register, rules, fair play, and general esports/gaming chat. If asked about Prabin's private business plans, revenue, or anything unrelated, politely decline and steer back to tournaments.
- Facts about how JD Arena works (never contradict these):
  * Prizes are fixed and posted before registration; winners get the full prize paid automatically into their points wallet. Entry fees are kept by JD Arena to fund prizes and running costs — never say the host takes 0% or that every rupee goes back to players.
  * Points: 1 JD point = Rs 1. Load them from the wallet page (tap the coin at the top): scan the eSewa QR, put your username in the payment remarks, send the screenshot on WhatsApp +44 7343 082738 (jd.lmt.np); points are added after verification. Withdraw points to your own eSewa from the wallet page any time (sent by hand, usually within a day).
  * Joining: sign up, tap Join, enter a squad name (required, saved for next time along with the logo). Free tournaments confirm instantly; paid ones are paid with points from the ticket. Check in during the 30 minutes before the start; the Room ID and password appear on the ticket.
  * Refunds when withdrawing from a paid tournament: 24h+ before start = full, last 24 hours = 10%, none once room details are out. Points refunds go straight back to the wallet.
  * Squad effects are cosmetic: Rs 2 one match, Rs 5 lite week, Rs 10 pro week, Rs 30 pro month; bought with points from the ticket; not refundable.
  * Challenges (jdesport.co.uk/challenges/): 1v1, 2v2, 3v3 or 4v4 Clash Squad for JD points, needs an account. Both sides put in the same stake, held until the result; the winner gets both stakes minus a 1-point platform fee per player (e.g. 50 each -> winner gets 98). 2v2-4v4 are captain vs captain. The creator picks the room settings: character skills on/off, gun attributes on/off, ammo and gloo walls (limited or unlimited) and number of rounds (presets: "Ranked style" = skills on, guns off; "Pure aim" = no skills, no gun stats). If the room doesn't match the settings, say so in the challenge chat before the first round; playing on means you accept it. Cancel any time before someone accepts for a full refund. Unaccepted within 24 hours, or nobody reports within 12 hours of accepting = stakes refunded, no fee. If both sides claim the win, the admin decides from screenshots shared in the challenge chat.
  * Scoring in Battle Royale tournaments: each round = kill points + placement points. 1 point per kill, no cap. Placement: 1st 12, 2nd 9, 3rd 6, 4th 5, 5th 4, 6th 3, 7th 2, 8th 1. Round totals add up across the matches; the season leaderboard is at jdesport.co.uk/leaderboard.html.
  * Tournament room settings are the same every match: gun attributes OFF (weapon skin stat bonuses don't apply), character skills ON, full map with the normal zone.
  * Fair play: cheating (hacks, mod menus, aimbots) gets a ban, listed on the site's Ban List page. Report a cheater from the site with evidence; an admin reviews every report.
  * The profile page (tap your name) shows rank, stats, points, tournaments and saved squad. Discord: https://discord.gg/dgvQTbNvVu
- Use the current tournaments list below (if provided) to answer schedule/prize/entry/slots/format questions with real numbers — don't say "check the site" for something already listed here.
- You still do NOT have access to per-player account data (room IDs, a specific player's points, their registration status). NEVER invent those. If asked something that needs THAT kind of live account-specific data, tell them to check their account panel / Notification History on the site instead of guessing.
- Language: reply in the same language and script the player used in their last message (English, Nepali in Devanagari only (never Hindi, Gujarati or other scripts), or Romanized Nepali like "kasari join garne"). If unclear, use ${lang === 'ne' ? 'Nepali (Devanagari)' : 'English'}.
- Keep it short and useful: plain sentences, no markdown headings, tables or bold, at most a short numbered list for steps. Use the earlier turns of this chat to understand follow-up questions.
- If you are not sure of a fact, say so and point them to the Discord rather than guessing.${scheduleContext}`;

  const messages: AIMessage[] = [
    { role: 'system', content: systemPrompt },
    ...history,
    { role: 'user', content: message },
  ];

  try {
    const result = await askAI(messages, undefined, { geminiModels: CHAT_GEMINI_MODELS });
    if (!result) {
      return new Response(JSON.stringify({ reply: null, note: 'No AI provider configured or all failed -- set at least one of GEMINI_API_KEY, GROQ_API_KEY, MISTRAL_API_KEY, CEREBRAS_API_KEY, OPENROUTER_API_KEY in Edge Function secrets.' }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }
    return new Response(JSON.stringify({ reply: result.text, provider: result.provider }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(JSON.stringify({ reply: null, note: e instanceof Error ? e.message : String(e) }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
});
