// Native Web Push (VAPID) sender shared by every Edge Function that notifies players.
// Replaces OneSignal: subscriptions live in public.push_subscriptions (saved by the site via
// save_push_subscription), so ad-blockers / Brave Shields can't block delivery — the only
// third party involved is the browser's own push service. Dead subscriptions (404/410) are
// removed automatically. Payload shape is read by the push handler in /sw.js.
import webpush from 'npm:web-push@3.6.7';

let configured = false;
/** Last delivery error (status + push-service reply), for the admin test action. */
export let lastPushError = '';
function configure(): boolean {
  if (configured) return true;
  const pub = Deno.env.get('VAPID_PUBLIC_KEY'), priv = Deno.env.get('VAPID_PRIVATE_KEY');
  if (!pub || !priv) return false;
  webpush.setVapidDetails(Deno.env.get('VAPID_SUBJECT') || 'mailto:prabinayer7@gmail.com', pub, priv);
  configured = true;
  return true;
}

export interface PushMessage {
  title: string;
  body: string;
  url?: string;   // opened when the notification is tapped
  tag?: string;   // same tag replaces an older notification instead of stacking
}

/** Push to every saved device of the given players. Returns how many devices accepted it. */
export async function sendPush(supabase: any, playerIds: string[], msg: PushMessage): Promise<number> {
  const ids = [...new Set((playerIds || []).filter(Boolean))];
  lastPushError = '';
  if (!ids.length) return 0;
  if (!configure()) { lastPushError = 'VAPID keys not set'; return 0; }
  const subs: any[] = [];
  for (let i = 0; i < ids.length; i += 300) {
    const { data } = await supabase.from('push_subscriptions').select('endpoint, p256dh, auth').in('player_id', ids.slice(i, i + 300));
    subs.push(...(data || []));
  }
  const payload = JSON.stringify({
    title: msg.title,
    body: msg.body,
    url: msg.url || 'https://jdesport.co.uk/',
    tag: msg.tag || 'jd-arena',
  });
  let ok = 0;
  const dead: string[] = [];
  const good: string[] = [];
  // modest concurrency so a big broadcast doesn't open hundreds of sockets at once
  for (let i = 0; i < subs.length; i += 25) {
    await Promise.all(subs.slice(i, i + 25).map(async (s) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600, urgency: 'high' });
        ok++; good.push(s.endpoint);
      } catch (e: any) {
        lastPushError = `${e?.statusCode ?? ''} ${e?.body || e?.message || e}`.trim();
        // 404/410 = unsubscribed; 403 = made with another VAPID key (e.g. old OneSignal) — the site re-subscribes on next visit
        if (e && (e.statusCode === 404 || e.statusCode === 410 || e.statusCode === 403)) dead.push(s.endpoint);
      }
    }));
  }
  if (dead.length) await supabase.from('push_subscriptions').delete().in('endpoint', dead);
  if (good.length) await supabase.from('push_subscriptions').update({ last_ok_at: new Date().toISOString() }).in('endpoint', good);
  return ok;
}
