// Announces a newly created OPEN challenge to every other player: an in-app notification
// row each, plus a push alert (native Web Push) that opens the challenge when tapped.
// Called by /challenges/ right after create_challenge() succeeds, with the creator's own
// login token. The caller must be the challenge's creator, the challenge must still be
// open, not a direct invite, and only minutes old — and broadcast_at makes it once-only,
// so nobody can use this to spam everyone.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush } from '../_shared/push.ts';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const SITE_URL = 'https://jdesport.co.uk';
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } });

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return json({ error: 'Not signed in' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: uErr } = await anon.auth.getUser(token);
  if (uErr || !user) return json({ error: 'Invalid session' }, 401);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: 'Bad JSON' }, 400); }
  const id = String(body.challenge_id || '');
  if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: 'challenge_id required' }, 400);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const since = new Date(Date.now() - 5 * 60 * 1000).toISOString();
  // claim the broadcast atomically: only the creator, only once, only a fresh open challenge
  const { data: c, error: cErr } = await db.from('challenges')
    .update({ broadcast_at: new Date().toISOString() })
    .eq('id', id).eq('creator', user.id).eq('status', 'open').is('invited', null).is('broadcast_at', null).gte('created_at', since)
    .select('id, mode, stake, note').maybeSingle();
  if (cErr) return json({ error: cErr.message }, 500);
  if (!c) return json({ sent: 0, note: 'Nothing to announce' });

  const { data: me } = await db.from('players').select('username, player_tag').eq('id', user.id).maybeSingle();
  const who = me?.username ? '@' + me.username : (me?.player_tag || 'A player');
  const pot = c.stake * 2 - 2; // matches challenge_fee_per_player() = 1
  const title = `⚔️ New ${c.mode} challenge — win ${pot} points`;
  const text = `${who} wants a ${c.mode} Clash Squad match: ${c.stake} points each, winner gets ${pot}.${c.note ? ' "' + String(c.note).slice(0, 80) + '"' : ''} Open Challenges to accept.`;

  const { data: players, error: pErr } = await db.from('players').select('id').neq('id', user.id).limit(10000);
  if (pErr) return json({ error: pErr.message }, 500);
  const ids = (players || []).map((p: any) => p.id);
  for (let i = 0; i < ids.length; i += 500) {
    await db.from('notifications').insert(ids.slice(i, i + 500).map((pid: string) => ({ player_id: pid, title, body: text })));
  }

  let pushed = 0;
  pushed = await sendPush(db, ids, { title, body: text, url: `${SITE_URL}/challenges/?c=${c.id}`, tag: 'jd-challenge' });
  return json({ sent: ids.length, pushed });
});
