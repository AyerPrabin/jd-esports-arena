// Invoked every 5 minutes by a pg_cron job (see the migration that sets up
// cron.schedule + net.http_post — 5 minutes, not 15, specifically so the
// room-code release below can land close to its 5-minutes-before-start
// target instead of the ~15-minute window a slower tick would allow).
// Four jobs share this one tick:
//   1. Emails players a reminder 24 hours and 1 hour before a tournament they're
//      registered for starts.
//   2. Nudges confirmed/approved players to check in ~30 minutes before start.
//   3. Sweeps each tournament exactly once, ~10 minutes before start: anyone
//      confirmed/approved who never checked in gets forfeited ('no_show'),
//      which frees their slot — the existing promote_from_waitlist() trigger
//      (schema.sql) picks that up with zero changes here, since it fires on
//      ANY update that moves a row out of confirmed/approved.
//   4. Auto-releases any room code the admin staged via stage-room-code
//      (jd-admin's "💾 Stage for auto-release"), ~5 minutes before start —
//      see ROOM_CODE_RELEASE_MS below.
// Reads ONLY the `registrations` table, so a player who never registered
// in-app gets nothing, ever.
//
// Reminder dedup is a marker row in `notifications` (checked before sending) so
// a cron tick can't double-email someone within the same window.
// Forfeit-sweep dedup is a row in `tournament_checkin_sweeps`: the first tick
// whose insert actually lands runs the sweep for that tournament; every later
// tick sees the unique-key conflict and skips. Without this, a re-forfeit
// re-evaluated every tick would strip-mine the waitlist — the tick that
// forfeits a no-show promotes a waitlisted player straight to 'confirmed' with
// checked_in_at still null, and the check-in window has already closed for
// them, so a markerless sweep would forfeit THEM on the very next tick too,
// cascading through the whole waitlist one casualty per tick.
// Room-code dedup is the `sent_at` column on `tournament_room_codes`: an update
// that only succeeds once (sent_at null -> now()) claims the release, so a race
// between ticks — or the admin beating the timer with a manual send, which also
// sets sent_at — can't double-send.
//
// Guarded by CRON_SECRET since pg_net's call isn't a logged-in admin — this
// function sends real emails, forfeits real registrations, and releases real
// room codes, it must not be publicly triggerable.
import { createClient } from 'npm:@supabase/supabase-js@2';

async function sendDiscordDM(token: string, discordUserId: string, content: string): Promise<boolean> {
  const authHeaders = { Authorization: `Bot ${token}`, 'Content-Type': 'application/json' };
  const chRes = await fetch('https://discord.com/api/v10/users/@me/channels', {
    method: 'POST',
    headers: authHeaders,
    body: JSON.stringify({ recipient_id: discordUserId }),
  });
  if (!chRes.ok) return false;
  const { id: channelId } = await chRes.json();
  const msgRes = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
    method: 'POST',
    headers: authHeaders,
    body: JSON.stringify({ content }),
  });
  return msgRes.ok;
}

const WINDOWS = [
  { key: '24h', ms: 24 * 60 * 60 * 1000, label: '24 hours' },
  { key: '1h', ms: 60 * 60 * 1000, label: '1 hour' },
  { key: 'checkin', ms: 30 * 60 * 1000, label: '30 minutes' },
];
const FORFEIT_CUTOFF_MS = 10 * 60 * 1000; // sweep eligible once a tournament is this close to (or past) start
const ROOM_CODE_RELEASE_MS = 5 * 60 * 1000; // auto-release eligible once a tournament is this close to (or past) start
const TOLERANCE_MS = 6 * 60 * 1000; // slightly wider than the 5-min cron interval so no tick is missed
// Not raw.githubusercontent.com: the repo is private, so that 404s unauthenticated.
// GitHub Pages serves the same file publicly regardless of repo visibility.
const TOURNAMENTS_URL = 'https://jdesport.co.uk/tournaments.json';

