// "Update ready" push for the JD Arena Android app (cron every 30 min, app_update_push.sql). Reads the live
// /download/android.json and pushes every app phone whose saved app version (push_fcm_tokens.app_version) is
// older than its versionCode - once per player per version (app_update_pushes). Tapping the notification opens
// /?update=1, where home.js shows the Update now prompt at once; the APK itself downloads from Supabase
// storage (bucket 'app'), because the app claims every jdesport.co.uk link and would open the APK in itself.
//   header: x-cron-secret
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendFcm } from '../_shared/push.ts';

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  let rel: any;
  try { rel = await (await fetch('https://jdesport.co.uk/download/android.json', { cache: 'no-store', signal: AbortSignal.timeout(8000) })).json(); }
  catch (e) { return Response.json({ error: 'android.json: ' + e }, { status: 502 }); }
  const code = Number(rel?.versionCode);
  if (!Number.isFinite(code) || !rel?.url) return Response.json({ error: 'android.json has no versionCode/url' }, { status: 502 });

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: toks } = await db.from('push_fcm_tokens').select('player_id').lt('app_version', code);
  const { data: done } = await db.from('app_update_pushes').select('player_id').eq('version_code', code);
  const sent = new Set((done || []).map((r: any) => r.player_id));
  const ids = [...new Set((toks || []).map((r: any) => r.player_id))].filter((id) => !sent.has(id));
  if (!ids.length) return Response.json({ version: code, pushed: 0 });

  const ok = await sendFcm(db, ids, {
    title: '⬇ JD Arena ' + (rel.versionName || 'update') + ' is ready',
    body: (rel.notes ? String(rel.notes).slice(0, 120) + ' ' : '') + 'Tap to update - your account stays.',
    url: 'https://jdesport.co.uk/?update=1',
    tag: 'jd-app-update',
  });
  await db.from('app_update_pushes').upsert(ids.map((player_id) => ({ player_id, version_code: code })), { onConflict: 'player_id,version_code' });
  return Response.json({ version: code, players: ids.length, devices: ok });
});
