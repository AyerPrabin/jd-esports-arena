// 📞 Ring squad: a member of a squad/group chat calls everyone else in it. Teammates' phones ring
// (JD Arena app: "Squad calls" channel, ringtone + repeating buzz until opened or 45 s - PushService.java;
// browsers: long buzz, stays until tapped - sw.js "ring"). A "📞 @x is calling the squad" line goes into the chat
// (kind 'system', so chat-push doesn't send a second alert). One ring per caller per chat every 2 minutes.
// Muted members and players who turned squad alerts off are not rung.   body: { group_id }   (signed-in player)
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush } from '../_shared/push.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
const GAP_MS = 2 * 60000;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const jwt = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  const { data: u } = await db.auth.getUser(jwt);
  const me = u?.user?.id;
  if (!me) return json({ error: 'Please sign in first.' }, 401);
  let group = '';
  try { group = String((await req.json()).group_id || ''); } catch { /* checked below */ }
  if (!/^[0-9a-f-]{36}$/i.test(group)) return json({ error: 'Open your squad chat first.' }, 400);

  const [{ data: g }, { data: mem }, { data: ban }, { data: who }] = await Promise.all([
    db.from('chat_groups').select('name').eq('id', group).maybeSingle(),
    db.from('chat_group_members').select('player_id, muted').eq('group_id', group),
    db.from('banned_players').select('player_id').eq('player_id', me).maybeSingle(),
    db.from('players').select('username, player_tag').eq('id', me).maybeSingle(),
  ]);
  if (!g || !(mem || []).some((m: any) => m.player_id === me)) return json({ error: "You're not in this chat." }, 403);
  if (ban) return json({ error: 'Your account is banned.' }, 403);

  const name = who?.username ? '@' + who.username : (who?.player_tag || 'A teammate');
  const line = `📞 ${name} is calling the squad`;
  // rate limit from the chat itself: this caller's last ring line in this chat
  const { data: last } = await db.from('group_messages').select('created_at').eq('group_id', group).eq('kind', 'system')
    .eq('body', line).order('id', { ascending: false }).limit(1).maybeSingle();
  const wait = last ? GAP_MS - (Date.now() - Date.parse(last.created_at)) : 0;
  if (wait > 0) return json({ error: `You just rang them. Try again in ${Math.ceil(wait / 1000)} s.` }, 429);

  const to = (mem || []).filter((m: any) => m.player_id !== me && !m.muted).map((m: any) => m.player_id);
  await db.from('group_messages').insert({ group_id: group, sender: me, kind: 'system', body: line });
  const rang = to.length ? await sendPush(db, to, {
    title: `📞 ${name} is calling`,
    body: `${g.name || 'Your squad'}: get online now! Tap to open the squad chat.`,
    url: `https://jdesport.co.uk/chat/?g=${group}`,
    tag: 'jd-ring-' + group.slice(0, 8),
    category: 'squad',
  }) : 0;
  return json({ ok: true, members: to.length, rang });
});
