// Professional stages for events bigger than one room: Groups -> (Semi-finals) -> Grand Final.
// Each stage is a real event in tournaments.json, so room codes, seats, rosters and results work as usual.
// The whole prize sits on the Grand Final. Moving a registration keeps its paid points, card and line-up.

export const ROOM: Record<string, number> = { solo: 48, duo: 24, squad: 12 };   // teams one room holds: a room is 48 players
export const modeOf = (t: any) => { const m = String(t?.mode || '').toLowerCase(); return m === 'solo' || m === 'duo' ? m : 'squad'; };
export const DRAW_BEFORE_MS = 2 * 3600000;   // after the 24-hour confirm sweep, with time to tell squads their group

export function planStages(name: string, n: number, mode: string, matches: number) {
  const cap = ROOM[mode] || 12, groups = Math.ceil(n / cap);
  if (groups < 2) throw new Error(`${n} joined, and one room holds ${cap}. No groups needed.`);
  if (groups > 8) throw new Error('That is more than 8 groups. Ask the JD admin.');
  const final = `${name} · Grand Final`, useSemis = groups >= 4;
  const semis = useSemis ? [`${name} · Semi-final 1`, `${name} · Semi-final 2`] : [];
  // the next room's seats shared out, but never a whole group: someone always goes out (13 squads = 7/6, top 5)
  const advance = Math.max(1, Math.min(Math.floor((useSemis ? cap * 2 : cap) / groups), Math.floor(n / groups) - 1));
  const groupNames = Array.from({ length: groups }, (_, i) => `${name} · Group ${'ABCDEFGH'[i]}`);
  const through = advance * groups, gap = matches * 30 * 60000;
  const stages: any[] = groupNames.map((g, i) => ({ name: g, stage: 'group', stage_label: `Group ${'ABCDEFGH'[i]}`, seat: i, offset: i * gap,
    slots: Math.floor(n / groups) + (i < n % groups ? 1 : 0), advance, advance_to: useSemis ? semis : [final] }));
  semis.forEach((s, i) => stages.push({ name: s, stage: 'semi', stage_label: `Semi-final ${i + 1}`, seat: i, offset: (groups + i) * gap,
    slots: Math.ceil(through / 2), advance: Math.floor(cap / 2), advance_to: [final] }));
  stages.push({ name: final, stage: 'final', stage_label: 'Grand Final', seat: 0, offset: (groups + semis.length) * gap,
    slots: useSemis ? Math.floor(cap / 2) * 2 : through, advance: 0, advance_to: [] });
  return { stages, groupNames, cap, advance, useSemis, final };
}

// who goes where next: alternating by rank and group, so semi-finals get an even mix of top and lower squads
export const nextStage = (t: any, rank: number) => (t.advance_to || [])[(rank + (Number(t.seat) || 0)) % ((t.advance_to || []).length || 1)];

// stages that have to finish before this one can start
export const unfinishedBefore = (doc: any, t: any): any[] => !t?.parent ? [] : (doc.tournaments || []).filter((x: any) =>
  x.parent === t.parent && (x.advance_to || []).includes(t.name) && !x.winner && String(x.status || '').toLowerCase() !== 'completed');

const nptWhen = (ms: number) => { const d = new Date(ms + 345 * 60000), h = d.getUTCHours();
  return { date: d.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric', timeZone: 'UTC' }),
    time: `${h % 12 || 12}:${String(d.getUTCMinutes()).padStart(2, '0')} ${h < 12 ? 'AM' : 'PM'} NPT`, start: d.toISOString().slice(0, 19) + '+05:45' }; };

type Publish = (doc: any) => Promise<string | null>;   // returns an error message, or null

// One event into its stages, all or nothing: moves first (one transaction), publish second, moves undone if that fails.
export async function drawEvent(admin: any, doc: any, t: any, publish: Publish, tag: (s: string) => string) {
  const slug = t.name;
  if (t.parent || t.mega || t.winner || ['completed', 'cancelled'].includes(String(t.status || '').toLowerCase())) throw new Error("This event can't be drawn.");
  const { data: codes } = await admin.from('tournament_room_codes').select('tournament_slug').eq('tournament_slug', slug).not('sent_at', 'is', null).limit(1);
  if (codes?.length) throw new Error('The room code is already out, so this event plays as one room.');
  const { data: regs, error } = await admin.from('registrations').select('id, player_id, squad_name').eq('tournament_slug', slug).in('status', ['confirmed', 'approved']);
  if (error) throw new Error(error.message);
  const list = [...(regs || [])], matches = Math.min(6, Math.max(1, Number(String(t.format || '').match(/(\d+)\s*match/i)?.[1] || 3)));
  const plan = planStages(slug, list.length, modeOf(t), matches);
  if (doc.tournaments.some((x: any) => plan.stages.some((s) => s.name === x.name))) throw new Error('These stages already exist.');
  for (let i = list.length - 1; i > 0; i--) {   // a fair shuffle: nobody picks their group
    const j = crypto.getRandomValues(new Uint32Array(1))[0] % (i + 1); [list[i], list[j]] = [list[j], list[i]];
  }
  const moves = list.map((r: any, i: number) => ({ id: r.id, from: slug, to: plan.groupNames[i % plan.groupNames.length] }));
  const at0 = Math.max(Date.parse(t.start) || 0, Date.now() + 30 * 60000);
  const base: any = { ...t }; delete base.teams; delete base.winner;
  const events = plan.stages.map((s) => ({ ...base, ...nptWhen(at0 + s.offset), ...s, offset: undefined, parent: slug, status: 'upcoming', winner: '', teams: [],
    prize: s.stage === 'final' ? t.prize : '' }));
  events.forEach((e: any) => delete e.offset);
  const { error: mv } = await admin.rpc('event_draw_apply', { p_moves: moves, p_stages: events.map((e) => e.name) });
  if (mv) throw new Error('Nothing was moved: ' + mv.message);
  doc.tournaments.splice(doc.tournaments.indexOf(t), 1, ...events);
  doc._published_at = new Date().toISOString();
  const bad = await publish(doc);
  if (bad) {
    await admin.rpc('event_draw_apply', { p_moves: moves.map((m) => ({ id: m.id, from: m.to, to: m.from })), p_stages: [] });
    throw new Error('Could not publish, so nothing changed: ' + bad);
  }
  await admin.rpc('event_end_waitlist', { p_slug: slug });   // no seat left to wait for: deposits back, tickets closed
  const byName = new Map(events.map((e: any) => [e.name, e]));
  const nextLabel = plan.useSemis ? 'Semi-finals' : 'Grand Final';
  await admin.from('notifications').insert(moves.map((m) => { const r: any = list.find((x: any) => x.id === m.id), e: any = byName.get(m.to);
    return { player_id: r.player_id, push: true, tournament_slug: m.to, title: tag(`🎲 ${r.squad_name}: ${e.stage_label}`).slice(0, 120),
      body: `${slug} is drawn. You play ${e.date} ${e.time}. The top ${plan.advance} reach the ${nextLabel}. Nothing more to pay.` }; }));
  return { groups: plan.groupNames.length, advance: plan.advance, semis: plan.useSemis, names: plan.groupNames, final: plan.final, teams: list.length };
}
