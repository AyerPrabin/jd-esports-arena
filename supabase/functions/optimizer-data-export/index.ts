// Daily export of the anonymous JD-Optimiers FPS stats (optimizer_sessions, see optimizer_sessions.sql) for the
// private research repo AyerPrabin/jd-optimizer-data. Its GitHub Action calls this once a day with the shared
// secret (x-export-secret == OPTIMIZER_EXPORT_SECRET) and ?since=<last id it has>, and commits the CSV rows.
// No secret, no data. Rows hold no account or name - only a random per-PC ID, FPS numbers, settings and the
// PC model.
import { createClient } from 'npm:@supabase/supabase-js@2';

const COLS = ['v', 'min', 'fps', 'low1', 'stutter_min', 'cpu', 'gpu', 'temp', 'ping', 'renderer', 'cap', 'cpus', 'emu_ram',
  'turn_fps', 'turn_low', 'still_fps', 'hw_cpu', 'hw_gpu', 'ram_gb', 'cores', 'threads', 'hz', 'laptop', 'mode',
  'battery_pct', 'gpu_power_limit_s', 'gpu_heat_limit_s'];

const cell = (x: unknown) => {
  const s = x === null || x === undefined ? '' : String(x);
  return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
};

Deno.serve(async (req: Request) => {
  const secret = Deno.env.get('OPTIMIZER_EXPORT_SECRET');
  if (!secret || req.headers.get('x-export-secret') !== secret) return new Response('Forbidden', { status: 403 });
  const since = Number(new URL(req.url).searchParams.get('since') || '0') || 0;
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data, error } = await sb.from('optimizer_sessions').select('id, anon_id, created_at, data')
    .gt('id', since).order('id', { ascending: true }).limit(5000);
  if (error) return new Response('Error: ' + error.message, { status: 500 });
  const head = ['id', 'created_at', 'anon_id', ...COLS].join(',');
  const rows = (data || []).map((r: any) => [r.id, r.created_at, r.anon_id, ...COLS.map((c) => r.data?.[c])].map(cell).join(','));
  return new Response(head + '\n' + rows.join('\n') + (rows.length ? '\n' : ''), {
    status: 200,
    headers: { 'Content-Type': 'text/csv; charset=utf-8' },
  });
});
