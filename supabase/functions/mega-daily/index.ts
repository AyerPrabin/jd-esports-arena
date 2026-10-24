// Daily MEGA progress push (mega.sql, cron 'mega-daily' at 7 PM Nepal). For the open mega event: one in-app alert
// + phone push to every player who hasn't paid their entry yet - "842 / 1,500 squads in, Rs 3,00,000" - with a
// line for squads who joined: invite friends. Players switch it off in Alert settings ('mega' category).
// Once per day per event (mega_daily_log), so a retried cron call never doubles it.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { sendPush } from '../_shared/push.ts';

const npr = (n: number) => 'Rs ' + n.toLocaleString('en-IN');

Deno.serve(async (req: Request) => {
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) return new Response('Unauthorized', { status: 401 });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: m } = await db.rpc('mega_info', { p_slug: null });
  if (!m?.slug || m.status !== 'open') return Response.json({ sent: 0, note: 'no open mega' });
  const day = new Date(Date.now() + 5.75 * 3600e3).toISOString().slice(0, 10);   // Nepal date
  const { error: dupe } = await db.from('mega_daily_log').insert({ slug: m.slug, day });
  if (dupe) return Response.json({ sent: 0, note: 'already sent today' });

  const left = Math.max(0, m.max - m.squads);
  const headline = m.headline || `MEGA is coming in the next few months`;
  const outTitle = `🏆 ${m.slug}: ${m.squads.toLocaleString('en-IN')} / ${m.max.toLocaleString('en-IN')} squads in`;
  const outBody = `${headline}. ${npr(m.prize_pool)} prize pool, ${m.entry} points entry, ${left.toLocaleString('en-IN')} slots left. ` +
    `If ${m.min.toLocaleString('en-IN')} squads don't join, everyone gets a full refund. Join and share your invite link.`;
  const inTitle = `🏆 ${m.slug}: ${m.squads.toLocaleString('en-IN')} / ${m.max.toLocaleString('en-IN')} squads`;
  const inBody = `Your squad is in. Help it fill: share your invite link from jdesport.co.uk/mega - you get points for every squad that joins with it.`;

  // everyone, split into "paid in" and "not yet"
  const inIds = new Set<string>();
  for (let from = 0; ; from += 1000) {
    const { data } = await db.from('registrations').select('player_id').eq('tournament_slug', m.slug)
      .in('status', ['confirmed', 'approved']).gt('paid_points', 0).range(from, from + 999);
    (data || []).forEach((r: any) => inIds.add(r.player_id));
    if (!data || data.length < 1000) break;
  }
  const all: string[] = [];
  for (let from = 0; ; from += 1000) {
    const { data } = await db.from('players').select('id').range(from, from + 999);
    (data || []).forEach((p: any) => all.push(p.id));
    if (!data || data.length < 1000) break;
  }
  const out = all.filter((id) => !inIds.has(id)), ins = [...inIds];
  for (const [ids, title, body] of [[out, outTitle, outBody], [ins, inTitle, inBody]] as [string[], string, string][]) {
    for (let i = 0; i < ids.length; i += 500) {
      await db.from('notifications').insert(ids.slice(i, i + 500).map((pid) => ({ player_id: pid, tournament_slug: m.slug, title, body, push: false })));
    }
  }
  const pushed = await sendPush(db, out, { title: outTitle, body: outBody, url: 'https://jdesport.co.uk/mega/', tag: 'jd-mega', category: 'mega' })
    + await sendPush(db, ins, { title: inTitle, body: inBody, url: 'https://jdesport.co.uk/mega/', tag: 'jd-mega', category: 'mega' });
  return Response.json({ slug: m.slug, not_in: out.length, in: ins.length, pushed });
});
