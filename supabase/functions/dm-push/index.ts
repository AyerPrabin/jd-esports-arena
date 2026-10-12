// Called by the dm_messages_push trigger (schema.sql, "friends + direct messages") via pg_net
// whenever players send each other a direct message. Pushes "💬 @sender: message" to the
// recipient's devices. One tag per conversation, so a burst of messages from the same friend
// replaces the previous alert instead of stacking. Tapping it opens the chat (chat.js reads
// ?dm=<player tag>). DMs never go into notifications, so they don't flood Notification History.
// Must be deployed with --no-verify-jwt (the pg_net caller has no JWT, only x-cron-secret).
//   body: { ids: number[] }   header: x-cron-secret
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush } from '../_shared/push.ts';

const SITE = 'https://jdesport.co.uk';

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  let ids: number[] = [];
  try { ids = ((await req.json()).ids || []).map(Number).filter((x: number) => Number.isFinite(x)).slice(0, 200); } catch { /* empty */ }
  if (!ids.length) return Response.json({ sent: 0 });
  // Give an open chat a moment to mark the message read (chat.js refreshes every 2.5s), so a
  // live back-and-forth doesn't also buzz the phone for every single message. pg_net times
  // out after 5s, so reply at once and push in the background.
  const work = (async () => {
    await new Promise((r) => setTimeout(r, 4000));
    let sent = 0;
    const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: rows } = await db.from('dm_messages').select('id, sender, recipient, body, read_at').in('id', ids).order('id');
    const senders = [...new Set((rows || []).map((r: any) => r.sender))];
    const { data: ps } = senders.length
      ? await db.from('players').select('id, username, player_tag').in('id', senders)
      : { data: [] as any[] };
    const who = new Map((ps || []).map((p: any) => [p.id, p]));
    for (const m of rows || []) {
      if (m.read_at) continue; // already seen in an open chat
      const p: any = who.get(m.sender) || {};
      const name = p.username ? '@' + p.username : (p.player_tag || 'A friend');
      sent += await sendPush(db, [m.recipient], {
        title: `💬 ${name}`,
        body: String(m.body || '').slice(0, 200),
        url: `${SITE}/?dm=${encodeURIComponent(p.player_tag || '')}`,
        tag: 'jd-dm-' + String(m.sender).slice(0, 8),
        category: 'dm',
      });
    }
    console.log('dm-push sent', sent);
  })().catch((e) => console.error('dm-push', e));
  // @ts-ignore EdgeRuntime is provided by Supabase Edge Functions
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(work); else await work;
  return Response.json({ queued: ids.length });
});
