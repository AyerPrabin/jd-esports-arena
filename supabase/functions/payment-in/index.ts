// Money received on the owner's phone -> JD Arena (payments_in.sql). An Android automation app (MacroDroid) posts
// every eSewa / Khalti "you received Rs X" notification here; JD staff mods get a push and can match it to a
// player's load request in /mod/. Deploy with --no-verify-jwt (the phone has no Supabase login).
// Auth: header x-pay-token must equal the PAYMENT_HOOK_TOKEN secret.
// Body: JSON { text, title?, app? } or plain text. Only notifications that contain an amount are saved.
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
  let text = raw, app = '';
  try { const j = JSON.parse(raw); text = [j.title, j.text].filter(Boolean).join(' · '); app = String(j.app || ''); } catch { /* plain text */ }
  text = String(text || '').replace(/\s+/g, ' ').trim().slice(0, 600);
  // only "received" money: skip "sent", "paid", OTPs and promos
  if (!/receiv|credited|प्राप्त|aayo|jamma/i.test(text) || /\b(sent|paid to|otp|cashback offer)\b/i.test(text)) {
    return Response.json({ saved: false, why: 'not a money-received notification' });
  }
  const m = text.match(/(?:rs\.?|npr|रु\.?)\s*([\d,]+(?:\.\d{1,2})?)/i);
  const amount = m ? Math.round(parseFloat(m[1].replace(/,/g, ''))) : 0;
  if (!(amount >= 1 && amount <= 100000)) return Response.json({ saved: false, why: 'no amount found' });
  const sender = (text.match(/from\s+([A-Za-z][A-Za-z .'-]{1,40}?)(?=\s*(?:[.,(·]|on |at |rs|npr|$))/i) || [])[1] || null;
  const provider = /khalti/i.test(text + ' ' + app) ? 'khalti' : /ime/i.test(text + ' ' + app) ? 'imepay' : 'esewa';

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  // the same notification can fire twice: skip a repeat within 2 minutes
  const { data: dup } = await db.from('payments_in').select('id').eq('raw', text).gt('created_at', new Date(Date.now() - 120000).toISOString()).limit(1);
  if (dup?.length) return Response.json({ saved: false, why: 'duplicate' });
  const { data: row, error } = await db.from('payments_in').insert({ provider, amount, sender, raw: text }).select('id').single();
  if (error) return new Response(error.message, { status: 500 });

  // push to the owner + staff mods (the notifications insert trigger sends the phone push)
  const { data: mods } = await db.from('moderators').select('email').eq('role', 'staff');
  const emails = [...new Set([OWNER, ...(mods || []).map((x: any) => String(x.email).toLowerCase())])];
  const { data: staff } = await db.from('players').select('id').in('email', emails);
  const { count } = await db.from('wallet_load_requests').select('id', { count: 'exact', head: true }).eq('status', 'pending').eq('amount', amount);
  if (staff?.length) await db.from('notifications').insert(staff.map((s: any) => ({ player_id: s.id, push: true,
    title: `💰 Rs ${amount} received (${provider})`,
    body: `${sender ? 'From ' + sender + '. ' : ''}${count ? count + ' load request' + (count > 1 ? 's' : '') + ' for Rs ' + amount + ' waiting: open Mod > Loads to match it.' : 'No load request for this amount yet.'}` })));
  return Response.json({ saved: true, id: row.id, amount, provider });
});
