// Admin-only: notifies everyone self-registered (in-app) for a tournament that its
// Best-of-3 results are up, with a link to the results section on the live site.
// Mirrors send-room-code's targeting — reads the `registrations` table, NOT the
// `teams` roster in tournaments.json (those are two separate, unsynced lists; see
// SUPABASE_SETUP.md's "Known gap"). Only reaches players who registered in-app.
//
// This does not touch tournaments.json — publishing the results themselves is still
// the "Generate JSON, then Publish to GitHub" flow in jd-admin-970f8094.html. Run this only
// after that publish is live, otherwise the link this sends points at a stale board.
import { createClient } from 'npm:@supabase/supabase-js@2';

const SITE_URL = 'https://jdesport.co.uk';

// Browser calls this cross-origin with a custom x-admin-secret header, which makes the
// browser send a CORS preflight OPTIONS request first — without these headers that
// preflight gets rejected and the real request never goes out, surfacing to the admin
// as a plain "Failed to fetch".
const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-admin-secret, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

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

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
  }
  const ADMIN_SECRET = Deno.env.get('ADMIN_SECRET');
  if (!ADMIN_SECRET || req.headers.get('x-admin-secret') !== ADMIN_SECRET) {
    return new Response('Unauthorized', { status: 401, headers: CORS_HEADERS });
  }

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return new Response('Bad JSON', { status: 400, headers: CORS_HEADERS });
  }
  const { tournament_slug } = payload;
  if (!tournament_slug) {
    return new Response('tournament_slug is required', { status: 400, headers: CORS_HEADERS });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  const { data: regs, error: regErr } = await supabase
    .from('registrations')
    .select('player_id, players(email, player_tag, username, discord_user_id)')
    .eq('tournament_slug', tournament_slug)
    .in('status', ['confirmed', 'approved']); // skip unverified-payment registrations
  if (regErr) return new Response(regErr.message, { status: 500, headers: CORS_HEADERS });
  const targets = (regs || [])
    .filter((r: any) => r.players)
    .map((r: any) => ({ id: r.player_id, email: r.players.email, player_tag: r.players.player_tag, username: r.players.username, discord_user_id: r.players.discord_user_id }));

  if (!targets.length) {
    return new Response(
      JSON.stringify({ sent: 0, emailed: 0, pushed: 0, note: 'No self-registered players for this tournament.' }),
      { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } },
    );
  }

  const title = `Results are in: ${tournament_slug}`;
  const body = 'See how your squad placed on the leaderboard.';
  const resultsUrl = `${SITE_URL}/#bo3board`;

  const rows = targets.map((t) => ({ player_id: t.id, tournament_slug, title, body }));
  const { error: insErr } = await supabase.from('notifications').insert(rows);
  if (insErr) return new Response(insErr.message, { status: 500, headers: CORS_HEADERS });

  // ── email (Resend, optional — same domain-verification caveat as everywhere else) ──
  let emailed = 0;
  const resendKey = Deno.env.get('RESEND_API_KEY');
  if (resendKey) {
    const from = Deno.env.get('RESEND_FROM') || 'JD Arena <onboarding@resend.dev>';
    for (const t of targets) {
      if (!t.email) continue;
      try {
        const res = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            from,
            to: t.email,
            subject: title,
            html: `<p>${body}</p><p><a href="${resultsUrl}">View the leaderboard</a></p>`,
          }),
        });
        if (res.ok) emailed++;
      } catch {
        // one player's email failing shouldn't block the rest
      }
    }
  }

  // ── push (OneSignal) — url opens the results section when the player taps the alert ──
  let pushed = 0;
  const oneSignalAppId = Deno.env.get('ONESIGNAL_APP_ID');
  const oneSignalApiKey = Deno.env.get('ONESIGNAL_API_KEY');
  if (oneSignalAppId && oneSignalApiKey) {
    try {
      const res = await fetch('https://api.onesignal.com/notifications', {
        method: 'POST',
        headers: { Authorization: `Key ${oneSignalApiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({
          app_id: oneSignalAppId,
          target_channel: 'push',
          include_aliases: { external_id: targets.map((t) => t.id) },
          headings: { en: title },
          contents: { en: body },
          url: resultsUrl,
        }),
      });
      if (res.ok) pushed = targets.length;
    } catch {
      // push failing shouldn't block email/in-app delivery, which already happened above
    }
  }

  // ── Discord DM — only players who ran !link on the bot have a discord_user_id set ──
  let discorded = 0;
  const discordBotToken = Deno.env.get('DISCORD_BOT_TOKEN');
  if (discordBotToken) {
    const dmText = `**${title}**\n${body}\n${resultsUrl}`;
    for (const t of targets) {
      if (!t.discord_user_id) continue;
      try {
        if (await sendDiscordDM(discordBotToken, t.discord_user_id, dmText)) discorded++;
      } catch {
        // one player's DM failing shouldn't block the rest
      }
    }
  }

  return new Response(JSON.stringify({ sent: targets.length, emailed, pushed, discorded }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
