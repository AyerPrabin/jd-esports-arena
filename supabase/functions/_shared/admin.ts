// Admin auth for the x-admin-secret header (21 Nov 2026).
// Accepts the master ADMIN_SECRET (server-to-server calls, hand-typed passcode) or a short-lived admin token
// "jda1.<email b64url>.<exp ms>.<hmac>" that admin-google-login gives a verified Google admin. The browser keeps
// only the token, so a stolen copy dies within TOKEN_MS; rotating ADMIN_SECRET kills every token at once.
const enc = new TextEncoder();
export const TOKEN_MS = 12 * 3600e3;

function same(a: string, b: string): boolean {   // constant time
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
const b64u = (u: Uint8Array) => btoa(String.fromCharCode(...u)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

async function sign(secret: string, msg: string): Promise<string> {
  const k = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64u(new Uint8Array(await crypto.subtle.sign('HMAC', k, enc.encode(msg))));
}

export async function adminToken(email: string, secret = Deno.env.get('ADMIN_SECRET') || '', now = Date.now()) {
  const exp = now + TOKEN_MS;
  const body = `jda1.${b64u(enc.encode(email.toLowerCase()))}.${exp}`;
  return { token: `${body}.${await sign('admin-token:' + secret, body)}`, exp };
}

// allowed: when given, the token's email must still be on the list (removing an admin works at once)
export async function isAdminValue(v: string | null, secret = Deno.env.get('ADMIN_SECRET') || '',
                                   allowed?: string[], now = Date.now()): Promise<boolean> {
  if (!secret || !v) return false;
  if (same(v, secret)) return true;
  const m = /^(jda1\.([A-Za-z0-9_-]+)\.(\d{13}))\.([A-Za-z0-9_-]{43})$/.exec(v);
  if (!m || Number(m[3]) < now || Number(m[3]) > now + TOKEN_MS + 60e3) return false;
  if (!same(m[4], await sign('admin-token:' + secret, m[1]))) return false;
  if (allowed) {
    const email = atob(m[2].replace(/-/g, '+').replace(/_/g, '/'));
    if (!allowed.includes(email)) return false;
  }
  return true;
}

// owner + ADMIN_EMAILS (comma list, a function secret). Until ADMIN_EMAILS is set, the second admin the owner
// approved on 14 Nov stays allowed. Set it and this fallback can be deleted.
export function adminEmails(): string[] {
  const owner = (Deno.env.get('ADMIN_EMAIL') || 'ayerprabin95@gmail.com').toLowerCase();
  const extra = Deno.env.get('ADMIN_EMAILS');
  return [owner, ...(extra === undefined ? ['saudmahesh059saudmahesh059@gmail.com']
    : extra.split(',').map((s) => s.trim().toLowerCase()).filter(Boolean))];
}

export const isAdmin = (req: Request) => isAdminValue(req.headers.get('x-admin-secret'), undefined, adminEmails());
