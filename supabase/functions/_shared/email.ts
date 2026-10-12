// Unsubscribe support for the optional emails (24h reminder, results, announcements).
// Each link carries the player id and an HMAC of it, so it works without logging in
// (email-unsubscribe verifies it). Service emails (room codes, check-in and forfeit
// notices, account emails) don't check players.email_opt_out and have no link.
const SITE = 'https://jdesport.co.uk';
const FN_URL = `${Deno.env.get('SUPABASE_URL')}/functions/v1/email-unsubscribe`;

async function hmac(text: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode('unsub:' + text));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('').slice(0, 32);
}

export async function unsubToken(playerId: string): Promise<string> {
  return hmac(playerId);
}

export async function unsubUrl(playerId: string): Promise<string> {
  return `${FN_URL}?p=${encodeURIComponent(playerId)}&t=${await unsubToken(playerId)}`;
}

// Footer HTML + headers for an optional email. Spread `headers` into the Resend body.
export async function optionalEmailExtras(playerId: string) {
  const url = await unsubUrl(playerId);
  return {
    footer: `<hr style="border:none;border-top:1px solid #ddd;margin:20px 0 10px"><p style="font-size:12px;color:#777">JD Esports Arena · Prabin Ayer (AyerFire). You get this because you have a JD Arena account. <a href="${url}">Unsubscribe from these emails</a> · <a href="${SITE}/privacy/">Privacy policy</a></p>`,
    headers: { 'List-Unsubscribe': `<${url}>`, 'List-Unsubscribe-Post': 'List-Unsubscribe=One-Click' },
  };
}
