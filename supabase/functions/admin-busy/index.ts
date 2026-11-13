// JD Admin app (owner's phone) -> busy time blocks from the phone calendar (admin_busy.sql).
// Only start/end times arrive here: no titles, places or notes. Mods read them via admin_busy_now().
// Auth: header x-pay-token must equal PAYMENT_HOOK_TOKEN (same key the app already uses for payment-in).
import { createClient } from 'npm:@supabase/supabase-js@2';

const same = (a: string, b: string) => {   // constant-time compare
  if (!a || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
};
const HOUR = 3600_000;

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return new Response('POST only', { status: 405 });
  const TOKEN = Deno.env.get('PAYMENT_HOOK_TOKEN') || '';
  if (TOKEN.length < 24 || !same(req.headers.get('x-pay-token') || '', TOKEN)) return new Response('Unauthorized', { status: 401 });

  let j: any;
  try { j = await req.json(); } catch { return new Response('Bad JSON', { status: 400 }); }
  if (!Array.isArray(j?.blocks)) return new Response('blocks[] needed', { status: 400 });

  // keep sane blocks only: start < end, ends after 1 h ago, starts within 48 h, at most 16 h long
  const now = Date.now();
  const blocks = j.blocks
    .map((b: any) => ({ s: Number(b?.s), e: Number(b?.e) }))
    .filter((b: any) => Number.isFinite(b.s) && Number.isFinite(b.e) && b.s < b.e && b.e > now - HOUR && b.s < now + 48 * HOUR && b.e - b.s <= 16 * HOUR)
    .sort((a: any, b: any) => a.s - b.s)
    .slice(0, 40)
    .map((b: any) => ({ s: new Date(b.s).toISOString(), e: new Date(b.e).toISOString() }));

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { error } = await db.from('admin_busy').upsert({ id: 1, blocks, updated_at: new Date().toISOString() });
  if (error) return new Response('Save failed', { status: 500 });
  return Response.json({ ok: true, blocks: blocks.length });
});
