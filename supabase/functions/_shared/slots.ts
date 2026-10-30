// Squad slot numbers for room-code alerts. Rule: squads sit in the seat matching their slot
// in the app. Slot = position among the tournament's active squads (confirmed/approved) by
// slot_key (registration time, or an admin's swap - slot_swap.sql) — same order as my_tournament_slots() (the ticket) and the mod panel.

/** player_id -> slot number for one tournament. */
export async function slotMap(db: any, slug: string): Promise<Map<string, number>> {
  const { data } = await db.from('registrations').select('player_id')
    .eq('tournament_slug', slug).in('status', ['confirmed', 'approved']).order('slot_key', { ascending: true });
  const m = new Map<string, number>();
  (data || []).forEach((r: any, i: number) => { if (!m.has(r.player_id)) m.set(r.player_id, i + 1); });
  return m;
}

/** The line added to a room-code alert. */
export function slotLine(slot?: number): string {
  return slot ? `Your slot: #${slot} — sit in seat ${slot}. Enter the room within 10 minutes.` : 'Enter the room within 10 minutes.';
}
