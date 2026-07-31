// Admin-only: marks an anomaly flag reviewed, with an optional note (e.g. "checked
// replay, clean" or "banned via report #..."). Doesn't itself ban anyone -- that's a
// separate, deliberate step via action-report/banDirectly in the admin panel.
import { createClient } from 'npm:@supabase/supabase-js@2';

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
  const flag_id = String(payload.flag_id || '').trim();
  const admin_note = payload.admin_note ? String(payload.admin_note).trim() : null;
  if (!flag_id) return new Response('flag_id is required', { status: 400, headers: CORS_HEADERS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { error } = await supabase.from('performance_flags').update({ reviewed: true, admin_note }).eq('id', flag_id);
  if (error) return new Response(error.message, { status: 500, headers: CORS_HEADERS });

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
