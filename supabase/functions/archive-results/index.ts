// Admin-only: permanently archives one tournament's final Best-of-3 standings into
// public.tournament_results, so player career stats (get_player_career_stats()) and
// rank tiers survive past the point where the admin panel moves the bo3 board on to
// the next bracket. Called from the "📦 Archive results" button in the BO3 section of
// admin/index.html once results are final for a tournament.
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface ResultRow {
  squad_name: string;
  placement: number;
  kills: number;
  points: number;
  prize_won?: number;
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET');
  if (!ADMIN_SECRET || req.headers.get('x-admin-secret') !== ADMIN_SECRET) {
    return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  }

  let body: { tournament_slug?: string; results?: ResultRow[] };
  try {
    body = await req.json();
  } catch {
    return new Response('Invalid JSON body', { status: 400, headers: CORS_HEADERS });
  }
  const tournament_slug = (body.tournament_slug || '').trim();
  const results = Array.isArray(body.results) ? body.results : [];
  if (!tournament_slug) return new Response('tournament_slug is required', { status: 400, headers: CORS_HEADERS });
  if (!results.length) return new Response('results must be a non-empty array', { status: 400, headers: CORS_HEADERS });

  const rows = results
    .map(r => ({
      tournament_slug,
      squad_name: String(r.squad_name || '').trim(),
      placement: Number(r.placement) || 0,
      kills: Number(r.kills) || 0,
      points: Number(r.points) || 0,
      prize_won: Number(r.prize_won) || 0,
    }))
    .filter(r => r.squad_name && r.placement > 0);
  if (!rows.length) return new Response('No valid rows (each needs a squad_name and placement)', { status: 400, headers: CORS_HEADERS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { error } = await supabase
    .from('tournament_results')
    .upsert(rows, { onConflict: 'tournament_slug,squad_name' });
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });

  // Anomaly detection: never blocks the archive, never bans anyone -- just flags a
  // squad whose kills spike well past their own history for admin review. Needs at
  // least 2 prior appearances under the same squad_name to judge "normal" for them;
  // a brand-new squad's first big game is not itself suspicious.
  let flagged = 0;
  try {
    for (const row of rows) {
      const { data: history, error: histErr } = await supabase
        .from('tournament_results')
        .select('kills')
        .eq('squad_name', row.squad_name)
        .neq('tournament_slug', tournament_slug);
      if (histErr || !history || history.length < 2) continue;
      const avg = history.reduce((s, h) => s + (h.kills || 0), 0) / history.length;
      const ratio = avg > 0 ? row.kills / avg : (row.kills >= 8 ? 999 : 0);
      if (row.kills >= Math.max(8, avg * 2.5)) {
        const { error: flagErr } = await supabase.from('performance_flags').insert({
          tournament_slug,
          squad_name: row.squad_name,
          kills: row.kills,
          historical_avg_kills: Math.round(avg * 10) / 10,
          prior_appearances: history.length,
          ratio: Math.round(ratio * 10) / 10,
        });
        if (!flagErr) flagged++;
      }
    }
  } catch {
    // anomaly detection failing shouldn't block the archive that already succeeded above
  }

  return new Response(JSON.stringify({ archived: rows.length, flagged }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
