// Called by the notifications_push trigger (schema.sql) via pg_net whenever notification rows
// are saved with push = true — tickets, entry confirmations, wallet credits, prizes, challenge
// invites/results, waitlist moves, admin alerts. Sends each one as a Web Push (Google FCM on
// Chrome/Android/Edge/Brave) so it shows on the phone/desktop even when JD Arena is closed.
// Edge Functions that already push their own alerts insert with push = false to avoid doubles.
//   body: { ids: uuid[] }   header: x-cron-secret (the pg_net caller isn't a logged-in user)
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush } from '../_shared/push.ts';

const SITE = 'https://jdesport.co.uk';

// Keep these patterns in step with notifKind() in index.html (the Notifications list uses the
// same buckets). category = the alert type players can switch off (push_prefs, ⚙️ settings);
// tournament and admin alerts have none, so they always push.
function linkFor(n: any): { url: string; tag: string; category?: string } {
  const t = `${n.title || ''} ${n.body || ''}`;
  if (/squad chat|friend request|now your friend/i.test(t)) return { url: `${SITE}/chat/`, tag: 'jd-chat', category: 'friends' };
  // daily reminder: daily_challenge_alert already decides whether the row exists, so no category
  if (/daily challenge time/i.test(t)) return { url: `${SITE}/challenges/`, tag: 'jd-challenge-daily' };
  // result deadlines and disputes can cost a stake if missed: always pushed
  if (/confirm your challenge result|challenge disputed|challenge under review/i.test(t)) return { url: `${SITE}/challenges/`, tag: 'jd-challenge-result' };
  if (/challenge/i.test(t)) return { url: `${SITE}/challenges/`, tag: 'jd-challenge', category: 'challenges' };
  if (/wallet|points added/i.test(t)) return { url: `${SITE}/wallet/`, tag: 'jd-wallet', category: 'wallet' };
  if (/Admin →/.test(t)) return { url: `${SITE}/admin/`, tag: 'jd-admin' };
  // tournament alerts open that event's ticket on the homepage (home.js ?ticket=)
  if (n.tournament_slug) return { url: `${SITE}/?ticket=${encodeURIComponent(n.tournament_slug)}#tournaments`, tag: 'jd-t-' + String(n.tournament_slug).slice(0, 40) };
  return { url: `${SITE}/`, tag: 'jd-arena' };
}

// Reliable delivery (push_reliable.sql, 2026-10-30): pg_net only waits a few seconds, so the work runs in the
// background after a quick reply; the same alert to many players (an announcement) goes out as one batch; every
// row gets pushed_at once tried, and { sweep: true } (cron every 5 min) resends rows from the last 30 min that
// never got one - a cold start, a timeout or an FCM hiccup no longer loses a notification.
async function deliver(db: any, ids: string[]): Promise<number> {
  // in chunks: hundreds of ids in one .in() make the request URL too long and the read comes back empty
  const rows: any[] = [];
  for (let i = 0; i < ids.length; i += 100) {
    const { data, error } = await db.from('notifications').select('id, player_id, tournament_slug, title, body')
      .in('id', ids.slice(i, i + 100)).is('pushed_at', null);
    if (error) console.error('push-notifications read', error.message);
    rows.push(...(data || []));
  }
  const groups = new Map<string, any[]>();
  for (const n of rows) {
    const k = `${n.title}\u0000${n.body}\u0000${n.tournament_slug || ''}`;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k)!.push(n);
  }
  let sent = 0;
  for (const g of groups.values()) {
    const n = g[0];
    const body = String(n.body || '').startsWith('TICKET::') ? 'Your ticket is ready — tap to view.' : String(n.body || '');
    try {
      sent += await sendPush(db, g.map((x) => x.player_id), { title: n.title || 'JD Arena', body: body.slice(0, 300), ...linkFor(n) });
    } catch (e) { console.error('push-notifications', e); continue; }   // left without pushed_at: the sweep retries
    const gid = g.map((x) => x.id);
    for (let i = 0; i < gid.length; i += 300) {
      await db.from('notifications').update({ pushed_at: new Date().toISOString() }).in('id', gid.slice(i, i + 300));
    }
  }
  return sent;
}

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  let ids: string[] = [], sweep = false;
  try {
    const j = await req.json();
    ids = (j.ids || []).filter((x: unknown) => typeof x === 'string').slice(0, 1000);
    sweep = j.sweep === true;
  } catch { /* empty */ }
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  if (sweep) {   // missed pushes: older than 2 min (the first try is done or dead), newer than 30 min (still useful)
    const { data } = await db.from('notifications').select('id').eq('push', true).is('pushed_at', null)
      .lt('created_at', new Date(Date.now() - 2 * 60000).toISOString())
      .gt('created_at', new Date(Date.now() - 30 * 60000).toISOString()).limit(1000);
    ids = (data || []).map((r: any) => r.id);
  }
  if (!ids.length) return Response.json({ queued: 0 });
  const work = deliver(db, ids).then((n) => console.log('push-notifications sent', n)).catch((e) => console.error('push-notifications', e));
  // @ts-ignore EdgeRuntime is provided by Supabase Edge Functions
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(work); else await work;
  return Response.json({ queued: ids.length });
});
