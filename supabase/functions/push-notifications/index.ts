// Called by the notifications_push trigger (schema.sql) via pg_net whenever notification rows
// are saved with push = true — tickets, entry confirmations, wallet credits, prizes, challenge
// invites/results, waitlist moves, admin alerts. Sends each one as a Web Push (Google FCM on
// Chrome/Android/Edge/Brave) so it shows on the phone/desktop even when JD Arena is closed.
// Edge Functions that already push their own alerts insert with push = false to avoid doubles.
//   body: { ids: uuid[] }   header: x-cron-secret (the pg_net caller isn't a logged-in user)
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush } from '../_shared/push.ts';

const SITE = 'https://jdesport.co.uk';

function linkFor(n: any): { url: string; tag: string } {
  const t = `${n.title || ''} ${n.body || ''}`;
  if (/challenge/i.test(t)) return { url: `${SITE}/challenges/`, tag: 'jd-challenge' };
  if (/wallet|points added/i.test(t)) return { url: `${SITE}/wallet/`, tag: 'jd-wallet' };
  if (/Admin →/.test(t)) return { url: `${SITE}/admin/`, tag: 'jd-admin' };
  if (n.tournament_slug) return { url: `${SITE}/#tournaments`, tag: 'jd-t-' + String(n.tournament_slug).slice(0, 40) };
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
