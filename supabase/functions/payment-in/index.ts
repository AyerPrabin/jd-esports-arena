// Money received on the owner's phone -> JD Arena (payments_in.sql). The JD Pay Relay app (E:\jd-android\relay) posts
// every eSewa / Khalti / IME Pay notification here; JD staff mods get a push and can match it to a player's load
// request in /mod/. Deploy with --no-verify-jwt (the phone has no Supabase login).
// Auth: header x-pay-token must equal the PAYMENT_HOOK_TOKEN secret.
// Body: JSON { text, title?, app? }. Wallet alerts we can't use go to payments_in_skipped so the admin can see why.
import { createClient } from 'npm:@supabase/supabase-js@2';

const OWNER = (Deno.env.get('ADMIN_EMAIL') || 'ayerprabin95@gmail.com').toLowerCase();
const same = (a: string, b: string) => {   // constant-time compare
  if (!a || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
};

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return new Response('POST only', { status: 405 });
  const TOKEN = Deno.env.get('PAYMENT_HOOK_TOKEN') || '';
  const got = req.headers.get('x-pay-token') || '';   // header only: a token in the URL ends up in logs
  if (TOKEN.length < 24 || !same(got, TOKEN)) return new Response('Unauthorized', { status: 401 });

  const raw = await req.text();
  let text = raw, app = '', j: any = {};
  try { j = JSON.parse(raw); text = [j.title, j.text].filter(Boolean).join(' · '); app = String(j.app || ''); } catch { /* plain text */ }
  text = String(text || '').replace(/\s+/g, ' ').trim().slice(0, 600);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  // phone push to the owner + staff mods (the notifications insert trigger sends it)
  const pushStaff = async (title: string, body: string) => {
    const { data: mods } = await db.from('moderators').select('email').eq('role', 'staff');
    const emails = [...new Set([OWNER, ...(mods || []).map((x: any) => String(x.email).toLowerCase())])];
    const { data: staff } = await db.from('players').select('id').in('email', emails);
    if (staff?.length) await db.from('notifications').insert(staff.map((s: any) => ({ player_id: s.id, push: true, title, body })));
  };

  // "Send test" in JD Pay Relay proves the whole path with one push (at most one every 5 minutes)
  if (app === 'jd-relay-test') {
    const { count } = await db.from('notifications').select('id', { count: 'exact', head: true })
      .eq('title', '🧪 JD Pay Relay connected').gt('created_at', new Date(Date.now() - 300000).toISOString());
    if (!count) await pushStaff('🧪 JD Pay Relay connected', 'Test from the JD phone worked. eSewa "money received" alerts will now show in Mod > Loads.');
    return Response.json({ saved: false, test: true, pushed: !count });
  }
  // JD Admin app update check: admin-tools/relay.json (private bucket) + a 1-hour download link for that APK
  if (app === 'jd-relay-update') {
    const { data: f } = await db.storage.from('admin-tools').download('relay.json');
    if (!f) return Response.json({ versionCode: 0 });
    let v: any; try { v = JSON.parse(await f.text()); } catch { return Response.json({ versionCode: 0 }); }
    const file = String(v.file || '');
    if (!/^jd-pay-relay-[\d.]+\.apk$/.test(file)) return Response.json({ versionCode: 0 });
    const { data: s } = await db.storage.from('admin-tools').createSignedUrl(file, 3600);
    return Response.json({ versionCode: +v.versionCode || 0, versionName: String(v.versionName || ''), notes: String(v.notes || '').slice(0, 200), url: s?.signedUrl || '' });
  }
  // JD Admin 2.2+: every 15 min the phone says it is alive (admin-tools/relay-beat.json, read by wallet-admin)
  if (app === 'jd-relay-beat') {
    const beat = { at: new Date().toISOString(), v: +j.v || 0, access: !!j.access, listening: !!j.listening, battery: !!j.battery, queued: Math.min(+j.queued || 0, 99) };
    await db.storage.from('admin-tools').upload('relay-beat.json', new Blob([JSON.stringify(beat)], { type: 'application/json' }), { upsert: true });
    return Response.json({ ok: true });
  }
  // JD Admin's "Needs you" card: counts only, no names or amounts
  if (app === 'jd-relay-stats') {
    const c = (q: any) => q.then((r: any) => r.count ?? 0, () => 0);
    const n = (t: string) => db.from(t).select('*', { count: 'exact', head: true });
    const [loads, withdraws, challenges, promos, chats, report] = await Promise.all([
      c(n('wallet_load_requests').eq('status', 'pending')), c(n('withdraw_requests').eq('status', 'pending')),
      c(n('challenges').eq('status', 'disputed')), c(n('promo_posts').eq('status', 'pending')),
      c(n('jd_messages').eq('channel', 'jd').eq('from_staff', false).is('read_at', null)),
      db.rpc('commission_report', {}).then((r: any) => r.data || [], () => []),
    ]);
    const commission = report.filter((x: any) => !x.settled && x.amount > 0).length;
    return Response.json({ loads, withdraws, challenges, promos, chats, commission });
  }
  // only the wallet apps (the relay sends the package name): anything else is ignored
  if (!/esewa|f1soft|khalti|ime ?pay|imepay/i.test(app)) return Response.json({ saved: false, why: 'not from eSewa, Khalti or IME Pay' });

  // OTPs, PINs and login codes are never stored, logged or shown to anyone
  if (/\b(otp|one[- ]?time|verification|verify|security code|pin|password|mpin|login|log in|sign in|device)\b/i.test(text)) {
    return Response.json({ saved: false, why: 'security alert ignored' });
  }
  const skip = async (why: string) => {
    console.log('payment-in skipped:', why, '|', app);   // no alert text in logs
    // long digit runs (phone / account / transaction numbers) are masked before staff can see them
    await db.from('payments_in_skipped').insert({ app: app.slice(0, 80), why, raw: text.replace(/\d{5,}/g, m => '•••' + m.slice(-2)) });
    return Response.json({ saved: false, why });
  };
  // only "received" money: skip "sent", "paid", OTPs and promos
  if (!/receiv|credited|प्राप्त|aayo|jamma/i.test(text) || /\b(sent|paid to|otp|cashback offer)\b/i.test(text)) return skip('not a money-received notification');
  const m = text.match(/(?:rs\.?|npr|रु\.?)\s*([\d,]+(?:\.\d{1,2})?)/i);
  const amount = m ? Math.round(parseFloat(m[1].replace(/,/g, ''))) : 0;
  if (!(amount >= 1 && amount <= 100000)) return skip('no amount found');
  const sender = (text.match(/from\s+([A-Za-z][A-Za-z .'-]{1,40}?)(?=\s*(?:[.,(·]|on |at |rs|npr|$))/i) || [])[1] || null;
  const provider = /khalti/i.test(app) ? 'khalti' : /ime/i.test(app) ? 'imepay' : 'esewa';

  // JD Admin 2.2+ sends when the alert reached the phone, so an alert sent late (no internet) still fits its load.
  // Only the last 48 h, never the future.
  const now = Date.now(), posted = Number(j.posted);
  const at = Number.isFinite(posted) && posted > now - 48 * 3600e3 && posted <= now + 120e3 ? Math.min(posted, now) : now;
  // the same notification can come twice (fired twice, or re-sent after the listener restarts): same text and a
  // time within 90 s is the same payment
  const { data: dup } = await db.from('payments_in').select('id').eq('raw', text)
    .gte('received_at', new Date(at - 90e3).toISOString()).lte('received_at', new Date(at + 90e3).toISOString()).limit(1);
  if (dup?.length) return Response.json({ saved: false, why: 'duplicate' });
  const { data: row, error } = await db.from('payments_in').insert({ provider, amount, sender, raw: text, received_at: new Date(at).toISOString() }).select('id').single();
  if (error) return new Response(error.message, { status: 500 });

  const { count } = await db.from('wallet_load_requests').select('id', { count: 'exact', head: true }).eq('status', 'pending').eq('amount', amount);
  await pushStaff(`💰 Rs ${amount} received (${provider})`,
    `${sender ? 'From ' + sender + '. ' : ''}${count ? count + ' load request' + (count > 1 ? 's' : '') + ' for Rs ' + amount + ' waiting: open Mod > Loads to match it.' : 'No load request for this amount yet.'}`);
  return Response.json({ saved: true, id: row.id, amount, provider });
});
