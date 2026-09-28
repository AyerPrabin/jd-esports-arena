// Admin-only: points wallet management (see the wallet section of schema.sql).
//   { action: 'lookup', q }                                  -> player (tag / username / email) + balance
//   { action: 'credit', player_id, amount, ref, note? }      -> add verified eSewa payment as points
//   { action: 'withdrawals' }                                 -> pending withdrawal requests
//   { action: 'resolve', id, paid: bool, payout_ref? }        -> mark paid, or reject (points returned)
// Balances only change inside admin_wallet_credit / admin_resolve_withdrawal (service role).
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

  if (p.action === 'lookup') {
    const q = String(p.q || '').trim().replace(/^@/, '');
    if (!q) return fail('Type a player tag, username or email');
    const cols = 'id, username, player_tag, email';
    const exact = q.replace(/[%_\\]/g, (m) => '\\' + m); // ilike without wildcards
    const [a, b, c] = await Promise.all([
      supabase.from('players').select(cols).eq('player_tag', q.toUpperCase()),
      supabase.from('players').select(cols).ilike('username', exact),
      supabase.from('players').select(cols).ilike('email', exact),
    ]);
    const found = [...(a.data || []), ...(b.data || []), ...(c.data || [])];
    const player = found[0];
    if (!player) return fail('No player found with that tag, username or email', 404);
    const { data: w } = await supabase.from('wallets').select('balance').eq('player_id', player.id).maybeSingle();
    const { data: ledger } = await supabase.from('wallet_ledger')
      .select('delta, balance_after, reason, ref, note, created_at').eq('player_id', player.id)
      .order('created_at', { ascending: false }).limit(10);
    return json({ player, balance: w?.balance ?? 0, ledger: ledger || [] });
  }

  if (p.action === 'credit') {
    const { data, error } = await supabase.rpc('admin_wallet_credit', {
      p_player: p.player_id, p_amount: parseInt(p.amount), p_ref: p.ref, p_note: p.note || null,
    });
    if (error) return fail(error.message);
    return json({ balance: data });
  }

  if (p.action === 'withdrawals') {
    const { data, error } = await supabase.from('withdraw_requests')
      .select('id, amount, esewa_id, esewa_name, status, created_at, players(username, player_tag)')
      .eq('status', 'pending').order('created_at', { ascending: true });
    if (error) return fail(error.message, 500);
    return json(data || []);
  }

  if (p.action === 'resolve') {
    const { data, error } = await supabase.rpc('admin_resolve_withdrawal', {
      p_id: p.id, p_paid: !!p.paid, p_payout_ref: p.payout_ref || null,
    });
    if (error) return fail(error.message);
    return json(data);
  }

  return fail('Unknown action');
});
