// Admin-only: sends a free-form announcement — any title/message the admin types,
// not tied to a tournament or a fixed room-code/results template. Reaches either a
// hand-picked list of players (payload.player_tags — same tag/username/email lookup
// as send-room-code) or literally every player on the site if no list is given.
// Writes one notifications row per player (shows up in jd-arena.html's Notification
// History), pushes a OneSignal alert if ONESIGNAL_APP_ID/ONESIGNAL_API_KEY are set,
// emails them if RESEND_API_KEY is set, and DMs them on Discord if they've linked
// their account (zulu_discord.py's !link) and DISCORD_BOT_TOKEN is set.
import { createClient } from 'npm:@supabase/supabase-js@2';

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
  const { title, body, player_tags } = payload;
  if (!title || !body) {
    return new Response('title and body are required', { status: 400, headers: CORS_HEADERS });
  }

  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // targets: [{ id, email, player_tag, username, discord_user_id }]
  let targets: any[] = [];
  let unresolved: string[] = [];
  const broadcast = !Array.isArray(player_tags) || !player_tags.length;
  if (!broadcast) {
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
    const { data: players, error: playersErr } = await supabase
      .from('players')
      .select('id, email, player_tag, username, discord_user_id');
    if (playersErr) return new Response(playersErr.message, { status: 500, headers: CORS_HEADERS });
    targets = players || [];
  }

  if (!targets.length) {
    return new Response(
      JSON.stringify({ sent: 0, emailed: 0, pushed: 0, unresolved, note: 'No matching players to notify.' }),
      { status: 200, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } },
    );
  }

  const rows = targets.map((t) => ({ player_id: t.id, title, body }));
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
          body: JSON.stringify({ from, to: t.email, subject: title, html: `<p>${body}</p>` }),
        });
        if (res.ok) emailed++;
      } catch {
        // one player's email failing shouldn't block the rest
      }
    }
  }

  // ── push (OneSignal) — a true broadcast targets the "Subscribed Users" segment instead
  // of listing every external_id (that's the correct/efficient way to reach literally
  // everyone); a targeted send still lists specific external_ids like send-room-code does ──
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
          ...(broadcast
            ? { included_segments: ['Subscribed Users'] }
            : { include_aliases: { external_id: targets.map((t) => t.id) } }),
          headings: { en: title },
          contents: { en: body },
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
    const dmText = `**${title}**\n${body}`;
    for (const t of targets) {
      if (!t.discord_user_id) continue;
      try {
        if (await sendDiscordDM(discordBotToken, t.discord_user_id, dmText)) discorded++;
      } catch {
        // one player's DM failing (blocked DMs, left the server, etc.) shouldn't block the rest
      }
    }
  }

  return new Response(JSON.stringify({ sent: targets.length, emailed, pushed, discorded, unresolved }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
