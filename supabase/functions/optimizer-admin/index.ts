// Admin-only: JD-Optimiers plans (Optimizer Pro / Max) and linked PCs (see supabase/optimizer.sql).
//   { action: 'list' }                                   -> every plan (active first) with username + PC count
//   { action: 'search', q }                              -> players by username / tag / email + their plan
//   { action: 'grant', player_id, tier, days, note?, effect? } -> add days of pro|max (free); max + effect also gives a 30-day Pro squad effect
//   { action: 'end', player_id }                         -> end the plan now
//   { action: 'devices', player_id }                     -> linked PCs
//   { action: 'revoke_device', id }                      -> unlink a PC (the app asks to sign in again)
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });
}
function fail(msg: string, status = 400) {
  return new Response(msg, { status, headers: CORS_HEADERS });
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') return fail('Method not allowed', 405);
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET');
  if (!ADMIN_SECRET || req.headers.get('x-admin-secret') !== ADMIN_SECRET) return fail('Unauthorized', 401);
  let p: any;
  try {
    p = await req.json();
  } catch {
    return fail('Bad JSON');
  }
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  if (p.action === 'list') {
    const { data: plans, error } = await supabase.from('optimizer_plans')
      .select('player_id, tier, expires_at, updated_at, note, players(username, player_tag, email)')
      .order('expires_at', { ascending: false }).limit(500);
    if (error) return fail(error.message, 500);
    const { data: devs } = await supabase.from('optimizer_devices').select('player_id').is('revoked_at', null);
    const pcs: Record<string, number> = {};
    for (const d of devs || []) pcs[d.player_id] = (pcs[d.player_id] || 0) + 1;
    const now = Date.now();
    return json((plans || []).map((r: any) => ({
      player_id: r.player_id, tier: r.tier, expires_at: r.expires_at, updated_at: r.updated_at, note: r.note,
      active: new Date(r.expires_at).getTime() > now, pcs: pcs[r.player_id] || 0,
      username: r.players?.username, player_tag: r.players?.player_tag, email: r.players?.email,
    })));
  }

  if (p.action === 'search') {
    const q = String(p.q || '').trim().replace(/^@/, '');
    if (q.length < 2) return json([]);
    const like = '%' + q.replace(/[%_*,()\\"]/g, '') + '%';
    const { data, error } = await supabase.from('players')
      .select('id, username, player_tag, email, optimizer_plans(tier, expires_at)')
      .or(`username.ilike.${like},player_tag.ilike.${like},email.ilike.${like}`)
      .limit(10);
    if (error) return fail(error.message, 500);
    return json((data || []).map((x: any) => {
      const pl = Array.isArray(x.optimizer_plans) ? x.optimizer_plans[0] : x.optimizer_plans;
      return { id: x.id, username: x.username, player_tag: x.player_tag, email: x.email,
               tier: pl?.tier ?? null, expires_at: pl?.expires_at ?? null };
    }));
  }

  if (p.action === 'grant') {
    const days = Number(p.days);
    if (!p.player_id || !['pro', 'max'].includes(p.tier) || !Number.isInteger(days) || days < 1 || days > 3660)
      return fail('Pick a player, Pro or Max, and 1-3660 days');
    const { data, error } = await supabase.rpc('_optimizer_grant', {
      p_player: p.player_id, p_tier: p.tier, p_days: days, p_note: String(p.note || 'admin grant').slice(0, 200),
    });
    if (error) return fail(error.message);
    if (p.tier === 'max' && p.effect) {
      const fx = await supabase.rpc('_optimizer_max_effect', { p_player: p.player_id, p_effect: String(p.effect), p_ref: 'admin-grant' });
      if (fx.error) return json({ ...data, effect_error: fx.error.message });
      return json({ ...data, effect: fx.data?.effect, effect_expires_at: fx.data?.expires_at });
    }
    return json(data);
  }

  if (p.action === 'end') {
    if (!p.player_id) return fail('player_id required');
    const { error } = await supabase.from('optimizer_plans')
      .update({ expires_at: new Date().toISOString(), updated_at: new Date().toISOString(), note: 'ended by admin' })
      .eq('player_id', p.player_id);
    if (error) return fail(error.message, 500);
    return json({ ok: true });
  }

  if (p.action === 'devices') {
    if (!p.player_id) return fail('player_id required');
    const { data, error } = await supabase.from('optimizer_devices')
      .select('id, device_name, created_at, last_seen, revoked_at')
      .eq('player_id', p.player_id).order('created_at', { ascending: false }).limit(20);
    if (error) return fail(error.message, 500);
    return json(data || []);
  }

  if (p.action === 'revoke_device') {
    if (!p.id) return fail('id required');
    const { error } = await supabase.from('optimizer_devices').update({ revoked_at: new Date().toISOString() })
      .eq('id', p.id).is('revoked_at', null);
    if (error) return fail(error.message, 500);
    return json({ ok: true });
  }

  return fail('Unknown action');
});
