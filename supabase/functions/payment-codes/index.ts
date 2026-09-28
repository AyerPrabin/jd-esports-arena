// Admin-only: generate and list payment codes (see payment_codes in schema.sql).
//   { action: 'create', kind, tournament_slug?, count?, note? } -> { codes: [...] }
//   { action: 'list', limit? }                                   -> recent codes + who redeemed them
// The player pays over WhatsApp, the organiser generates a code here and sends it back,
// and the player redeems it on the site with redeem_code(). Entry codes are bound to one
// tournament at creation, so a cheap entry's code can't be used on an expensive one.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const PRICES: Record<string, number | null> = { entry: null, fx_game: 2, fx_lite_week: 5, fx_week: 10, fx_month: 30 };
// no 0/O/1/I/L so codes read cleanly when typed from a WhatsApp message
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

function newCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  const chars = [...bytes].map((b) => ALPHABET[b % ALPHABET.length]).join('');
  return `JD-${chars.slice(0, 5)}-${chars.slice(5)}`;
}
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
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
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  if (payload.action === 'create') {
    const kind = String(payload.kind || '');
    if (!(kind in PRICES)) return new Response('Unknown code type', { status: 400, headers: CORS_HEADERS });
    const slug = payload.tournament_slug ? String(payload.tournament_slug) : null;
    if (kind === 'entry' && !slug) return new Response('Pick the tournament for an entry code', { status: 400, headers: CORS_HEADERS });
    const count = Math.min(Math.max(parseInt(payload.count) || 1, 1), 20);
    const rows = Array.from({ length: count }, () => ({
      code: newCode(),
      kind,
      tournament_slug: kind === 'entry' ? slug : null,
      amount_npr: PRICES[kind],
      note: payload.note ? String(payload.note).slice(0, 120) : null,
    }));
    const { error } = await supabase.from('payment_codes').insert(rows);
    if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
    return json({ codes: rows });
  }

  if (payload.action === 'list') {
    const limit = Math.min(Math.max(parseInt(payload.limit) || 40, 1), 200);
    const { data, error } = await supabase
      .from('payment_codes')
      .select('code, kind, tournament_slug, amount_npr, note, created_at, redeemed_at, players(username, player_tag)')
      .order('created_at', { ascending: false })
      .limit(limit);
    if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });
    return json(data || []);
  }

  return new Response('Unknown action', { status: 400, headers: CORS_HEADERS });
});
