// Admin-only: releases a Room ID/password to a set of players — either the
// list the admin explicitly picked/edited in jd-admin-970f8094.html's Room Codes panel
// (payload.player_tags), or everyone self-registered for a tournament if no
// list was given. Writes one notifications row per player (so it shows up in
// jd-arena.html's Notification History), pushes a OneSignal alert to their
// device if ONESIGNAL_APP_ID/ONESIGNAL_API_KEY are set, emails them if
// RESEND_API_KEY is set, and DMs them on Discord if they've linked their
// account (zulu_discord.py's !link) and DISCORD_BOT_TOKEN is set.
import { createClient } from 'npm:@supabase/supabase-js@2';

// Browser calls this cross-origin with a custom x-admin-secret header, which makes the
// browser send a CORS preflight OPTIONS request first — without these headers that
// preflight gets rejected (or, pre-this-fix, hit the 405 below) and the real request
// never goes out at all, surfacing to the admin as a plain "Failed to fetch".
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
  const { tournament_slug, room_id, room_pass, player_tags } = payload;
  if (!tournament_slug || !room_id) {
    return new Response('tournament_slug and room_id are required', { status: 400, headers: CORS_HEADERS });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // targets: [{ id, email, player_tag, username, discord_user_id }]
  let targets: any[] = [];
  let unresolved: string[] = [];
  if (Array.isArray(player_tags) && player_tags.length) {
    // Admin can type the auto player_tag (e.g. JD-7F3K2), the player's chosen
    // username, or their account email — check all three columns, no
    // string-built filters (avoids any injection risk from admin-typed input).
    const [byTag, byUser, byEmail] = await Promise.all([
      supabase.from('players').select('id, email, player_tag, username, discord_user_id').in('player_tag', player_tags),
      supabase.from('players').select('id, email, player_tag, username, discord_user_id').in('username', player_tags),
      supabase.from('players').select('id, email, player_tag, username, discord_user_id').in('email', player_tags),
    ]);
    if (byTag.error) return new Response(byTag.error.message, { status: 500, headers: CORS_HEADERS });
    if (byUser.error) return new Response(byUser.error.message, { status: 500, headers: CORS_HEADERS });
    if (byEmail.error) return new Response(byEmail.error.message, { status: 500, headers: CORS_HEADERS });
    const byId = new Map();
    for (const r of [...(byTag.data || []), ...(byUser.data || []), ...(byEmail.data || [])]) byId.set(r.id, r);
    targets = [...byId.values()];
    const found = new Set();
    for (const t of targets) {
      found.add(t.player_tag.toLowerCase());
      if (t.username) found.add(t.username.toLowerCase());
      if (t.email) found.add(t.email.toLowerCase());
    }
    unresolved = player_tags.filter((t: string) => !found.has(String(t).toLowerCase()));
  } else {
    const { data: regs, error: regErr } = await supabase
      .from('registrations')
      .select('player_id, players(email, player_tag, username, discord_user_id)')
      .eq('tournament_slug', tournament_slug)
      .in('status', ['confirmed', 'approved']); // skip unverified-payment registrations by default
    if (regErr) return new Response(regErr.message, { status: 500, headers: CORS_HEADERS });
    targets = (regs || [])
      .filter((r: any) => r.players)
      .map((r: any) => ({ id: r.player_id, email: r.players.email, player_tag: r.players.player_tag, username: r.players.username, discord_user_id: r.players.discord_user_id }));
  }

  if (!targets.length) {
    return new Response(
      JSON.stringify({ sent: 0, emailed: 0, pushed: 0, unresolved, note: 'No matching players to notify.' }),
      { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } },
    );
  }

  const title = `Room code: ${tournament_slug}`;
  const body = "Your match is about to start. Don't share this with anyone outside your squad.";

  const rows = targets.map((t) => ({
    player_id: t.id,
    tournament_slug,
    title,
    body,
    room_id,
    room_pass: room_pass || null,
  }));
  const { error: insErr } = await supabase.from('notifications').insert(rows);
  if (insErr) return new Response(insErr.message, { status: 500, headers: CORS_HEADERS });

  // ── email (Resend) ──
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
            html: `<p>${body}</p><p><b>Room ID:</b> ${room_id}${room_pass ? `<br><b>Password:</b> ${room_pass}` : ''}</p><p style="color:#888;font-size:12px">Player ID: ${t.player_tag || ''}</p>`,
          }),
        });
        if (res.ok) emailed++;
      } catch {
        // one player's email failing shouldn't block the rest
      }
    }
  }

  // ── push (OneSignal) — external_id was set client-side via OneSignal.login(player.id) ──
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
          contents: { en: `Room ID: ${room_id}${room_pass ? ' · Pass: ' + room_pass : ''}` },
        }),
      });
      if (res.ok) pushed = targets.length;
    } catch {
      // push failing shouldn't block email/in-app delivery, which already happened above
    }
  }

  // ── Discord DM — a direct call to Discord's bot REST API using the same bot token as
  // zulu_discord.py; the Python bot process doesn't need to be running for this to work.
  // Only players who ran !link on the bot have a discord_user_id set. ──
  let discorded = 0;
  const discordBotToken = Deno.env.get('DISCORD_BOT_TOKEN');
  if (discordBotToken) {
    const dmText = `**Room code: ${tournament_slug}**\nRoom ID: ${room_id}${room_pass ? `\nPassword: ${room_pass}` : ''}\nDon't share this with anyone outside your squad.`;
    for (const t of targets) {
      if (!t.discord_user_id) continue;
      try {
        if (await sendDiscordDM(discordBotToken, t.discord_user_id, dmText)) discorded++;
      } catch {
        // one player's DM failing (blocked DMs, left the server, etc.) shouldn't block the rest
      }
    }
  }

  // Mark any staged auto-release row as already sent, so tournament-reminders'
  // T-minus-5-minutes sweep doesn't send this code again just because the admin
  // beat it to the punch with a manual send.
  try {
    await supabase
      .from('tournament_room_codes')
      .upsert(
        { tournament_slug, room_id, room_pass: room_pass || null, sent_at: new Date().toISOString() },
        { onConflict: 'tournament_slug' },
      );
  } catch {
    // best-effort — the code already went out above, this just prevents a future double-send
  }

  return new Response(JSON.stringify({ sent: targets.length, emailed, pushed, discorded, unresolved }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
