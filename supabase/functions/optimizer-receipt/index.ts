// Public: signs a JD-Optimiers scan receipt. The app sends ONLY the SHA-256 of its scan report (+ app version);
// we return {payload, sig} where payload = {"h":hash,"t":unix seconds,"v":version,"k":1} and sig = ECDSA P-256
// over SHA-256(payload), raw r||s (IEEE P1363 - the format Windows BCryptVerifySignature expects), both
// base64url. The private key (JWK) lives only in the OPTIMIZER_RECEIPT_KEY secret; the app embeds the public key.
//
// What a receipt proves: this exact report text existed at server time t and has not been edited since.
// It does not prove the scan itself was honest (no check running on a player's own PC can).
// No personal data is sent or stored.

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

let keyPromise: Promise<CryptoKey> | null = null;
function signingKey(): Promise<CryptoKey> {
  if (!keyPromise) {
    const raw = Deno.env.get('OPTIMIZER_RECEIPT_KEY');
    if (!raw) throw new Error('OPTIMIZER_RECEIPT_KEY is not set');
    keyPromise = crypto.subtle.importKey('jwk', JSON.parse(raw), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  }
  return keyPromise;
}

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: CORS_HEADERS });
  let body: { h?: unknown; v?: unknown };
  try {
    body = await req.json();
  } catch {
    return new Response('Bad JSON', { status: 400, headers: CORS_HEADERS });
  }
  const h = typeof body.h === 'string' ? body.h.toLowerCase() : '';
  const v = typeof body.v === 'string' ? body.v : '';
  if (!/^[0-9a-f]{64}$/.test(h) || !/^[0-9.]{1,12}$/.test(v)) {
    return new Response('h must be a 64-char hex SHA-256 and v a version', { status: 400, headers: CORS_HEADERS });
  }
  try {
    const payload = JSON.stringify({ h, t: Math.floor(Date.now() / 1000), v, k: 1 });
    const bytes = new TextEncoder().encode(payload);
    const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, await signingKey(), bytes));
    return new Response(JSON.stringify({ payload: b64url(bytes), sig: b64url(sig) }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  } catch (e) {
    return new Response(e instanceof Error ? e.message : String(e), { status: 500, headers: CORS_HEADERS });
  }
});
