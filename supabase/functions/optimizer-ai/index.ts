// JD-Optimiers v5.9 "AI Doctor": the app sends a plain-text health report of the player's PC (hardware, power,
// emulator settings, the last sessions from history.csv, why FPS dropped, emulator crashes from the Windows
// event log) and gets back plain-text suggestions. Pro / Max plans only: the plan token + machine hash are
// checked with optimizer_check, and each PC gets 6 checks a day (optimizer_ai_uses).
// Ban-safe by design: the AI may only suggest Windows, driver, hardware, emulator-setting and JD-Optimiers
// changes - never anything that touches the game, its files or its input. Nothing is applied automatically.
// The report is not stored.
import { createClient } from 'npm:@supabase/supabase-js@2';
import { askAI } from '../_shared/ai.ts';

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const DAILY_CHECKS = 6;
const sha256hex = async (s: string) => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s))))
  .map((b) => b.toString(16).padStart(2, '0')).join('');
const text = (body: string, status = 200) =>
  new Response(body, { status, headers: { ...CORS_HEADERS, 'Content-Type': 'text/plain; charset=utf-8' } });

const SYSTEM = `You are JD AI Doctor inside JD-Optimiers, a Windows booster for Free Fire on MSI App Player / BlueStacks (emulator process HD-Player.exe).
You get a health report from the player's PC. Find what is really holding their FPS, smoothness, ping or stability back, using the numbers in the report.

STRICT SAFETY RULES (the player's game account must never be at risk of a ban):
- Never suggest macros, scripts, auto-clickers, aim assist, recoil control, overlays drawn on the game, memory or game-file edits, modded APKs, root, Xposed, GFX tools that edit game files, or anything that reads or changes the game.
- Only suggest: Windows settings, drivers, BIOS, cooling and hardware, the charger / power plan, background apps, network, MSI App Player / BlueStacks settings (renderer, FPS cap, CPU cores, RAM, ASTC, VSync), Free Fire's own in-game graphics menu, and JD-Optimiers features (Boost, Play, FPS cap buttons 60/90/120/240, App Sleep, Mouse presets, Live accel, Hardware Tips, Deep tweaks).
- Never tell them to change settings in the middle of a match.

HOW TO ANSWER (plain text only - no markdown, no tables, no ** or #):
1. Start with one line "Health: X/10" and one short sentence on the biggest problem.
2. Then up to 8 numbered suggestions, most important first. Each one: what to do (exact menu path or JD button), then "Why:" quoting the number from the report that shows it (e.g. "1% low 41 vs avg 118", "GPU hit 88 C", "HD-Player crashed 3 times").
3. If the report shows emulator crashes, explain the likely cause from the crash text (renderer, driver, RAM, overheating, antivirus) and the fix.
4. End with "Looks good:" and one line on what is already fine.
5. If a section "[Other JD players with the same graphics card]" is given, use it: e.g. "players with your card get a better 1% low on OpenGL at cap 90" - only when it has 3+ sessions.
6. Very last line, only if one of these JD buttons would clearly help: "JD_ACTIONS: " followed by up to 3 of exactly fps60, fps90, fps120, sleep_on (comma separated). The app turns them into buttons the player can press; they apply at the next Play, never mid-match. Leave the line out if none fits.
Keep it under 350 words, simple English a teenager understands. If data is missing (no sessions yet), say "Play one match with Play/Boost, then check again" and give only the safe basics for this hardware.`;

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== 'POST') return text('Method not allowed', 405);
  let body: { t?: unknown; m?: unknown; v?: unknown; r?: unknown };
  try {
    body = await req.json();
  } catch {
    return text('Bad request.', 400);
  }
  const token = typeof body.t === 'string' ? body.t : '';
  const m = typeof body.m === 'string' && /^[0-9a-f]{64}$/.test(body.m) ? body.m : undefined;
  const report = typeof body.r === 'string' ? body.r.slice(0, 14000) : '';
  if (!/^[0-9a-f]{64}$/.test(token)) return text('AI Doctor is part of Optimizer Pro and Max - sign in to the app first.', 403);
  if (report.length < 40) return text('The report was empty - try again.', 400);

  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const { data: plan, error: planErr } = await sb.rpc('optimizer_check', m ? { p_token: token, p_machine: m } : { p_token: token });
  if (planErr) return text('Plan check failed - try again in a minute.', 503);
  if (!plan || plan.status !== 'ok') return text('AI Doctor is part of Optimizer Pro and Max - your plan is not active on this PC.', 403);

  const hash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode('ai:' + token))))
    .map((b) => b.toString(16).padStart(2, '0')).join('');
  const since = new Date(Date.now() - 86400000).toISOString();
  const { count, error: cntErr } = await sb.from('optimizer_ai_uses').select('id', { count: 'exact', head: true })
    .eq('token_hash', hash).gte('at', since);
  if (!cntErr && (count ?? 0) >= DAILY_CHECKS) return text(`You used all ${DAILY_CHECKS} AI checks for today - try again tomorrow.`, 429);

  // what other JD players with the same graphics card got (anonymous shared stats) - real numbers for the AI
  const gpus = [...report.matchAll(/^GPU: (.+?), [\d.]+ GB VRAM$/gm)].map((x) => x[1].trim()).slice(0, 4);
  let peers = '';
  if (gpus.length) {
    const { data: rows } = await sb.rpc('optimizer_gpu_stats', { p_gpus: gpus });
    if (Array.isArray(rows) && rows.length) {
      peers = '\n\n[Other JD players with the same graphics card, last 90 days: renderer, FPS cap -> avg FPS, 1% low, stutters/min]\n' +
        rows.slice(0, 12).map((g: any) => `${g.gpu}: ${g.renderer} cap ${g.cap} -> ${g.fps} FPS, 1% low ${g.low1}, ${g.stutter_min}/min (${g.sessions} sessions)`).join('\n');
    }
  }

  const ai = await askAI([
    { role: 'system', content: SYSTEM },
    { role: 'user', content: report + peers },
  ], ['groq', 'cerebras', 'gemini'], { timeoutMs: 18000 });   // stays under the app's 90 s wait; Gemini last (ZULU shares it)
  if (!ai || !ai.text.trim()) return text('The AI is busy right now - try again in a few minutes.', 503);
  if (!cntErr) await sb.from('optimizer_ai_uses').insert({ token_hash: hash });
  // plain text for the app's text box: strip any markdown the model slipped in
  const out = ai.text.replace(/\*\*|__|^#+\s*/gm, '').replace(/^\s*[-*]\s+/gm, '- ').trim();

  // "My PC" card on /optimizer/: keep the latest answer for this linked PC (the player sees only their own)
  try {
    const { data: dev } = await sb.from('optimizer_devices').select('id, player_id')
      .eq('token_hash', await sha256hex(token)).is('revoked_at', null).maybeSingle();
    if (dev) {
      const advice = out.replace(/^JD_ACTIONS:.*$/m, '').trim();
      const sm = /Health:\s*(\d{1,2})\s*\/\s*10/i.exec(advice);
      const score = sm ? Math.min(10, Math.max(0, +sm[1])) : null;
      const first = advice.split('\n').map((l) => l.trim()).filter(Boolean);
      const headline = (sm ? (first[0].replace(/Health:\s*\d+\s*\/\s*10[.\s-]*/i, '') || first[1] || '') : first[0] || '').slice(0, 300);
      await sb.from('optimizer_ai_latest').upsert({ device_id: dev.id, player_id: dev.player_id, score, headline,
        advice: advice.slice(0, 4000), at: new Date().toISOString() });
    }
  } catch (_) { /* the card is a bonus - the answer still goes back */ }
  return text(out);
});
