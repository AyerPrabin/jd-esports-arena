// Invoked hourly by a pg_cron job (see the migration that adds the cron.schedule
// entry — hourly is plenty of margin for a 3-day deadline, unlike the 5-minute
// tournament-reminders tick which chases minute-scale windows).
//
// Purpose: a player who signs up but never clicks the Supabase confirmation
// email (mailer down, rate-limited, spam-filtered, typo'd address, etc.) can
// otherwise sit forever in an unverified state while still holding a squad's
// registration slot. This sweep finds accounts that are still unverified
// 3+ days after creation and releases any pending/confirmed registration they
// hold, so the slot can flow to the waitlist via the existing
// promote_from_waitlist() trigger (schema.sql) — it fires on any UPDATE that
// moves a registrations row out of pending/confirmed, no changes needed here.
//
// Registrations are moved to 'rejected', not deleted — same terminal status
// the admin payment-review flow already uses, so this stays reversible/auditable
// and doesn't need its own dedup marker: once a player's registrations are
// rejected, the next tick simply finds nothing left to do for them.
//
// Scoped to pending/confirmed only — an 'approved' registration means an admin
// already reviewed and accepted a payment screenshot, so email-verification
// status shouldn't retroactively undo that.
//
// Guarded by CRON_SECRET since pg_net's call isn't a logged-in admin — this
// function cancels real registrations, it must not be publicly triggerable.
import { createClient } from 'npm:@supabase/supabase-js@2';

const VERIFY_DEADLINE_MS = 3 * 24 * 60 * 60 * 1000; // 3 days

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-cron-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  const CRON_SECRET = Deno.env.get('CRON_SECRET');
  if (!CRON_SECRET || req.headers.get('x-cron-secret') !== CRON_SECRET) {
    return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const resendKey = Deno.env.get('RESEND_API_KEY');
  const resendFrom = Deno.env.get('RESEND_FROM') || 'JD Arena <onboarding@resend.dev>';
  const cutoff = Date.now() - VERIFY_DEADLINE_MS;

  // auth.users isn't reachable via supabase-js .from(), so page through
  // admin.listUsers() to find accounts still unverified past the deadline.
  // Capped at 20 pages (4000 users) — well beyond this project's scale, and
  // keeps a runaway loop impossible if listUsers ever misbehaves.
  const staleUnverifiedIds: string[] = [];
  for (let page = 1; page <= 20; page++) {
    const { data, error } = await supabase.auth.admin.listUsers({ page, perPage: 200 });
    if (error || !data?.users?.length) break;
    for (const u of data.users) {
      if (!u.email_confirmed_at && Date.parse(u.created_at) < cutoff) staleUnverifiedIds.push(u.id);
    }
    if (data.users.length < 200) break; // last page
  }

  let cancelled = 0;
  const affectedPlayers: string[] = [];
  for (const playerId of staleUnverifiedIds) {
    const { data: rejected, error } = await supabase
      .from('registrations')
      .update({ status: 'rejected' })
      .eq('player_id', playerId)
      .in('status', ['pending', 'confirmed'])
      .select('id, tournament_slug, players(email, username)');
    if (error || !rejected || !rejected.length) continue;

    affectedPlayers.push(playerId);
    for (const reg of rejected as any[]) {
      cancelled++;
      const title = `Registration removed: ${reg.tournament_slug}`;
      const body = "Your account email was never verified within 3 days of signing up, so your squad's registration was released back to the waitlist. Verify your email and re-register any time.";
      await supabase.from('notifications').insert({ player_id: playerId, tournament_slug: reg.tournament_slug, title, body });
      if (!resendKey || !reg.players?.email) continue;
      try {
        await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ from: resendFrom, to: reg.players.email, subject: title, html: `<p>${body}</p>` }),
        });
      } catch {
        // one player's email failing shouldn't block the rest
      }
    }
  }

  return new Response(
    JSON.stringify({ staleUnverified: staleUnverifiedIds.length, affectedPlayers: affectedPlayers.length, cancelled }),
    { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } },
  );
});
