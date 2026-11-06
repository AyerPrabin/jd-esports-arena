// New-video alert (cron every 10 min, video_alerts.sql). TikTok's public profile page shows @ayer_fire's video count
// but no video ids, so a higher count pushes every player an alert that opens the profile, newest video first.
// A blocked or changed page only logs last_error and pushes nothing. A jump of more than 5 is treated as a bad read.
//   header: x-cron-secret
import { createClient } from 'npm:@supabase/supabase-js@2';

const HANDLE = 'ayer_fire';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';

async function readCount(): Promise<number> {
  const res = await fetch(`https://www.tiktok.com/@${HANDLE}`, { headers: { 'user-agent': UA, 'accept-language': 'en' }, signal: AbortSignal.timeout(12000) });
  const html = await res.text();
  if (!res.ok || !html.includes(`"uniqueId":"${HANDLE}"`)) throw new Error(`profile not readable (HTTP ${res.status})`);
  const m = html.match(/"videoCount":(\d+)/);
  if (!m) throw new Error('no video count on the page');
  return Number(m[1]);
}

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const checked_at = new Date().toISOString();
  let count: number;
  try { count = await readCount(); }
  catch (e) {
    await db.from('tiktok_watch').upsert({ id: 1, checked_at, last_error: String(e).slice(0, 200) });
    return Response.json({ error: String(e) });
  }
  const { data: state } = await db.from('tiktok_watch').select('video_count').eq('id', 1).maybeSingle();
  const before = state?.video_count ?? null;
  const added = before === null ? 0 : count - before;
  let alerted = 0;
  if (added >= 1 && added <= 5) {
    const { data, error } = await db.rpc('video_new_alert', { p_link: '/watch/', p_title: '🎬 New JD video on TikTok', p_body: 'Tap to watch it on TikTok.' });
    if (error) {   // keep the old count so the next run tries again
      await db.from('tiktok_watch').upsert({ id: 1, checked_at, last_error: error.message.slice(0, 200) });
      return Response.json({ error: error.message });
    }
    alerted = data || 0;
  }
  await db.from('tiktok_watch').upsert({ id: 1, video_count: count, checked_at, last_error: null });
  return Response.json({ count, before, alerted });
});
