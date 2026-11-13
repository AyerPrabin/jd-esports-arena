// Admin-only: points wallet management (see the wallet section of schema.sql).
//   { action: 'lookup', q }                                  -> player (tag / username / email) + balance
//   { action: 'credit', player_id, amount, ref, note? }      -> add verified eSewa payment as points
//   { action: 'reset_pin', player_id }                       -> clear a forgotten wallet PIN (wallet_pin.sql)
//   { action: 'history', player_id }                        -> every point added or taken, newest first, with totals
//   { action: 'refundables', player_id }                    -> recent charges + how much is left to refund
//   { action: 'refund', player_id, ledger_id?, amount?, reason? } -> refund a charge (or a custom amount)
//   { action: 'withdrawals' }                                 -> pending withdrawal requests
//   { action: 'resolve', id, paid: bool, payout_ref? }        -> mark paid, or reject (points returned)
//   { action: 'loads' }                                       -> pending eSewa screenshots from /wallet/
//   { action: 'resolve_load', id, approve: bool, amount?, note? } -> credit the points, or reject
// Balances only change inside admin_wallet_credit / admin_resolve_withdrawal (service role).
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush, lastPushError } from '../_shared/push.ts';

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
    return json({ devices: count ?? 0, sent, error: sent ? undefined : lastPushError });
  }

  if (p.action === 'challenges') {
    const cols = 'id, ref_no, mode, stake, status, note, room_id, creator_claim, opponent_claim, claim_at, resolution, created_at, accepted_at, resolved_at, rule_by, rule_reason, rule_held, rule_winner, rule_at, rule_done_at, creator_id:creator, opponent_id:opponent, creator:players!challenges_creator_fkey(username, player_tag), opponent:players!challenges_opponent_fkey(username, player_tag)';
    // find one challenge by its number (#C-1043, C1043 or 1043)
    const refNo = parseInt(String(p.ref || '').replace(/\D/g, ''), 10);
    let recentQ = supabase.from('challenges').select(cols).neq('status', 'disputed').or('rule_at.is.null,rule_done_at.not.is.null').order('created_at', { ascending: false }).limit(30);
    if (refNo > 0) recentQ = supabase.from('challenges').select(cols).eq('ref_no', refNo).limit(1);
    const [{ data: disputed, error: e1 }, { data: recent, error: e2 }] = await Promise.all([
      supabase.from('challenges').select(cols).or('status.eq.disputed,and(rule_at.not.is.null,rule_done_at.is.null)').order('created_at', { ascending: true }),
      recentQ,
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
    const lock = p.outcome === 'rule_void' ? Number(p.lock_days ?? 0) : 0;
    if (![-1, 0, 1, 3, 7, 30].includes(lock)) return fail('Pick a punishment: warning, 1, 3, 7 or 30 days, or a challenge ban.');
    // fine 0-20 points, rule breaker -> reporter (10 if an old page sends none)
    const fine = p.outcome === 'rule_void' ? Number(p.fine ?? 10) : 0;
    if (!Number.isInteger(fine) || fine < 0 || fine > 20) return fail('The fine must be 0 to 20 points.');
    const { error } = await supabase.rpc('admin_resolve_challenge', { p_id: p.id, p_outcome: p.outcome, p_lock_days: lock, p_fine: fine });
    if (error) return fail(error.message);
    return json({ ok: true });
  }

  if (p.action === 'money') {
    const { data, error } = await supabase.rpc('admin_money_flow');
    if (error) return fail(error.message, 500);
    return json(data);
  }

  if (p.action === 'history') {
    if (!p.player_id) return fail('Pick a player');
    const { data: who } = await supabase.from('players').select('username, player_tag').eq('id', p.player_id).maybeSingle();
    if (!who) return fail('Player not found', 404);
    const { data: w } = await supabase.from('wallets').select('balance, unlimited').eq('player_id', p.player_id).maybeSingle();
    const rows: any[] = [];
    for (let page = 0; page < 5; page++) {   // the API returns 1,000 rows at a time
      const { data, error } = await supabase.from('wallet_ledger').select('delta, balance_after, reason, ref, note, created_at')
        .eq('player_id', p.player_id).order('created_at', { ascending: false }).range(page * 1000, page * 1000 + 999);
      if (error) return fail(error.message, 500);
      rows.push(...(data || []));
      if ((data || []).length < 1000) break;
    }
    return json({ player: who, balance: w?.balance ?? 0, unlimited: !!w?.unlimited, rows,
      added: rows.reduce((s, r) => s + Math.max(r.delta, 0), 0), taken: rows.reduce((s, r) => s + Math.max(-r.delta, 0), 0) });
  }
  if (p.action === 'balances') {
    const { data, error } = await supabase.from('players')
      .select('id, username, player_tag, email, wallets(balance, unlimited, staff, updated_at)');
    if (error) return fail(error.message, 500);
    const rows = (data || []).map((x: any) => {
      const w = Array.isArray(x.wallets) ? x.wallets[0] : x.wallets;
      return { id: x.id, username: x.username, player_tag: x.player_tag, email: x.email,
        balance: w?.balance ?? 0, unlimited: !!w?.unlimited, staff: !!w?.staff, updated_at: w?.updated_at ?? null };
    }).sort((a: any, b: any) => (b.unlimited ? 1 : 0) - (a.unlimited ? 1 : 0) || b.balance - a.balance);
    const { data: pend } = await supabase.from('withdraw_requests').select('amount, payout').eq('status', 'pending');
    return json({ rows, pending_withdrawals: (pend || []).reduce((s: number, r: any) => s + (r.payout ?? r.amount), 0) });
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

  // refunds: the player's refundable charges, and the refund itself (rules in admin_refund.sql)
  // a forgotten wallet PIN: only the admin can clear it, after checking this is the real owner
  if (p.action === 'reset_pin') {
    const { data, error } = await supabase.rpc('admin_wallet_pin_reset', { p_player: p.player_id });
    if (error) return fail(error.message);
    return json(data);
  }
  if (p.action === 'refundables') {
    const { data, error } = await supabase.rpc('admin_refundables', { p_player: p.player_id });
    if (error) return fail(error.message);
    return json(data || []);
  }
  if (p.action === 'refund') {
    const amount = p.amount === null || p.amount === undefined || p.amount === '' ? null : parseInt(p.amount);
    const { data, error } = await supabase.rpc('admin_refund', {
      p_player: p.player_id, p_ledger: p.ledger_id || null, p_amount: amount, p_reason: p.reason || null,
    });
    if (error) return fail(error.message);
    return json(data); // the player's notification (and its push) is inserted by admin_refund
  }

  if (p.action === 'withdrawals') {
    const { data, error } = await supabase.from('withdraw_requests')
      .select('id, amount, fee, payout, esewa_id, esewa_name, status, created_at, players(username, player_tag)')
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

  // points loads: players upload the eSewa screenshot on /wallet/ (request_wallet_load)
  // is the JD phone (JD Admin app) still sending eSewa alerts? Its 15-min health check + the last alert it sent
  if (p.action === 'relay_status') {
    const [{ data: f }, { data: last }] = await Promise.all([
      supabase.storage.from('admin-tools').download('relay-beat.json'),
      supabase.from('payments_in').select('received_at').order('received_at', { ascending: false }).limit(1),
    ]);
    let beat: any = null; try { beat = f ? JSON.parse(await f.text()) : null; } catch { beat = null; }
    return json({ beat, last_alert: last?.[0]?.received_at || null });
  }

  if (p.action === 'loads') {
    // each waiting load gets the JD phone's eSewa alerts that fit it (same amount, paid up to 3 h before or 30 min
    // after the request, not used yet), so the admin can match it in one tap instead of opening eSewa
    const since = new Date(Date.now() - 72 * 3600e3).toISOString();
    const [{ data, error }, { data: pays }] = await Promise.all([
      supabase.from('wallet_load_requests')
        .select('*, players(username, player_tag)')   // * = also esewa_code / sender_name (load_proof.sql)
        .eq('status', 'pending').order('created_at', { ascending: true }).limit(50),
      supabase.from('payments_in').select('id, amount, sender, received_at').gt('received_at', since)
        .is('load_id', null).is('matched_at', null).order('received_at', { ascending: false }).limit(80),
    ]);
    if (error) return fail(error.message, 500);
    // same rule as _pay_name_fit (load_name_fit.sql): equal, or one is the other plus words and the shorter has 2+ words
    const fitName = (a: string, b: string) => !!a && !!b && (a === b || (a.split(' ').length >= 2 && b.startsWith(a + ' ')) || (b.split(' ').length >= 2 && a.startsWith(b + ' ')));
    const nm = (s: unknown) => String(s || '').replace(/\s+in your e-?sewa account.*$/i, '').replace(/\s+/g, ' ').trim().toLowerCase();
    return json((data || []).map((r: any) => {
      const t = new Date(r.created_at).getTime();
      const fits = (pays || []).filter((x: any) => x.amount === r.amount
        && new Date(x.received_at).getTime() >= t - 3 * 3600e3 && new Date(x.received_at).getTime() <= t + 30 * 60e3)
        .map((x: any) => ({ id: x.id, amount: x.amount, sender: nm(x.sender), at: x.received_at, same_name: fitName(nm(x.sender), nm(r.sender_name)) }))
        .sort((a: any, b: any) => Number(b.same_name) - Number(a.same_name));
      return { ...r, fits };
    }));
  }

  // one-tap: link a waiting load to the eSewa alert it fits; the database re-checks amount, time and reuse
  if (p.action === 'match_load') {
    const pid = Number(p.payment_id);
    if (!/^[0-9a-f-]{36}$/i.test(String(p.id || '')) || !Number.isInteger(pid)) return fail('id and payment_id required');
    const { data, error } = await supabase.rpc('match_load_payment', { p_load: p.id, p_payment: pid, p_by: 'admin' });
    if (error) return fail(error.message);
    return json(data);
  }

  if (p.action === 'resolve_load') {
    const amount = p.amount == null || p.amount === '' ? null : parseInt(p.amount, 10);
    const { data, error } = await supabase.rpc('admin_resolve_load', {
      p_id: p.id, p_approve: !!p.approve, p_amount: amount, p_note: p.note || null,
    });
    if (error) return fail(error.message);
    // the player's notification (and its push) is inserted by admin_resolve_load / admin_wallet_credit
    return json(data);
  }

  return fail('Unknown action');
});
