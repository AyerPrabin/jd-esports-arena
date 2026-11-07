// Runs every 10 minutes (event_modes_groups.sql). Two hours before an event with room for more teams than one
// Free Fire room holds: over one room, it draws groups and stages; otherwise it closes the event at one room,
// so a late joiner can't make it unplayable. Guarded by CRON_SECRET: it moves real registrations.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { DRAW_BEFORE_MS, drawEvent, modeOf, ROOM } from '../_shared/stages.ts';

Deno.serve(async (req: Request) => {
  const SECRET = Deno.env.get('CRON_SECRET');
  if (!SECRET || req.headers.get('x-cron-secret') !== SECRET) return new Response('Unauthorized', { status: 401 });
  const URL_ = Deno.env.get('SUPABASE_URL')!, SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, ADMIN_SECRET = Deno.env.get('ADMIN_SECRET')!;
  const admin = createClient(URL_, SERVICE);
  const publish = async (doc: any) => {
    const r = await fetch(`${URL_}/functions/v1/publish-tournaments`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-admin-secret': ADMIN_SECRET,
      'Authorization': `Bearer ${SERVICE}`, 'apikey': SERVICE }, body: JSON.stringify({ content: JSON.stringify(doc, null, 2) }) });
    return r.ok ? null : await r.text();
  };
  const out: any[] = [];
  const load = async () => (await admin.from('site_content').select('content').eq('key', 'tournaments').maybeSingle()).data?.content as any;
  const first = await load();
  const due = (first?.tournaments || []).filter((t: any) => { const ms = Date.parse(t.start);
    return !t.parent && !t.mega && !t.winner && String(t.status || 'upcoming').toLowerCase() === 'upcoming' && +t.slots > ROOM[modeOf(t)] &&
      Number.isFinite(ms) && ms - Date.now() <= DRAW_BEFORE_MS; }).map((t: any) => t.name);
  for (const name of due) {
    try {
      const doc = await load(), t = doc?.tournaments?.find((x: any) => x.name === name);   // fresh copy: each publish rewrites the whole list
      if (!t) continue;
      const { count, error } = await admin.from('registrations').select('id', { count: 'exact', head: true }).eq('tournament_slug', name).in('status', ['confirmed', 'approved']);
      if (error) throw new Error(error.message);
      const cap = ROOM[modeOf(t)];
      if ((count || 0) > cap) {
        const tag = (s: string) => (t.host ? `[@${String(t.host).replace(/^@+/, '')}] ${s}` : `[JD] ${s}`);
        out.push({ name, drawn: await drawEvent(admin, doc, t, publish, tag) });
      } else {
        t.slots = cap; doc._published_at = new Date().toISOString();
        const bad = await publish(doc);
        if (bad) throw new Error(bad);
        out.push({ name, kept_one_room: count || 0 });
      }
      await admin.from('mod_actions').insert({ mod_email: 'groups-auto', action: 'groups_draw', detail: JSON.stringify(out[out.length - 1]).slice(0, 500) });
    } catch (e) {
      const msg = String((e as Error).message || e);
      console.error('groups-auto', name, msg);
      // tell the owner: an event over one room can't be played until this is sorted
      const { data: o } = await admin.from('players').select('id').ilike('email', 'ayerprabin95@gmail.com').limit(1).maybeSingle();
      const { count: told } = await admin.from('notifications').select('id', { count: 'exact', head: true }).eq('tournament_slug', name).like('title', '⚠️ Groups not drawn%');
      if (o && !told) await admin.from('notifications').insert({ player_id: (o as any).id, push: true, tournament_slug: name, title: `⚠️ Groups not drawn: ${name}`.slice(0, 120), body: msg.slice(0, 300) });
      out.push({ name, error: msg });
    }
  }
  return new Response(JSON.stringify({ ok: true, out }), { headers: { 'Content-Type': 'application/json' } });
});
