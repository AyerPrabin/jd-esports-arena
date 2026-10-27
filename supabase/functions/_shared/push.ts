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
  /** Alert type players can switch off (push_prefs.off): dm, squad, match, friends,
   *  challenges, lobby, wallet. No category = always sent (tournaments, security). */
  category?: string;
}

/** Push to every saved device of the given players. Returns how many devices accepted it. */
export async function sendPush(supabase: any, playerIds: string[], msg: PushMessage): Promise<number> {
  let ids = [...new Set((playerIds || []).filter(Boolean))];
  lastPushError = '';
  if (!ids.length) return 0;
  // players who switched this alert type off (⚙️ alert settings) — they still get the
  // notification row in history, just no push
  if (msg.category) {
    const muted = new Set<string>();
    for (let i = 0; i < ids.length; i += 300) {
      const { data } = await supabase.from('push_prefs').select('player_id').in('player_id', ids.slice(i, i + 300)).contains('off', [msg.category]);
      (data || []).forEach((r: any) => muted.add(r.player_id));
    }
    ids = ids.filter((id) => !muted.has(id));
    if (!ids.length) return 0;
  }
  // JD Arena app 2.0+ phones (Firebase tokens), then the browsers (Web Push)
  let ok = await sendFcm(supabase, ids, msg);
  if (!configure()) { if (!ok) lastPushError = lastPushError || 'VAPID keys not set'; return ok; }
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
    category: msg.category || '',
  });
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

// ── JD Arena app 2.0+: Firebase Cloud Messaging (HTTP v1) ──────────────────────────────────────────────
// The app is a real Android app now (no browser inside), so Web Push can't reach it. The site saves the app's
// FCM token in push_fcm_tokens (save_fcm_token); this sends a data message the app turns into a notification
// (PushService.java). FCM_SERVICE_ACCOUNT = the Firebase service-account JSON (Supabase secret). Not set = skip.
let fcmToken = '', fcmTokenExp = 0, fcmProject = '';
const b64url = (b: Uint8Array | string) => btoa(typeof b === 'string' ? b : String.fromCharCode(...b))
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

async function fcmAccessToken(): Promise<string> {
  if (fcmToken && Date.now() < fcmTokenExp) return fcmToken;
  const raw = Deno.env.get('FCM_SERVICE_ACCOUNT');
  if (!raw) return '';
  const sa = JSON.parse(raw);
  fcmProject = sa.project_id;
  const now = Math.floor(Date.now() / 1000);
  const unsigned = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' })) + '.' + b64url(JSON.stringify({
    iss: sa.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600,
  }));
  const der = Uint8Array.from(atob(sa.private_key.replace(/-----[^-]+-----|\s/g, '')), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned)));
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=' + unsigned + '.' + b64url(sig),
  });
  const j = await r.json();
  if (!j.access_token) { lastPushError = 'FCM auth: ' + JSON.stringify(j).slice(0, 200); return ''; }
  fcmToken = j.access_token;
  fcmTokenExp = Date.now() + 50 * 60 * 1000;
  return fcmToken;
}

async function sendFcm(supabase: any, ids: string[], msg: PushMessage): Promise<number> {
  const tokens: string[] = [];
  for (let i = 0; i < ids.length; i += 300) {
    const { data } = await supabase.from('push_fcm_tokens').select('token').in('player_id', ids.slice(i, i + 300));
    (data || []).forEach((r: any) => tokens.push(r.token));
  }
  if (!tokens.length) return 0;
  let access = '';
  try { access = await fcmAccessToken(); } catch (e) { lastPushError = 'FCM auth: ' + String(e); }
  if (!access) return 0;
  const data = { title: msg.title, body: msg.body, url: msg.url || 'https://jdesport.co.uk/', tag: msg.tag || 'jd-arena', category: msg.category || '' };
  let ok = 0;
  const dead: string[] = [], good: string[] = [];
  for (let i = 0; i < tokens.length; i += 25) {
    await Promise.all(tokens.slice(i, i + 25).map(async (token) => {
      try {
        const r = await fetch(`https://fcm.googleapis.com/v1/projects/${fcmProject}/messages:send`, {
          method: 'POST', headers: { Authorization: 'Bearer ' + access, 'Content-Type': 'application/json' },
          body: JSON.stringify({ message: { token, data, android: { priority: 'HIGH', ttl: '3600s' } } }),
        });
        if (r.ok) { ok++; good.push(token); return; }
        const t = await r.text();
        lastPushError = `FCM ${r.status} ${t.slice(0, 200)}`;
        if (r.status === 404 || /UNREGISTERED|INVALID_ARGUMENT/.test(t)) dead.push(token);   // app removed / token replaced
      } catch (e) { lastPushError = 'FCM ' + String(e); }
    }));
  }
  if (dead.length) await supabase.from('push_fcm_tokens').delete().in('token', dead);
  if (good.length) await supabase.from('push_fcm_tokens').update({ last_ok_at: new Date().toISOString() }).in('token', good);
  return ok;
}