// Not called from a browser (pg_cron/pg_net hits this server-to-server), but CORS
// headers are added anyway for consistency with the other Edge Functions here.
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
  // Only DB access is essential here — the check-in nudge and forfeit sweep
  // both work with no email provider configured at all (they still write
  // notifications rows, which is what jd-arena.html's Notification History
  // and the check-in UI actually read). RESEND_API_KEY is checked per-send
  // further down instead of gating the whole function.
  if (!Deno.env.get('SUPABASE_URL') || !Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')) {
    return new Response(
      JSON.stringify({ skipped: 'Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY secrets.' }),
      { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } },
    );
  }

  let tournaments: any[] = [];
  try {
    const r = await fetch(TOURNAMENTS_URL, { cache: 'no-store' });
    if (r.ok) tournaments = (await r.json()).tournaments || [];
  } catch {
    return new Response(JSON.stringify({ skipped: 'Could not fetch tournaments.json' }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const resendKey = Deno.env.get('RESEND_API_KEY');
  const resendFrom = Deno.env.get('RESEND_FROM') || 'JD Arena <onboarding@resend.dev>';
  const now = Date.now();

  // ── 24h / 1h / check-in-nudge reminders ──
  const due: { tournament: any; window: (typeof WINDOWS)[number] }[] = [];
  for (const t of tournaments) {
    if (!t.start || ['completed', 'cancelled'].includes((t.status || '').toLowerCase())) continue;
    const startMs = Date.parse(t.start);
    if (isNaN(startMs)) continue;
    const msUntil = startMs - now;
    for (const w of WINDOWS) {
      if (msUntil <= w.ms && msUntil > w.ms - TOLERANCE_MS) due.push({ tournament: t, window: w });
    }
  }

  let sent = 0;
  for (const { tournament: t, window: w } of due) {
    const isCheckin = w.key === 'checkin';
    let regsQuery = supabase
      .from('registrations')
      .select('player_id, checked_in_at, players(email, username)')
      .eq('tournament_slug', t.name)
      .in('status', ['confirmed', 'approved']); // skip unverified-payment registrations
    const { data: regs, error: regErr } = await regsQuery;
    if (regErr || !regs || !regs.length) continue;

    const title = isCheckin
      ? `Check in now: ${t.name}`
      : `Reminder: ${t.name} starts in ${w.label}`;
    const body = isCheckin
      ? `${t.name} starts in 30 minutes — tap Check In on the tournament card or you may lose your spot to the waitlist.`
      : `${t.name} starts in ${w.label} (${t.date || ''}${t.time ? ' - ' + t.time : ''}). Make sure you're ready.`;

    for (const reg of regs as any[]) {
      if (isCheckin && reg.checked_in_at) continue; // already checked in, nothing to nudge
      if (!reg.players || !reg.players.email) continue;
      const { data: already } = await supabase
        .from('notifications')
        .select('id')
        .eq('player_id', reg.player_id)
        .eq('tournament_slug', t.name)
        .eq('title', title)
        .limit(1);
      if (already && already.length) continue; // already reminded this player for this window

      await supabase.from('notifications').insert({ player_id: reg.player_id, tournament_slug: t.name, title, body });
      if (!resendKey) continue;
      try {
        const res = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ from: resendFrom, to: reg.players.email, subject: title, html: `<p>${body}</p>` }),
        });
        if (res.ok) sent++;
      } catch {
        // one player's email failing shouldn't block the rest — the notifications row is
        // already written, so this won't silently retry into a duplicate on the next tick
      }
    }
  }

  // ── forfeit sweep — exactly once per tournament, see file header ──
  let forfeited = 0;
  const swept: string[] = [];
  for (const t of tournaments) {
    if (!t.start || ['completed', 'cancelled'].includes((t.status || '').toLowerCase())) continue;
    const startMs = Date.parse(t.start);
    if (isNaN(startMs)) continue;
    if (startMs - now > FORFEIT_CUTOFF_MS) continue; // not due yet

    // Claims the sweep for this tournament: only the tick whose insert actually
    // lands (no unique-key conflict) proceeds past this point.
    const { error: markerErr } = await supabase
      .from('tournament_checkin_sweeps')
      .insert({ tournament_slug: t.name });
    if (markerErr) continue; // already swept (or a transient error) — either way, skip

    const { data: forfeitedRegs, error: forfeitErr } = await supabase
      .from('registrations')
      .update({ status: 'no_show' })
      .eq('tournament_slug', t.name)
      .in('status', ['confirmed', 'approved'])
      .is('checked_in_at', null)
      .select('player_id, players(email)');
    if (forfeitErr || !forfeitedRegs) continue;

    swept.push(t.name);
    const title = `Missed check-in: ${t.name}`;
    const body = "You didn't check in in time, so your spot was released.";
    for (const reg of forfeitedRegs as any[]) {
      forfeited++;
      await supabase.from('notifications').insert({ player_id: reg.player_id, tournament_slug: t.name, title, body });
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

  // ── room code auto-release — exactly once per tournament, see file header ──
  const discordBotToken = Deno.env.get('DISCORD_BOT_TOKEN');
  const oneSignalAppId = Deno.env.get('ONESIGNAL_APP_ID');
  const oneSignalApiKey = Deno.env.get('ONESIGNAL_API_KEY');
  let roomCodesSent = 0;
  const roomCodesReleased: string[] = [];
  for (const t of tournaments) {
    if (!t.start || ['completed', 'cancelled'].includes((t.status || '').toLowerCase())) continue;
    const startMs = Date.parse(t.start);
    if (isNaN(startMs)) continue;
    if (startMs - now > ROOM_CODE_RELEASE_MS) continue; // not due yet

    // Claims the release for this tournament: only the tick whose update actually
    // flips a row from sent_at IS NULL proceeds past this point.
    const { data: staged, error: stageErr } = await supabase
      .from('tournament_room_codes')
      .update({ sent_at: new Date().toISOString() })
      .eq('tournament_slug', t.name)
      .is('sent_at', null)
      .select('room_id, room_pass')
      .maybeSingle();
    if (stageErr || !staged) continue; // nothing staged, already sent, or a transient error

    const { data: regs, error: regErr } = await supabase
      .from('registrations')
      .select('player_id, players(email, player_tag, discord_user_id)')
      .eq('tournament_slug', t.name)
      .in('status', ['confirmed', 'approved']); // skip unverified-payment registrations, same as a manual send
    if (regErr || !regs || !regs.length) continue;
    const targets = (regs as any[])
      .filter((r) => r.players)
      .map((r) => ({ id: r.player_id, email: r.players.email, discord_user_id: r.players.discord_user_id }));
    if (!targets.length) continue;

    roomCodesReleased.push(t.name);
    const title = `Room code: ${t.name}`;
    const body = "Your match is about to start. Don't share this with anyone outside your squad.";
    await supabase.from('notifications').insert(
      targets.map((tg) => ({ player_id: tg.id, tournament_slug: t.name, title, body, room_id: staged.room_id, room_pass: staged.room_pass || null })),
    );
    roomCodesSent += targets.length;

    if (resendKey) {
      for (const tg of targets) {
        if (!tg.email) continue;
        try {
          await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({
              from: resendFrom,
              to: tg.email,
              subject: title,
              html: `<p>${body}</p><p><b>Room ID:</b> ${staged.room_id}${staged.room_pass ? `<br><b>Password:</b> ${staged.room_pass}` : ''}</p>`,
            }),
          });
        } catch {
          // one player's email failing shouldn't block the rest
        }
      }
    }

    if (oneSignalAppId && oneSignalApiKey) {
      try {
        await fetch('https://api.onesignal.com/notifications', {
          method: 'POST',
          headers: { Authorization: `Key ${oneSignalApiKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            app_id: oneSignalAppId,
            target_channel: 'push',
            include_aliases: { external_id: targets.map((tg) => tg.id) },
            headings: { en: title },
            contents: { en: `Room ID: ${staged.room_id}${staged.room_pass ? ' · Pass: ' + staged.room_pass : ''}` },
          }),
        });
      } catch {
        // push failing shouldn't block email/in-app delivery, which already happened above
      }
    }

    if (discordBotToken) {
      const dmText = `**Room code: ${t.name}**\nRoom ID: ${staged.room_id}${staged.room_pass ? `\nPassword: ${staged.room_pass}` : ''}\nDon't share this with anyone outside your squad.`;
      for (const tg of targets) {
        if (!tg.discord_user_id) continue;
        try {
          await sendDiscordDM(discordBotToken, tg.discord_user_id, dmText);
        } catch {
          // one player's DM failing shouldn't block the rest
        }
      }
    }
  }

  return new Response(JSON.stringify({ sent, due: due.length, forfeited, swept, roomCodesSent, roomCodesReleased }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
