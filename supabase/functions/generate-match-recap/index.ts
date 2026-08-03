// Admin-only: generates a personality-driven match recap (English + Nepali) from a
// tournament's archived final standings, via a multi-provider AI fallback chain (see
// _shared/ai.ts) -- Groq first, then Gemini and others, so this isn't limited to
// Gemini's small free-tier quota. Admin-triggered only, never automatic on every score
// entry -- the admin panel shows the output before anyone sends it to players, same as
// the existing Send Announcement flow it feeds into.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { askAI, type AIMessage } from '../_shared/ai.ts';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET');
  if (!ADMIN_SECRET || req.headers.get('x-admin-secret') !== ADMIN_SECRET) {
    return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return new Response('Bad JSON', { status: 400, headers: CORS_HEADERS });
  }
  const tournament_slug = String(payload.tournament_slug || '').trim();
  if (!tournament_slug) return new Response('tournament_slug is required', { status: 400, headers: CORS_HEADERS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: results, error } = await supabase
    .from('tournament_results')
    .select('squad_name, placement, kills, points')
    .eq('tournament_slug', tournament_slug)
    .order('placement', { ascending: true });
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
  if (!results || !results.length) {
    return new Response('No archived results for this tournament yet -- archive results first.', { status: 400, headers: CORS_HEADERS });
  }

  const standingsText = results.map(r => `#${r.placement} ${r.squad_name} — ${r.kills} kills, ${r.points} pts`).join('\n');
  const prompt = `You are a hype/roast esports commentator for JD Esports Arena, a Free Fire Battle Royale tournament series in Nepal. Write a short, punchy match recap (3-5 sentences) for the final standings below -- playful roasting of the bottom squads, genuine hype for the top squads, keep it fun and never mean-spirited or personal. Then translate that exact same recap into Nepali (natural, not literal word-for-word).

Tournament: ${tournament_slug}
Final standings:
${standingsText}

Respond in exactly this format, nothing else:
ENGLISH:
<recap>
NEPALI:
<recap>`;

  const messages: AIMessage[] = [{ role: 'user', content: prompt }];
  const result = await askAI(messages);
  if (!result) {
    return new Response('No AI provider configured or all failed -- set at least GROQ_API_KEY or GEMINI_API_KEY in Edge Function secrets.', { status: 502, headers: CORS_HEADERS });
  }
  const text = result.text;

  const enMatch = text.match(/ENGLISH:\s*([\s\S]*?)(?:\n?NEPALI:|$)/i);
  const neMatch = text.match(/NEPALI:\s*([\s\S]*)/i);
  const english = (enMatch ? enMatch[1] : text).trim();
  const nepali = (neMatch ? neMatch[1] : '').trim();

  return new Response(JSON.stringify({ english, nepali, provider: result.provider }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
