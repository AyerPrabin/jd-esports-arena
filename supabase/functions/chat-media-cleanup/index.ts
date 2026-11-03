// Daily (cron, chat_media_v2.sql): deletes chat photos/videos 30 days after upload, and files that were
// uploaded but never sent after 1 day, through the Storage API so the files themselves go, then marks
// those messages "deleted after 30 days".
//   header: x-cron-secret
import { createClient } from 'npm:@supabase/supabase-js@2';

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  let removed = 0, forgotten = 0;
  for (let round = 0; round < 10; round++) {
    const { data, error } = await db.rpc('chat_media_expired', { p_limit: 500 });
    if (error) return Response.json({ error: error.message, removed }, { status: 500 });
    const names = ((data || []) as unknown[]).map(String);
    if (!names.length) break;
    for (let i = 0; i < names.length; i += 100) {
      const part = names.slice(i, i + 100);
      const rm = await db.storage.from('chat-media').remove(part);
      if (rm.error) return Response.json({ error: rm.error.message, removed }, { status: 500 });
      removed += part.length;
      const f = await db.rpc('chat_media_forget', { p_names: part });
      forgotten += Number(f.data) || 0;
    }
  }
  return Response.json({ removed, forgotten });
});
