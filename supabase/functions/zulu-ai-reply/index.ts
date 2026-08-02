// Public (no admin gate — every visitor's browser calls this, not just admin).
// ZULU's last resort: called from zuluRespond() in index.html ONLY when the local
// pattern-matched systems (zuluPersonalMatch/zuluPublic) have nothing, instead of the
// old dead-end "I don't have that one yet" message. Calls Google Gemini with a system
// prompt scoping it to JD Esports Arena topics.
//
// Rate-limited via zulu_ai_reply_log (schema.sql): a per-IP burst cap (stop one client
// hammering it) and a global daily cap (stop the shared free Gemini quota -- also used by
// generate-match-recap and zulu_server.py's own council calls -- being exhausted by public
// chat traffic alone). Both limits fail OPEN on a logging/count error (a Supabase hiccup
// shouldn't take chat down) but fail CLOSED once a real cap is hit. Over a cap returns
// {reply: null} with HTTP 200, same shape as "no Gemini key set"/"Gemini error" below --
// index.html's zuluAsk() already treats a null reply as "fall back to the local canned
// answer", so a maxed-out quota degrades gracefully instead of erroring visibly.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const BURST_CAP = Number(Deno.env.get('ZULU_AI_REPLY_BURST_CAP') || '5');       // per IP
const BURST_WINDOW_SEC = Number(Deno.env.get('ZULU_AI_REPLY_BURST_WINDOW_SEC') || '60');
const DAILY_CAP = Number(Deno.env.get('ZULU_AI_REPLY_DAILY_CAP') || '15');      // global, all IPs
// ^ 15, not Gemini's full ~20/day, deliberately leaves headroom for generate-match-recap
// and zulu_server.py's admin-review council calls sharing the same key/quota.

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

    // Logged as an attempt (before calling Gemini, not after) so the cap bounds total
    // Gemini calls regardless of whether this particular one succeeds.
    await supabase.from('zulu_ai_reply_log').insert({ ip });
  } catch {
    // Best-effort rate limiting: a Supabase hiccup here shouldn't take public chat down,
    // it just means this one request isn't counted/capped.
  }

  const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY');
  if (!GEMINI_API_KEY) {
    return new Response(JSON.stringify({ reply: null, note: 'GEMINI_API_KEY not set' }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
  const GEMINI_MODEL = Deno.env.get('GEMINI_MODEL') || 'gemini-2.5-flash';

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
      const list = (d.tournaments || []).filter((t: any) => !['completed', 'cancelled'].includes((t.status || '').toLowerCase()));
      if (list.length) {
        scheduleContext = '\n\nCurrent tournaments (use this to answer schedule/prize/entry/slots/format questions accurately — do not contradict it):\n' +
          list.slice(0, 8).map((t: any) =>
            `- ${t.name || 'Tournament'}: status=${t.status || 'upcoming'}, date=${t.date || 'TBA'}, time=${t.time || 'TBA'}, prize=${t.prize || '—'}, entry=${t.entry || 'Free'}, slots=${t.slots ?? '—'}, format=${t.format || 'BR'}`
          ).join('\n');
      }
    }
  } catch {
    // tournaments.json fetch failing shouldn't block the reply — just answer without schedule grounding
  }

  const systemPrompt = `You are ZULU, the friendly assistant for JD Esports Arena — a Free Fire Battle Royale tournament platform in Nepal run solo by Prabin Ayer (AyerFire). Answer briefly (2-4 sentences), in a warm, casual tone.
Rules:
- Only discuss JD Arena, Free Fire tournaments, how to join/register, rules, fair play, and general esports/gaming chat. If asked about Prabin's private business plans, revenue, or anything unrelated, politely decline and steer back to tournaments.
- Use the current tournaments list below (if provided) to answer schedule/prize/entry/slots/format questions with real numbers — don't say "check the site" for something already listed here.
- You still do NOT have access to per-player account data (room IDs, a specific player's points, their registration status). NEVER invent those. If asked something that needs THAT kind of live account-specific data, tell them to check their account panel / Notification History on the site instead of guessing.
- Reply in ${lang === 'ne' ? 'Nepali' : 'English'}.${scheduleContext}`;

  try {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: systemPrompt }] },
          contents: [{ parts: [{ text: message }] }],
        }),
      },
    );
    if (!res.ok) {
      return new Response(JSON.stringify({ reply: null, note: 'Gemini error: ' + (await res.text()) }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }
    const data = await res.json();
    const reply = data?.candidates?.[0]?.content?.parts?.[0]?.text || null;
    return new Response(JSON.stringify({ reply }), {
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
