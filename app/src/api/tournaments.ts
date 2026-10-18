import { from, run } from './client';
import type { TournamentsDoc, Bo3, Standing } from './types';

// The live tournaments doc is the DB copy (site_content, key='tournaments'),
// which the admin publish keeps fresh — same source the old site reads first.
export async function getTournamentsDoc(): Promise<TournamentsDoc> {
  const rows = await run<{ content: TournamentsDoc }[]>(
    from('site_content').select('content').eq('key', 'tournaments').limit(1),
  );
  return rows[0]?.content ?? { tournaments: [] };
}

// Best-of-3 standings math (mirrors the old bo3Standings): total = sum of each round's pts,
// ranked by points then kills then name. Kept in the API layer so every view agrees.
export function standingsFromBo3(bo3: Bo3 | undefined): Standing[] {
  const teams = bo3?.teams ?? [];
  return teams
    .map((t) => ({
      team: t.team,
      totalPts: (t.r ?? []).reduce((a, x) => a + (Number(x?.pts) || 0), 0),
      kills: (t.r ?? []).reduce((a, x) => a + (Number(x?.kills) || 0), 0),
    }))
    .sort((a, b) => b.totalPts - a.totalPts || b.kills - a.kills || a.team.localeCompare(b.team))
    .map((t, i) => ({ rank: i + 1, ...t }));
}
