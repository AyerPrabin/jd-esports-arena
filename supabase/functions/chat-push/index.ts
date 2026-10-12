// Called by the group_messages_push / challenge_messages_push triggers (schema.sql, "Messages
// v2") via pg_net for every new squad-chat or match-chat message. Pushes it to everyone else
// in that chat who hasn't already read it and hasn't muted the chat:
//   squad chat → "👥 <chat name>"  "@sender: message"   opens /?g=<group id>
//   match chat → "⚔️ 2v2 · @sender" "message"           opens /challenges/?c=<challenge id>
// One tag per chat, so a burst replaces the previous alert instead of stacking, and only the
// newest message of a burst is pushed to each person. System lines ("X joined") never push.
// Must be deployed with --no-verify-jwt (the pg_net caller has no JWT, only x-cron-secret).
//   body: { kind: 'group' | 'match', ids: number[] }   header: x-cron-secret
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush } from '../_shared/push.ts';

const SITE = 'https://jdesport.co.uk';

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  let ids: number[] = [], kind = '';
  try {
    const b = await req.json();
    kind = b.kind === 'group' ? 'group' : b.kind === 'match' ? 'match' : '';
    ids = (b.ids || []).map(Number).filter((x: number) => Number.isFinite(x)).slice(0, 200);
  } catch { /* empty */ }
  if (!ids.length || !kind) return Response.json({ sent: 0 });
  // Same as dm-push: give an open chat (refreshes every 2.5s and marks read) a moment first,
  // so a live back-and-forth doesn't also buzz the phone. Reply at once (pg_net times out at 5s).
  const work = (async () => {
    await new Promise((r) => setTimeout(r, 4000));
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const table = kind === 'group' ? 'group_messages' : 'challenge_messages';
    const cols = kind === 'group' ? 'id, group_id, sender, kind, body' : 'id, challenge_id, sender, body';
    const { data: rows } = await db.from(table).select(cols).in('id', ids).order('id');
    const msgs = (rows || []).filter((m: any) => m.sender && m.kind !== 'system');
    if (!msgs.length) return;
    const senders = [...new Set(msgs.map((m: any) => m.sender))];
    const { data: ps } = await db.from('players').select('id, username, player_tag').in('id', senders);
    const who = new Map((ps || []).map((p: any) => [p.id, p.username ? '@' + p.username : (p.player_tag || 'A player')]));
    const nameOf = (id: string) => who.get(id) || 'A player';
    // newest message per chat
    const latest = new Map<string, any>();
    for (const m of msgs) latest.set(kind === 'group' ? m.group_id : m.challenge_id, m);
    let sent = 0;
    for (const [chat, m] of latest) {
      const text = m.kind === 'room' ? '🎮 shared a room — tap to see the ID and password' : String(m.body || '');
      if (kind === 'group') {
        const [{ data: g }, { data: mem }] = await Promise.all([
          db.from('chat_groups').select('name').eq('id', chat).maybeSingle(),
          db.from('chat_group_members').select('player_id, last_read_id, muted').eq('group_id', chat),
        ]);
        const to = (mem || []).filter((x: any) => x.player_id !== m.sender && !x.muted && Number(x.last_read_id) < m.id).map((x: any) => x.player_id);
        if (!to.length) continue;
        sent += await sendPush(db, to, {
          title: `👥 ${g?.name || 'Squad chat'}`,
          body: `${nameOf(m.sender)}: ${text}`.slice(0, 200),
          url: `${SITE}/?g=${chat}`,
          tag: 'jd-g-' + String(chat).slice(0, 8),
        });
      } else {
        const [{ data: c }, { data: reads }] = await Promise.all([
          db.from('challenges').select('creator, opponent, mode, status').eq('id', chat).maybeSingle(),
          db.from('challenge_reads').select('player_id, last_read_id').eq('challenge_id', chat),
        ]);
        if (!c || !['accepted', 'disputed', 'completed'].includes(c.status)) continue;
        const read = new Map((reads || []).map((r: any) => [r.player_id, Number(r.last_read_id)]));
        const to = [c.creator, c.opponent].filter((p: string) => p && p !== m.sender && (read.get(p) || 0) < m.id);
        if (!to.length) continue;
        sent += await sendPush(db, to, {
          title: `⚔️ ${c.mode} · ${nameOf(m.sender)}`,
          body: text.slice(0, 200),
          url: `${SITE}/challenges/?c=${chat}`,
          tag: 'jd-c-' + String(chat).slice(0, 8),
        });
      }
    }
    console.log('chat-push', kind, 'sent', sent);
  })().catch((e) => console.error('chat-push', e));
  // @ts-ignore EdgeRuntime is provided by Supabase Edge Functions
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(work); else await work;
  return Response.json({ queued: ids.length });
});
