// New-video alert (cron every 10 min, video_alerts.sql). TikTok's public embed page lists @ayer_fire's recent videos.
// Video ids grow over time, so an id above the last one seen is a new post: every player gets an alert that opens it.
// The first run only saves the newest id. A blocked or changed page only logs last_error and pushes nothing.
//   header: x-cron-secret
import { createClient } from 'npm:@supabase/supabase-js@2';

const HANDLE = 'ayer_fire';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';

async function newestVideo(): Promise<bigint> {
  const res = await fetch(`https://www.tiktok.com/embed/@${HANDLE}`, { headers: { 'user-agent': UA, 'accept-language': 'en' }, signal: AbortSignal.timeout(12000) });
  const html = await res.text();
  const ids = [...html.matchAll(new RegExp(`@${HANDLE}/video/(\\d{15,25})`, 'g'))].map((m) => BigInt(m[1]));
  if (!res.ok || !ids.length) throw new Error(`no videos on the page (HTTP ${res.status})`);
  return ids.reduce((a, b) => (b > a ? b : a));
}

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const checked_at = new Date().toISOString();
  let newest: bigint;
  try { newest = await newestVideo(); }
  catch (e) {
    await db.from('tiktok_watch').upsert({ id: 1, checked_at, last_error: String(e).slice(0, 200) });
    return Response.json({ error: String(e) });
  }
  const { data: state } = await db.from('tiktok_watch').select('last_video_id').eq('id', 1).maybeSingle();
  const before = state?.last_video_id ? BigInt(state.last_video_id) : null;
  let alerted = 0;
  if (before !== null && newest > before) {
    const { data, error } = await db.rpc('video_new_alert', { p_link: `/watch/?v=${newest}`, p_title: '🎬 New JD video on TikTok', p_body: 'Tap to watch it on TikTok.' });
    if (error) {   // keep the old id so the next run tries again
      await db.from('tiktok_watch').upsert({ id: 1, checked_at, last_error: error.message.slice(0, 200) });
      return Response.json({ error: error.message });
    }
    alerted = data || 0;
  }
  const last_video_id = before !== null && before > newest ? before.toString() : newest.toString();
  await db.from('tiktok_watch').upsert({ id: 1, last_video_id, checked_at, last_error: null });
  return Response.json({ newest: newest.toString(), before: before?.toString() ?? null, alerted });
});
