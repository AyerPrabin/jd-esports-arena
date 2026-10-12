// Public (deployed with --no-verify-jwt): the "Unsubscribe" link in optional emails.
//   GET  ?p=<player id>&t=<token>  -> a page with a "Confirm" button (link scanners that
//                                     open every URL in an email must not unsubscribe anyone)
//   POST (same query)              -> turns the emails off: the button, or one-click
//                                     unsubscribe from mail apps (RFC 8058)
// The token is an HMAC of the player id (see _shared/email.ts), so nobody can
// unsubscribe someone else. Only players.email_opt_out changes.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { unsubToken } from '../_shared/email.ts';

function page(title: string, msg: string, status = 200, extra = '') {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title></head>
<body style="margin:0;background:#07090F;color:#fff;font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;padding:16px">
<div style="max-width:420px;text-align:center"><h1 style="font-size:1.4rem">${title}</h1><p style="color:#A6AFC2;line-height:1.6">${msg}</p>${extra}
<p><a href="https://jdesport.co.uk/" style="color:#FFDD85">Back to JD Esports Arena</a></p></div></body></html>`;
  return new Response(html, { status, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const p = url.searchParams.get('p') || '';
  const t = url.searchParams.get('t') || '';
  if (!/^[0-9a-f-]{36}$/i.test(p) || t !== (await unsubToken(p))) {
    return page('Link not valid', 'This unsubscribe link is broken or incomplete. You can also email prabinayer7@gmail.com and we will turn the emails off for you.', 400);
  }
  if (req.method === 'GET') {
    return page('Unsubscribe from JD Arena emails?', 'This stops reminder, results and announcement emails. Room details, check-in notices and account emails still arrive, because you need them to play.', 200,
      `<form method="post"><button type="submit" style="min-height:44px;padding:10px 22px;border-radius:999px;border:0;background:#FFC83D;color:#07090F;font-weight:700;font-size:1rem;cursor:pointer">Confirm unsubscribe</button></form>`);
  }
  const supabase = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { error } = await supabase.from('players').update({ email_opt_out: true }).eq('id', p);
  if (error) return page('Something went wrong', 'Please try the link again in a minute.', 500);
  return page('You are unsubscribed', 'You will no longer get reminder, results or announcement emails. Room details, check-in notices and account emails still arrive, because you need them to play. Notifications on the site are not affected.');
});
