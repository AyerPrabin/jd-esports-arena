// Admin-only: points wallet management (see the wallet section of schema.sql).
//   { action: 'lookup', q }                                  -> player (tag / username / email) + balance
//   { action: 'credit', player_id, amount, ref, note? }      -> add verified eSewa payment as points
//   { action: 'withdrawals' }                                 -> pending withdrawal requests
//   { action: 'resolve', id, paid: bool, payout_ref? }        -> mark paid, or reject (points returned)
// Balances only change inside admin_wallet_credit / admin_resolve_withdrawal (service role).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush } from '../_shared/push.ts';

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

  if (p.action === 'search') {
    const q = String(p.q || '').trim().replace(/^@/, '');
    if (q.length < 2) return json([]);
    // strip characters that mean something in a like pattern or PostgREST's or() syntax
    const like = '%' + q.replace(/[%_*,()\\"]/g, '') + '%';
    const { data, error } = await supabase.from('players')
      .select('id, username, player_tag, email, wallets(balance, unlimited)')
      .or(`username.ilike.${like},player_tag.ilike.${like},email.ilike.${like}`)
      .limit(40);
    if (error) return fail(error.message, 500);
    // best matches first: exact username, username starts with, username contains, tag, email
    const ql = q.toLowerCase();
    const score = (x: any) => {
      const u = String(x.username || '').toLowerCase(), t = String(x.player_tag || '').toLowerCase();
      return u === ql || t === ql ? 0 : u.startsWith(ql) ? 1 : u.includes(ql) ? 2 : t.includes(ql) ? 3 : 4;
    };
    return json((data || []).sort((a: any, b: any) => score(a) - score(b)).slice(0, 8).map((x: any) => {
      const w = Array.isArray(x.wallets) ? x.wallets[0] : x.wallets;
      return { id: x.id, username: x.username, player_tag: x.player_tag, email: x.email, balance: w?.balance ?? 0, unlimited: !!w?.unlimited };
    }));
  }

  if (p.action === 'lookup') {
    if (p.player_id) {
      const { data: one } = await supabase.from('players').select('id, username, player_tag, email').eq('id', p.player_id).maybeSingle();
      if (!one) return fail('Player not found', 404);
      const { data: w1 } = await supabase.from('wallets').select('balance, unlimited').eq('player_id', one.id).maybeSingle();
      const { data: l1 } = await supabase.from('wallet_ledger').select('delta, balance_after, reason, ref, note, created_at')
        .eq('player_id', one.id).order('created_at', { ascending: false }).limit(10);
      return json({ player: one, balance: w1?.balance ?? 0, unlimited: !!w1?.unlimited, ledger: l1 || [] });
    }
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

  if (p.action === 'security') {
    const [{ data: state }, { data: sweep }] = await Promise.all([
      supabase.from('system_state').select('*').eq('id', 1).maybeSingle(),
      supabase.rpc('security_sweep', { p_apply: false }),
    ]);
    return json({ state, sweep });
  }

  if (p.action === 'lock' || p.action === 'unlock') {
    const { data, error } = await supabase.rpc('admin_set_lock', { p_locked: p.action === 'lock', p_reason: p.reason || null });
    if (error) return fail(error.message);
    return json(data);
  }

  if (p.action === 'test_push') {
    const { count } = await supabase.from('push_subscriptions').select('endpoint', { count: 'exact', head: true }).eq('player_id', p.player_id);
    const sent = await sendPush(supabase, [p.player_id], { title: '🔔 JD Arena test', body: 'Push works! You will get alerts like this even when the site is closed. ⚔️', url: 'https://jdesport.co.uk/', tag: 'jd-test' });
    return json({ devices: count ?? 0, sent });
  }

  if (p.action === 'challenges') {
    const cols = 'id, mode, stake, status, note, room_id, creator_claim, opponent_claim, claim_at, resolution, created_at, accepted_at, resolved_at, creator:players!challenges_creator_fkey(username, player_tag), opponent:players!challenges_opponent_fkey(username, player_tag)';
    const [{ data: disputed, error: e1 }, { data: recent, error: e2 }] = await Promise.all([
      supabase.from('challenges').select(cols).eq('status', 'disputed').order('created_at', { ascending: true }),
      supabase.from('challenges').select(cols).neq('status', 'disputed').order('created_at', { ascending: false }).limit(30),
    ]);
    if (e1 || e2) return fail((e1 || e2)!.message, 500);
    const ids = (disputed || []).map((c: any) => c.id);
    let chats: Record<string, any[]> = {};
    if (ids.length) {
      const { data: msgs } = await supabase.from('challenge_messages')
        .select('challenge_id, body, created_at, sender:players(username, player_tag)').in('challenge_id', ids).order('id');
      for (const m of msgs || []) (chats[m.challenge_id] ||= []).push(m);
    }
    return json({ disputed: (disputed || []).map((c: any) => ({ ...c, chat: chats[c.id] || [] })), recent: recent || [] });
  }

  if (p.action === 'resolve_challenge') {
    const { error } = await supabase.rpc('admin_resolve_challenge', { p_id: p.id, p_outcome: p.outcome });
    if (error) return fail(error.message);
    return json({ ok: true });
  }

  if (p.action === 'balances') {
    const { data, error } = await supabase.from('players')
      .select('id, username, player_tag, email, wallets(balance, unlimited, updated_at)');
    if (error) return fail(error.message, 500);
    const rows = (data || []).map((x: any) => {
      const w = Array.isArray(x.wallets) ? x.wallets[0] : x.wallets;
      return { id: x.id, username: x.username, player_tag: x.player_tag, email: x.email,
        balance: w?.balance ?? 0, unlimited: !!w?.unlimited, updated_at: w?.updated_at ?? null };
    }).sort((a: any, b: any) => (b.unlimited ? 1 : 0) - (a.unlimited ? 1 : 0) || b.balance - a.balance);
    const { data: pend } = await supabase.from('withdraw_requests').select('amount').eq('status', 'pending');
    return json({ rows, pending_withdrawals: (pend || []).reduce((s: number, r: any) => s + r.amount, 0) });
  }

  if (p.action === 'award') {
    const { data, error } = await supabase.rpc('award_prizes', { p_slug: p.tournament_slug || null });
    if (error) return fail(error.message);
    return json(data || []);
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
