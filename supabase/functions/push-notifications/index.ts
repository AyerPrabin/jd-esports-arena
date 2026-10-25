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

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  let ids: string[] = [];
  try { ids = ((await req.json()).ids || []).filter((x: unknown) => typeof x === 'string').slice(0, 1000); } catch { /* empty */ }
  if (!ids.length) return Response.json({ sent: 0 });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: rows } = await db.from('notifications').select('id, player_id, tournament_slug, title, body').in('id', ids);
  let sent = 0;
  for (const n of rows || []) {
    const body = String(n.body || '').startsWith('TICKET::') ? 'Your ticket is ready — tap to view.' : String(n.body || '');
    sent += await sendPush(db, [n.player_id], { title: n.title || 'JD Arena', body: body.slice(0, 300), ...linkFor(n) });
  }
  return Response.json({ sent });
});
