// Admin-only: swaps the slot numbers of two squads in the same tournament (the "⇄ Swap slot" button in the
// admin panel's Registered Teams list). slot_swap.sql admin_swap_slots() swaps their slot keys, so every other
// squad keeps its slot; the homepage roster, tickets, reminders and room-code alerts all follow at once.
// Both squads get an in-app notification with their new slot. If the room code already went out, the admin
// is told (the alert they got still shows the old seat).
//   body: { a: registration_id, b: registration_id }   header: x-admin-secret
import { createClient } from 'npm:@supabase/supabase-js@2';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET');
  if (!ADMIN_SECRET || req.headers.get('x-admin-secret') !== ADMIN_SECRET) {
    return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  }
  let payload: any;
  try { payload = await req.json(); } catch { return new Response('Bad JSON', { status: 400, headers: CORS_HEADERS }); }
  const { a, b } = payload || {};
  if (!a || !b) return new Response('a and b (registration ids) are required', { status: 400, headers: CORS_HEADERS });

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: regs } = await supabase.from('registrations').select('id, player_id, tournament_slug, squad_name').in('id', [a, b]);
  const { data, error } = await supabase.rpc('admin_swap_slots', { p_a: a, p_b: b });
  if (error) return new Response(error.message, { status: 400, headers: CORS_HEADERS });
  const row = Array.isArray(data) ? data[0] : data;
  const slots: Record<string, number | null> = { [a]: row?.a_slot ?? null, [b]: row?.b_slot ?? null };

  // best-effort: the swap already happened
  const notes = (regs || []).filter((r: any) => slots[r.id]).map((r: any) => ({
    player_id: r.player_id,
    tournament_slug: r.tournament_slug,
    title: '🔁 Your slot changed: #' + slots[r.id],
    body: (r.squad_name ? 'Your squad "' + r.squad_name + '"' : 'Your squad') + ' is now in slot #' + slots[r.id] +
      ' for ' + r.tournament_slug + ' (changed by the organiser). Sit in seat ' + slots[r.id] + ' when you enter the room.',
  }));
  if (notes.length) await supabase.from('notifications').insert(notes);

  const slug = regs?.[0]?.tournament_slug;
  const { data: rc } = slug ? await supabase.from('tournament_room_codes').select('sent_at').eq('tournament_slug', slug).maybeSingle() : { data: null };
  return new Response(JSON.stringify({ ok: true, a_slot: slots[a], b_slot: slots[b], room_code_was_sent: !!rc?.sent_at }), {
    status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
