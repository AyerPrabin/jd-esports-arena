// JD Arena homepage logic (moved out of index.html so phones cache it; bump ?v= in index.html after edits)
/* Captured synchronously, before supabase-js's detectSessionInUrl can consume/clear the
   redirect hash — tells us this SIGNED_IN is "just verified my email", not a normal login,
   so we know to auto-ask for push permission right here (see onAuthStateChange below). */
if(/[?&]shop=1/.test(location.search))window.addEventListener('load',()=>setTimeout(()=>{if(typeof _player!=='undefined'&&_player)fxShopOpen(null);else authOpen('login');},1400));
if(/[?&]account=1/.test(location.search))window.addEventListener('load',()=>setTimeout(()=>{if(typeof _player!=='undefined'&&_player)authOpen('login');},1200));
if(/[?&]signin=1/.test(location.search))window.addEventListener('load',()=>setTimeout(()=>{if(typeof _player==='undefined'||!_player)authOpen('login');},900));
/* ?signin=1&next=/optimizer/ : once signed in (password or Google), go back to that page on this site.
   Only same-site paths are accepted ("/x", never "//host" or "https:"). */
(function(){const m=/[?&]next=([^&#]+)/.exec(location.search);if(!m)return;let n='';try{n=decodeURIComponent(m[1]);}catch(e){return;}
  if(/^\/(?![\/\\])[A-Za-z0-9_\-\/.?=&%]*$/.test(n))try{sessionStorage.setItem('jd_next',n);}catch(e){}})();
let _emailVerifyFlow=/type=signup/.test(location.hash)||/type=signup/.test(location.search);
/* Same idea, for the delete-account flow: set before supabase-js can consume the redirect
   hash, so the SIGNED_IN handler below knows this login came from the "confirm deletion"
   magic-link email, not a normal login — see authRequestDelete(). */
let _deleteConfirmFlow=/confirm_delete=1/.test(location.search);
/* ---- config: point this at your repo's raw tournaments.json ---- */
const TOURNAMENTS_URL='https://jdesport.co.uk/tournaments.json'; /* not raw.githubusercontent.com — repo is private, that 404s unauthenticated; Pages serves this file publicly regardless */
const EDGE_FN_BASE='https://cnoxvqvpmgowdiyrrusv.supabase.co/functions/v1'; // Supabase Edge Functions (moved off Netlify)
const DISCORD_INVITE='https://discord.gg/dgvQTbNvVu'; /* JD Esports Arena Discord */
const MAIN_SITE_URL='/about/'; /* clean who-I-am + contact page (no phases). Point to zulu-website.html instead if you want the full portfolio. */
const WHATSAPP_NUMBER=''; /* ← your WhatsApp number, international format, digits only e.g. 97798XXXXXXXX. Powers one-tap Register. Leave '' to hide it. */
/* Customer support (a person): call or WhatsApp. Separate from WHATSAPP_NUMBER above, which switches on WhatsApp registration. */
const SUPPORT_PHONE='9779868813682',SUPPORT_PHONE_TXT='+977 986-8813682';
/* Per-squad visual effect — set per squad in the admin editor's Manual squad list
   ("Special effect" dropdown), not hardcoded here. Keys must match admin/index.html's
   SQUAD_EFFECTS values exactly. */
/* Only the champion effect gets an emoji badge (the crown) — the rest speak for
   themselves through the animated effect alone, an emoji on top read as clutter. */
/* tier = the cheapest plan that unlocks it: 'lite' (Rs 5 lite week), 'game' (Rs 2 single
   match), 'pro' (Rs 10 week / Rs 30 month — pro unlocks everything). The database's
   fx_tier_ok() is the real rule; this only drives the picker. */
const SQUAD_FX={
  glow:{key:'glow',cls:'sq-fx-glow',badge:'',particles:0,tag:'Glow',tier:'lite'},
  steel:{key:'steel',cls:'sq-fx-steel',badge:'',particles:0,tag:'Steel',tier:'lite'},
  gold:{key:'gold',cls:'sq-fx-gold',badge:'👑',particles:0,tag:'Champion',tier:'game'},
  fire:{key:'fire',cls:'sq-fx-fire',badge:'',particles:4,tag:'On fire',tier:'game'},
  ice:{key:'ice',cls:'sq-fx-ice',badge:'',particles:2,tag:'Frozen',tier:'game'},
  neon:{key:'neon',cls:'sq-fx-neon',badge:'',particles:0,tag:'Neon',tier:'game'},
  rainbow:{key:'rainbow',cls:'sq-fx-rainbow',badge:'',particles:2,tag:'Prism',tier:'game'},
  galaxy:{key:'galaxy',cls:'sq-fx-galaxy',badge:'',particles:0,tag:'Galaxy',tier:'pro'},
  thunder:{key:'thunder',cls:'sq-fx-thunder',badge:'',particles:0,tag:'Thunder',tier:'pro'},
  bullets:{key:'bullets',cls:'sq-fx-bullets',badge:'💥',particles:0,tag:'Bullet Storm',tier:'pro',hot:true},
  blade:{key:'blade',cls:'sq-fx-blade',badge:'⚔️',particles:0,tag:'Blade',tier:'pro'},
  legend:{key:'legend',cls:'sq-fx-legend',badge:'💎',particles:0,tag:'Legend',tier:'pro',hot:true},
  /* design-style effects, all Pro (styles in /effects-styles.css) */
  skeuo:{key:'skeuo',cls:'sq-fx-skeuo',badge:'',particles:0,tag:'Metal Plate',tier:'pro'},
  soft:{key:'soft',cls:'sq-fx-soft',badge:'',particles:0,tag:'Soft Touch',tier:'pro'},
  glass:{key:'glass',cls:'sq-fx-glass',badge:'',particles:0,tag:'Frosted',tier:'pro'},
  clay:{key:'clay',cls:'sq-fx-clay',badge:'',particles:0,tag:'Clay',tier:'pro'},
  brutal:{key:'brutal',cls:'sq-fx-brutal',badge:'',particles:0,tag:'Brutal',tier:'pro'},
  mono:{key:'mono',cls:'sq-fx-mono',badge:'',particles:0,tag:'Mono',tier:'pro'},
  maximal:{key:'maximal',cls:'sq-fx-maximal',badge:'🎉',particles:0,tag:'Overload',tier:'pro'},
  liquid:{key:'liquid',cls:'sq-fx-liquid',badge:'',particles:0,tag:'Liquid Glass',tier:'pro',hot:true},
  bento:{key:'bento',cls:'sq-fx-bento',badge:'',particles:0,tag:'Bento',tier:'pro'},
  spatial:{key:'spatial',cls:'sq-fx-spatial',badge:'',particles:0,tag:'Spatial 3D',tier:'pro',hot:true}
};
function fxTierOk(tier,key){const f=SQUAD_FX[key];return !!f&&(tier==='pro'||f.tier===tier);}
function squadFx(tm){return SQUAD_FX[tm&&tm.effect]||null;}
// Real floating particle elements (embers/snow/confetti), not just a CSS pseudo-element trick —
// each one moves independently, which reads far more alive than one shared background animation.
// Roster-modal particles: 6 spread across the whole card, positions/timings fixed per
// index (not Math.random) so a re-render doesn't make them jump around.
function sqfxParticles(){let h='';for(let k=0;k<6;k++)h+=`<i class="sqp" style="--x:${(k*37+9)%96}%;--y:${(k*53+11)%78}%;--d:${((k*.43)%2.6).toFixed(2)}s;--t:${(1.9+(k%3)*.55).toFixed(2)}s"></i>`;return h;}
function fxParticlesHtml(fx){if(!fx||!fx.particles)return'';let h='';for(let k=0;k<fx.particles;k++)h+=`<i class="fxp" style="--d:${(k*.5).toFixed(1)}s"></i>`;return h;}
// Every effect except Champion colors the name itself (a scrolling gradient in that
// effect's colors) — wrap it separately so only the text gets it, not the logo/badge/particles.
function fxNameHtml(fx,name){return (fx&&fx.cls!=='sq-fx-gold')?`<span class="fx-name">${esc(name)}</span>`:esc(name);}
/* Effect of a squad by name within one tournament — for places that only know the name
   (results table, podium, winner banner). Same sources as the cards: live roster first,
   then the admin's Manual squad list; names compared trimmed + case-insensitive since the
   results table and the winner field are typed by hand. */
const fxKey=s=>String(s||'').trim().toLowerCase();
function fxForSquad(tname,squad){
  const k=fxKey(squad);if(!k)return null;
  const t=((_lastData||{}).tournaments||[]).find(x=>x.name===tname);
  const hit=(t?teamsFor(t):[]).find(x=>fxKey(x.name)===k)||(_liveRoster.get(tname)||[]).map(x=>({name:x.squad_name,effect:x.effect,logo:x.squad_logo})).find(x=>fxKey(x.name)===k);
  return hit?{fx:SQUAD_FX[hit.effect]||null,logo:hit.logo||''}:{fx:null,logo:''};
}
// name with its effect as text only (no card) — see .fxn-* in effects-pro.css
function fxText(fx,name,tag){return fx?`<span class="fxn fxn-${fx.key}">${esc(name)}</span>${tag?`<span class="fxn-tag">✨ ${esc(fx.tag)}</span>`:''}`:esc(name);}
/* The champion of a finished event: the admin's Winner field, or — if that's still blank —
   the top squad of its published Best-of-3 table, so the name shows the moment it ends. */
function winnerOf(t,d){
  const w=String(t.winner||'').trim();if(w)return w;
  const B=d&&d.bo3;
  if(B&&B.published&&B.tournament===t.name&&B.teams&&B.teams.length){const top=bo3Standings(B)[0];if(top&&top.totalPts>0)return top.team;}
  return '';
}

/* ── career stats & rank tiers ── computed from get_player_career_stats() (see
   supabase/schema.sql), which aggregates every tournament_results row a player's
   registrations are credited for — squad-shares-stats, same model documented there.
   Only the top tier (Ace) gets a visual effect — the rainbow one, reused from
   SQUAD_FX above rather than inventing a separate visual — so it stays a rare,
   meaningful flex instead of every tier lighting up. Thresholds are cumulative
   career points (kills + placement, summed across every archived tournament) —
   tune freely, nothing else is keyed to these numbers. */
const RANK_TIERS=[
  {name:'Bronze',min:0,effect:''},
  {name:'Silver',min:20,effect:''},
  {name:'Gold',min:50,effect:''},
  {name:'Platinum',min:100,effect:''},
  {name:'Diamond',min:200,effect:''},
  {name:'Heroic',min:350,effect:''},
  {name:'Ace',min:550,effect:'rainbow'}
];
function computeTier(points){let t=RANK_TIERS[0];for(const tier of RANK_TIERS){if(points>=tier.min)t=tier;}return t;}
const TIER_ICONS={Bronze:'🥉',Silver:'🥈',Gold:'🥇',Platinum:'💠',Diamond:'💎',Heroic:'🔥',Ace:'👑'};
// % progress through the CURRENT tier's point band, for the rank card's ring + XP bar.
// Ace has no next tier — treated as maxed out (100%) rather than dividing by zero.
function tierProgress(tier,points){
  const idx=RANK_TIERS.indexOf(tier);
  const next=RANK_TIERS[idx+1];
  if(!next)return 100;
  const span=next.min-tier.min;
  return Math.max(2,Math.min(100,Math.round((points-tier.min)/span*100)));
}
let _careerStats=null;
async function loadCareerStats(){
  const box=document.getElementById('career-stats');
  if(!box||!sb||!_player||!_player.tag)return;
  box.innerHTML='<p class="sub">Loading career stats…</p>';
  try{
    const {data,error}=await sb.rpc('get_player_career_stats',{p_player_tag:_player.tag});
    if(error||!data||!data.length){box.innerHTML='';return;}
    _careerStats=data[0];
    renderCareerStats();
  }catch(e){box.innerHTML='';}
}
// The squad the player is in for whichever tournament's bracket is currently on
// display, if any — same data myPointsGapInfo() (ZULU) uses, shown here too so
// "team rank" doesn't require asking the chatbot.
function teamRankLine(){
  const B=(_lastData||{}).bo3;
  if(!B||!B.published||!B.teams||!B.teams.length)return'';
  const reg=_myRegs.get(B.tournament);
  const squad=reg&&reg.squad_name;
  if(!squad)return'';
  const rows=bo3Standings(B);
  const mine=rows.find(r=>r.team===squad);
  if(!mine)return'';
  return `<div class="career-team-rank">Squad rank in "${esc(B.tournament)}": <b>#${mine.rank}</b> · ${mine.totalPts} pts<p style="margin:8px 0 0;font-size:.8rem;color:var(--pm-muted,#9CA8BE)">🧠 ${esc(matchAnalystComment(mine,rows))}</p></div><button class="pm-btn" id="share-result-btn" style="margin-top:10px" onclick="shareMyResult()"><span class="pm-btn-ic">📤</span><span class="pm-btn-txt">Share my result</span></button>`;
}
function ordinal(n){const s=['th','st','nd','rd'],v=n%100;return n+(s[(v-20)%10]||s[v]||s[0]);}
// Personal per-squad breakdown ("match analyst") — computed straight from the same
// live bo3Standings() rows shown on the board, no separate data source or AI call.
function matchAnalystComment(mine,rows){
  const avgPts=rows.reduce((s,r)=>s+r.totalPts,0)/rows.length;
  const diff=mine.totalPts-avgPts;
  const ptsNote=diff>=3?`above the lobby average (${avgPts.toFixed(1)})`:diff<=-3?`below the lobby average (${avgPts.toFixed(1)})`:`right around the lobby average (${avgPts.toFixed(1)})`;
  return `You placed ${ordinal(mine.rank)} with ${mine.totalPts} points — ${ptsNote}.`;
}
function renderCareerStats(){
  const box=document.getElementById('career-stats');if(!box||!_careerStats)return;
  const s=_careerStats;
  const tier=computeTier(+s.total_points||0);
  const fx=SQUAD_FX[tier.effect]||null;
  // Apply the same tier effect to the username shown above this card.
  const nameEl=document.querySelector('#auth-body .auth-tag');
  if(nameEl){nameEl.className='auth-tag'+(fx?' '+fx.cls:'');nameEl.innerHTML=(fx&&fx.badge?`<span class="fx-badge">${fx.badge}</span> `:'')+fxNameHtml(fx,'@'+(_player.username||'…'))+fxParticlesHtml(fx);}
  const played=s.tournaments_played||0;
  const points=+s.total_points||0;
  const icon=TIER_ICONS[tier.name]||'🎖️';
  const nextTier=RANK_TIERS[RANK_TIERS.indexOf(tier)+1];
  if(!played){
    box.innerHTML=`<div class="career-card"><div class="pm-rank-top"><div class="pm-rank-icon">${icon}</div><div class="pm-rank-text"><div class="career-tier">${esc(tier.name)} Rank</div><p class="pm-rank-sub">Play a tournament to start building your career stats.</p></div></div></div>`;
    return;
  }
  const pct=tierProgress(tier,points);
  box.innerHTML=`<div class="career-card">
    <div class="pm-rank-top">
      <div class="pm-rank-icon">${icon}</div>
      <div class="pm-rank-text">
        <div class="career-tier${fx?' '+fx.cls:''}">${fx&&fx.badge?`<span class="fx-badge">${fx.badge}</span> `:''}${fxNameHtml(fx,tier.name+' Rank')}${fxParticlesHtml(fx)}</div>
        <p class="pm-rank-sub">${nextTier?(`<b>${nextTier.min-points} pts</b> to ${TIER_ICONS[nextTier.name]||''} ${esc(nextTier.name)}`):'Highest rank — legendary status.'}</p>
      </div>
      <div class="pm-ring" style="--pct:${pct}"><span>${pct}%</span></div>
    </div>
    <div class="career-grid">
      <div><b>${played}</b><span>Tournaments</span></div>
      <div><b>${s.booyahs||0}</b><span>Booyahs</span></div>
      <div><b>${s.avg_placement||'—'}</b><span>Avg placement</span></div>
      <div><b>${points}</b><span>Career points</span></div>
      <div><b>${s.total_prize&&+s.total_prize>0?'Rs '+s.total_prize:'—'}</b><span>Prize won</span></div>
    </div>
    <div class="pm-xpbar"><span style="width:${pct}%"></span></div>
    ${teamRankLine()}
  </div>`;
}

/* ── shareable result card: canvas-rendered PNG, not a server-side image —
   free to generate, no backend cost, and it's just re-drawing data already in
   memory (bo3Standings() + _myRegs, same source as teamRankLine() above). ── */
function wrapCanvasText(ctx,text,x,y,maxWidth,lineHeight){
  const words=String(text||'').split(' ');let line='';const lines=[];
  for(const w of words){
    const test=line?line+' '+w:w;
    if(ctx.measureText(test).width>maxWidth&&line){lines.push(line);line=w;}else{line=test;}
  }
  if(line)lines.push(line);
  lines.forEach((l,i)=>ctx.fillText(l,x,y+i*lineHeight));
  return lines.length;
}
async function generateResultCard(){
  const B=(_lastData||{}).bo3;
  if(!B||!B.published||!B.teams||!B.teams.length)return null;
  const reg=_myRegs.get(B.tournament);
  const squad=reg&&reg.squad_name;
  if(!squad)return null;
  const rows=bo3Standings(B);
  const mine=rows.find(r=>r.team===squad);
  if(!mine)return null;

  try{await document.fonts.load("260px 'Barlow Condensed'");await document.fonts.load("46px 'Barlow Condensed'");}catch(e){}

  const W=1080,H=1350;
  const cv=document.createElement('canvas');cv.width=W;cv.height=H;
  const ctx=cv.getContext('2d');

  const bgGrad=ctx.createLinearGradient(0,0,0,H);
  bgGrad.addColorStop(0,'#0D111B');bgGrad.addColorStop(1,'#07090F');
  ctx.fillStyle=bgGrad;ctx.fillRect(0,0,W,H);
  ctx.strokeStyle='rgba(255,200,80,.35)';ctx.lineWidth=6;ctx.strokeRect(24,24,W-48,H-48);

  ctx.textAlign='center';
  ctx.fillStyle='#FFDD85';ctx.font="46px 'Barlow Condensed', sans-serif";
  ctx.fillText('JD ESPORTS ARENA',W/2,130);
  ctx.fillStyle='#8A94A8';ctx.font="24px 'Geist','Mukta',sans-serif";
  ctx.fillText('by AyerFire · jdesport.co.uk',W/2,168);

  const medalColor=mine.rank===1?'#FFD54A':mine.rank===2?'#D9DEE8':mine.rank===3?'#E3A15F':'#FFC83D';
  ctx.font="260px 'Barlow Condensed', sans-serif";ctx.fillStyle=medalColor;
  ctx.fillText('#'+mine.rank,W/2,560);

  if(mine.rank===1){
    ctx.font="60px 'Barlow Condensed', sans-serif";ctx.fillStyle='#FFC83D';
    ctx.fillText('BOOYAH!',W/2,650);
  }

  ctx.font="64px 'Barlow Condensed', sans-serif";ctx.fillStyle='#FFFFFF';
  ctx.fillText(squad,W/2,760);

  ctx.font="28px 'Geist','Mukta',sans-serif";ctx.fillStyle='#A6AFC2';
  wrapCanvasText(ctx,B.title||B.tournament||'',W/2,800,W-160,34);

  const statY=1010,colW=W/3;
  [['MATCHES',3],['POINTS',mine.totalPts],['RANK','#'+mine.rank]].forEach((s,i)=>{
    const cx=colW*i+colW/2;
    ctx.font="70px 'Barlow Condensed', sans-serif";ctx.fillStyle='#FFDD85';
    ctx.fillText(String(s[1]),cx,statY);
    ctx.font="22px 'Geist','Mukta',sans-serif";ctx.fillStyle='#8A94A8';
    ctx.fillText(s[0],cx,statY+36);
  });

  ctx.font="22px 'Geist','Mukta',sans-serif";ctx.fillStyle='#8A94A8';
  ctx.fillText('jdesport.co.uk',W/2,H-50);

  return cv;
}
async function shareMyResult(){
  const btn=document.getElementById('share-result-btn');
  const txt=btn&&btn.querySelector('.pm-btn-txt');
  const reset=()=>{if(btn)btn.disabled=false;if(txt)txt.textContent='Share my result';};
  if(btn)btn.disabled=true;if(txt)txt.textContent='Generating…';
  try{
    const cv=await generateResultCard();
    if(!cv){reset();return;}
    cv.toBlob(async blob=>{
      if(!blob){reset();return;}
      const file=new File([blob],'jd-arena-result.png',{type:'image/png'});
      if(navigator.share&&navigator.canShare&&navigator.canShare({files:[file]})){
        try{await navigator.share({files:[file],title:'JD Esports Arena result'});}catch(e){}
      }else{
        const url=URL.createObjectURL(blob);
        const a=document.createElement('a');a.href=url;a.download='jd-arena-result.png';document.body.appendChild(a);a.click();document.body.removeChild(a);
        setTimeout(()=>URL.revokeObjectURL(url),2000);
      }
      reset();
    },'image/png');
  }catch(e){reset();}
}
const FEEDBACK_WEBHOOK=''; /* \u26a0 KEEP EMPTY on a public deploy: a webhook URL here is visible in page source and anyone could spam your Discord. Use the server /feedback route or the email fallback instead. */
const FEEDBACK_EMAIL='prabinayer7@gmail.com';
const ADMIN_EMAIL='ayerprabin95@gmail.com'; /* logged-in account that reveals the Admin link in the nav. This is
   NOT a password gate — jd-admin-970f8094.html still requires its own passcode, this only decides who *sees*
   the shortcut. Page source is public either way, so treat the admin passcode (not this email match) as the
   real boundary. */
const ZULU_PUBLIC_URL=''; /* was a temporary trycloudflare tunnel to the desktop zulu_server.py: it died whenever the PC was off, and every chat then fell back to canned answers. ZULU now answers online via the zulu-ai-reply Edge Function. */ /* OPTIONAL: if you host zulu_server.py publicly, put its base URL here (e.g. https://yourserver.com) and ZULU answers with the smart public brain via /public. Leave '' to use the built-in answers. The /public endpoint NEVER sees your private plan. NOTE: this is a cloudflared quick-tunnel URL — it changes every time zulu_server.py/cloudflared restart on Prabin's PC. If ZULU stops answering live questions, re-run cloudflared and paste the new URL here. */
const SUPABASE_URL='https://cnoxvqvpmgowdiyrrusv.supabase.co'; /* Supabase Project URL (Settings → API). */
const SUPABASE_ANON_KEY='sb_publishable_5n7uzH5crKrLe8A75K6OVQ_C_di-jil'; /* Supabase publishable key (Settings → API). Safe to expose here — it's protected by Row Level Security (see supabase/schema.sql). NEVER put the secret key in this file. */
const sb=(typeof supabase!=='undefined'&&SUPABASE_URL&&SUPABASE_ANON_KEY)?supabase.createClient(SUPABASE_URL,SUPABASE_ANON_KEY):null;

/* ── "who's online" presence — a Realtime Presence channel, not a DB table/heartbeat:
   presence disappears the instant a tab closes/disconnects, so the admin panel's live
   count (admin/index.html's connectPresence()) is always the real number, never a stale
   row nobody cleaned up. Every visitor joins (even logged-out ones show as an anonymous
   entry); trackPresence() re-announces with the current username whenever login state
   changes so the admin sees who, not just how many. ── */
let _presenceChannel=null;
function initPresence(){
  if(!sb||_presenceChannel)return;
  const key=(window.crypto&&crypto.randomUUID)?crypto.randomUUID():'anon-'+Math.random().toString(36).slice(2);
  _presenceChannel=sb.channel('jd-online',{config:{presence:{key}}});
  _presenceChannel.subscribe(status=>{if(status==='SUBSCRIBED')trackPresence();});
}
function trackPresence(){
  if(!_presenceChannel)return;
  _presenceChannel.track({username:(_player&&_player.username)||null,tag:(_player&&_player.tag)||null,since:new Date().toISOString()});
}
const FORCE_LOGIN_GATE=false; /* ← kill-switch. Flip to true ONLY after confirming, on the LIVE
   site, that signup → verify email → land back logged in actually works end-to-end (needs
   Authentication → URL Configuration's Site URL + Redirect URLs set correctly in Supabase).
   Until then this stays false so a broken email-verify redirect can't lock every visitor
   out of the whole site with no way back in. */
/* Hide immediately (synchronously, before any async session check) ONLY when the gate is
   actually armed. Keeps the ungated (current) experience flash-free, while still avoiding
   a flash of real content once the gate is turned on. */
if(FORCE_LOGIN_GATE&&sb){
  document.write('<style>header,#main-content{display:none}</style>');
}
/* ── Push alerts: the browser's own Web Push (VAPID) — no third-party SDK, so ad-blockers
   and Brave Shields can't block it. The device's subscription is saved to
   push_subscriptions (save_push_subscription RPC); every Edge Function sends through
   supabase/functions/_shared/push.ts; /sw.js shows the alert even when the site is closed. ── */
const VAPID_PUBLIC_KEY='BPP1cVMCDdmZzwhR48u0BBEFbrg2LP9JEUm8YHAWogBIoegeuJLZaKOvv_6JSciOMwMB0tu4C9RgWghf4HjQo4I';
let _pushSub=null,_pushErr='',_appToken='';
function b64ToU8(s){const p='='.repeat((4-s.length%4)%4),b=atob((s+p).replace(/-/g,'+').replace(/_/g,'/'));return Uint8Array.from(b,c=>c.charCodeAt(0));}
/* JD Arena app 2.0+ is a real Android app (WebView + window.JDApp bridge), not a browser tab: alerts come
   through Firebase (save_fcm_token, push_fcm_tokens) and Android's own notification permission. */
const JD_APP=window.JDApp||null;
function pushSupported(){return !!JD_APP||('serviceWorker' in navigator&&'PushManager' in window&&typeof Notification==='function');}
function pushPerm(){if(JD_APP){try{return JD_APP.notifPermission();}catch(e){return 'default';}}return typeof Notification==='function'?Notification.permission:'default';}
function pushAsk(){if(JD_APP)return new Promise(res=>{window.__jdPerm=res;JD_APP.requestNotifPermission();});return Notification.requestPermission();}
function appPushToken(){return new Promise(res=>{window.__jdToken=res;try{JD_APP.pushToken();}catch(e){res('ERR_bridge');}setTimeout(()=>res('ERR_timeout'),15000);});}
/* iPhone/iPad only support push for a home-screen-installed app (Apple's own
   restriction) — detect it and explain instead of the button silently doing nothing. */
/* Device text always follows platform_mode (what sign-up actually enforces; missing = mixed), never the old free-text field */
function platText(t){return ({mobile:'Mobile only',emulator:'Emulator only',mixed:'Mix Device'})[(t&&t.platform_mode)||'mixed']||'Mix Device';}
function isIosDevice(){return /iP(hone|od|ad)/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);}
/* Android app (TWA, /download/): the launcher opens /?source=twa&av=<versionCode>. A tap on a notification
   opens a plain URL in a new tab, so Android's android-app:// referrer counts too (version unknown: -1).
   Kept in sessionStorage, never localStorage: the app shares Chrome's storage, so ordinary Chrome tabs
   would think they're the app. */
const JD_TWA=(()=>{try{const m=/[?&]source=twa&av=(\d+)/.exec(location.search);
  if(m)sessionStorage.setItem('jd_twa',m[1]);
  else if(/^android-app:\/\/uk\.co\.jdesport\.arena/.test(document.referrer)&&!sessionStorage.getItem('jd_twa'))sessionStorage.setItem('jd_twa','-1');
  return +(sessionStorage.getItem('jd_twa')||0);}catch(e){return 0;}})();
function isStandaloneApp(){return !!JD_TWA||window.matchMedia('(display-mode: standalone)').matches||navigator.standalone===true;}
// Subscribe this device (only if notifications are already allowed) and save it to the
// signed-in player. Safe to call on every load: it re-saves, which also covers endpoints
// the browser rotated and a device that signed in as a different player.
async function ensurePushSubscribed(){
  if(!pushSupported()||!sb||!_player)return false;
  if(JD_APP){
    try{
      const t=await appPushToken();
      if(!t||/^ERR/.test(t))throw new Error('The app could not get a notification token ('+(t||'ERR_empty')+').');
      const {error}=await sb.rpc('save_fcm_token',{p_token:t,p_app_version:JD_TWA||null});
      if(error)throw error;
      _appToken=t;
      _pushSub=pushPerm()==='granted'?{fcm:t}:null;_pushErr='';updatePushBtn();return !!_pushSub;
    }catch(e){
      _pushErr=String((e&&e.message)||e);_pushSub=null;updatePushBtn();
      try{sb.rpc('log_app_push_error',{p_error:_pushErr.slice(0,300),p_app_version:JD_TWA||null,p_perm:pushPerm()});}catch(x){}
      return false;
    }
  }
  if(pushPerm()!=='granted')return false;
  try{
    const reg=await navigator.serviceWorker.ready;
    let sub=await reg.pushManager.getSubscription();
    // a subscription made with another key (e.g. the old OneSignal one) can't receive our pushes — replace it
    if(sub){const k=sub.options&&sub.options.applicationServerKey,want=b64ToU8(VAPID_PUBLIC_KEY);
      if(!k||!new Uint8Array(k).every((b,i)=>b===want[i])||k.byteLength!==want.length){try{await sub.unsubscribe();}catch(e){}sub=null;}}
    if(!sub)sub=await reg.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:b64ToU8(VAPID_PUBLIC_KEY)});
    const j=sub.toJSON();
    const {error}=await sb.rpc('save_push_subscription',{p_endpoint:j.endpoint,p_p256dh:j.keys.p256dh,p_auth:j.keys.auth,p_ua:navigator.userAgent+(JD_TWA?' JDApp/'+JD_TWA:isStandaloneApp()?' JDWebApp':'')});
    if(error)throw error;
    _pushSub=sub;_pushErr='';updatePushBtn();return true;
  }catch(e){_pushErr=String((e&&e.message)||e);_pushSub=null;updatePushBtn();return false;}
}
// on log out: stop sending this device the previous player's alerts
async function forgetPushDevice(){
  if(JD_APP){try{if(_appToken&&sb)await sb.rpc('delete_fcm_token',{p_token:_appToken});}catch(e){}_pushSub=null;_appToken='';return;}
  try{const reg=await navigator.serviceWorker.getRegistration();const sub=reg&&await reg.pushManager.getSubscription();if(sub&&sb)await sb.rpc('delete_push_subscription',{p_endpoint:sub.endpoint});}catch(e){}
  _pushSub=null;
}
const PUSH_SERVICE_HELP="Your browser couldn't start push alerts.\n\nOn Brave: open Settings → Privacy and security and turn on \"Use Google services for push messaging\", then reload this page and tap Enable again.\n\nOn other browsers: make sure notifications are allowed for jdesport.co.uk and try again.\n\nRoom details still reach you in Notification History.";
async function enablePush(){
  if(isIosDevice()&&!isStandaloneApp()){
    showMsg('Install the app to get alerts',"Apple only delivers push alerts to installed web apps on iPhone and iPad.\n\n1. Tap the Share icon in Safari.\n2. Choose \"Add to Home Screen\".\n3. Open JD Arena from the new home-screen icon and tap Enable push alerts again.");
    return;
  }
  if(!pushSupported()){showMsg('Push alerts not supported',"This browser can't receive push alerts. Use Chrome, Edge, Firefox, Brave or Samsung Internet.",true);return;}
  if(!_player){authOpen('login');return;}
  if(pushPerm()==='denied'){
    if(JD_TWA){showMsg('Notifications are turned off',"Notifications for the JD Arena app are switched off on this phone.\n\nTo turn them on: long-press the JD Arena icon on your home screen → App info → Notifications → Allow. Then open JD Arena again.",true);return;}
    showMsg("Notifications are turned off","Notifications for jdesport.co.uk were previously blocked on this device.\n\nTo turn them back on: open your browser's site settings (the icon next to the address bar), set Notifications to Allow, reload the page and tap Enable push alerts again.",true);
    return;
  }
  let perm=pushPerm();
  if(perm!=='granted'){try{perm=await pushAsk();}catch(e){}}
  if(perm!=='granted'){updatePushBtn();showMsg('Push alerts not enabled','Tap Allow when your browser asks, so JD Arena can alert you even when the site is closed.',true);return;}
  if(await ensurePushSubscribed())showMsg('Push alerts enabled','This device will now get alerts even when JD Arena is closed — match reminders, room details, new challenges and results.');
  else showMsg("Push alerts couldn't start",PUSH_SERVICE_HELP,true);
}
/* One place that decides what push looks like on this device, so the account row and the
   strip at the top of the notifications modal never disagree. */
function pushState(){
  if(isIosDevice()&&!isStandaloneApp())return 'ios';
  if(!pushSupported())return 'unsupported';
  if(pushPerm()==='denied')return 'blocked';
  if(pushPerm()==='granted'&&_pushSub)return 'on';
  if(pushPerm()==='granted'&&_pushErr)return 'svcerr';
  return 'ask';
}
const PUSH_UI={
  on:{row:'Push alerts on',sub:'Alerts arrive even when the site is closed',strip:''},
  ask:{row:'Enable push alerts',sub:'Get alerts even when the site is closed',strip:'Turn on push alerts to get match reminders, room details and new challenges even when JD Arena is closed.',cta:'Enable'},
  blocked:{row:'Push alerts turned off',sub:'Tap for steps to turn them back on',strip:'Notifications are turned off for this site in your browser settings.',cta:'Show steps'},
  ios:{row:'Install the app for alerts',sub:'Required on iPhone and iPad',strip:'On iPhone and iPad, push alerts only work in the installed home-screen app.',cta:'Show steps'},
  svcerr:{row:'Push alerts need one setting',sub:'Tap for the fix',strip:"Push alerts couldn't start on this browser — one setting needs changing.",cta:'Show fix'},
  unsupported:{row:'Push alerts not supported',sub:'Use Chrome, Edge, Firefox or Brave',strip:''}
};
function updatePushBtn(){
  const s=pushState(),ui=PUSH_UI[s],warn=s==='blocked'||s==='ios'||s==='svcerr';
  const b=document.getElementById('acct-push-btn');
  if(b){
    const txt=b.querySelector('.pm-row-txt');
    if(txt)txt.innerHTML=`${esc(ui.row)}<small class="pm-row-sub">${esc(ui.sub)}</small>`;
    b.classList.toggle('on',s==='on');b.classList.toggle('warn',warn);
    b.disabled=s==='on'||s==='unsupported';
    const tg=document.getElementById('acct-push-toggle');
    if(tg){tg.classList.toggle('on',s==='on');tg.classList.toggle('warn',warn);}
  }
  const strip=document.getElementById('notif-push');
  if(strip){
    if(!_player||!ui.strip){strip.hidden=true;strip.innerHTML='';}
    else{strip.hidden=false;strip.className='notif-push '+s;strip.innerHTML=`<span class="notif-push-ic">${s==='ask'?'🔔':s==='ios'?'📲':'🚫'}</span><span class="notif-push-txt">${esc(s==='blocked'&&JD_TWA?'Notifications are turned off for the JD Arena app.':ui.strip)}</span><button type="button" onclick="enablePush()">${esc(ui.cta)}</button>`;}
  }
}
/* Inside the Android app notifications are the whole point, and the player is often already signed in
   (the app shares Chrome's login) while Android 13+ starts the app with them off: ask once per app session. */
async function appAskPush(){
  if(!JD_TWA||!_player||!_player.termsAccepted||!pushSupported()||pushPerm()==='granted')return;
  try{if(sessionStorage.getItem('jd_app_push'))return;sessionStorage.setItem('jd_app_push','1');}catch(e){return;}
  if(await confirmBox('🔔 Turn on notifications','Room IDs, check-in alerts, results and challenges arrive as JD Arena app notifications - even when the app is closed.','Turn on','Later'))enablePush();
}
/* App 2.0.2+: the app calls this when it comes back to the front and after Android's notification question,
   so turning notifications on in phone settings takes effect without a reload. */
let _pushRefreshAt=0;
window.jdPushRefresh=function(force){
  if(!JD_APP||!_player)return;
  if(!force&&Date.now()-_pushRefreshAt<300000){updatePushBtn();return;}
  _pushRefreshAt=Date.now();ensurePushSubscribed();
};
/* App 2.0.3+: the phone's approximate area (city / district), only if the player allowed location in the app
   (LauncherActivity.readArea). '' = not known yet, 'none' = not allowed -> the saved area is cleared. */
let _area='';
window.jdArea=function(j){if(j){_area=j;saveArea();}};
async function saveArea(){
  if(!sb||!_player||!_area)return;
  const key=_player.id+'|'+_area;
  try{if(sessionStorage.getItem('jd_area_saved')===key)return;}catch(e){}
  let a=null;if(_area!=='none'){try{a=JSON.parse(_area);}catch(e){return;}}
  const {error}=await sb.rpc('save_my_area',{p_city:a&&a.city||null,p_district:a&&a.district||null,p_region:a&&a.region||null,p_country:a&&a.country||null,p_lat:a&&typeof a.lat==='number'?a.lat:null,p_lon:a&&typeof a.lon==='number'?a.lon:null});
  if(!error)try{sessionStorage.setItem('jd_area_saved',key);}catch(e){}
}
/* Called right when an account becomes active: ask once if the player hasn't answered yet. */
async function maybeAskPush(){
  if(!pushSupported()||pushPerm()!=='default')return;
  try{if(await pushAsk()==='granted')await ensurePushSubscribed();}catch(e){}
  updatePushBtn();
}

const ARENA_SAMPLE={tagline:'JD Esports Arena · AyerFire',tournaments:[
 {name:'JD Free Fire Open #1',game:'Free Fire BR · Squad',date:'TBA',time:'TBA',status:'upcoming',prize:'Bragging rights + shoutout',entry:'Free',platform:'Mobile only',slots:12,registered:0,teams:[],format:'Battle Royale · 4 matches',register_url:''},
 {name:'JD Free Fire Open #2',game:'Free Fire BR · Squad',date:'TBA',time:'TBA',status:'upcoming',prize:'Bragging rights + shoutout',entry:'Free',platform:'Mobile only',slots:12,registered:0,teams:[],format:'Battle Royale · 4 matches',register_url:''},
 {name:'JD Free Fire Open #3',game:'Free Fire BR · Squad',date:'TBA',time:'TBA',status:'upcoming',prize:'Bragging rights + shoutout',entry:'Free',platform:'Mobile only',slots:12,registered:0,teams:[],format:'Battle Royale · 4 matches',register_url:''}]};

function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
let _lastData=null;
/* ── language (EN / नेपाली) + safe register links — easy + safe for young players ── */
const WA_DEFAULT_MSG='Hi! I want to join a JD Arena tournament. My squad: ';
function lsGet(k){try{return localStorage.getItem(k)}catch(e){return null}}
function lsSet(k,v){try{localStorage.setItem(k,v)}catch(e){}}
function safeUrl(u){u=String(u||'').trim();return /^(https?:\/\/|mailto:|tel:)/i.test(u)?u:'';}
function waLink(msg){const n=(typeof WHATSAPP_NUMBER==='string'?WHATSAPP_NUMBER:'').replace(/[^0-9]/g,'');return n?('https://wa.me/'+n+'?text='+encodeURIComponent(msg||'')):'';}
function regLink(t){var ty=(t.register_type||'whatsapp');
  if(ty==='discord')return DISCORD_INVITE||waLink('Hi! I want to register for '+(t.name||'a JD Arena tournament')+'. My squad: ');
  if(ty==='url')return safeUrl(t.register_url);
  return waLink('Hi! I want to register for '+(t.name||'a JD Arena tournament')+'. My squad: ')||safeUrl(t.register_url);}
const T={
 en:{eye:'Free Fire \u00b7 Nepal',h1:'Where Nepal <em>competes</em>',sub:"Free Fire BR tournaments under the AyerFire banner \u2014 real prize pools, live brackets, room-ID delivery and a season leaderboard. Built and run solo.",see:"See what's on",discord:'Join the Discord',ttl:'Tournaments',ttag:'Live + Upcoming',howttl:'How to join',s1t:'Sign up',s1d:'Create a free account. Your squad name and logo are saved for every event.',s2t:'Load points',s2d:'In your wallet, pay the eSewa QR and upload the payment screenshot. Points are added once we check it (1 point = Rs 1).',s3t:'Join with points',s3d:'Tap Join on an event. Free events confirm straight away; paid entries are taken from your points.',s4t:'Confirm & play',s4d:'After you register, tap "Confirm you\'re playing" on the event. The window opens 48h before start and closes 24h before — not confirmed by then means you lose your seat.',s5t:'Get your Room ID',s5d:'The Room ID and password appear on your ticket about 5 minutes before the match.',evpast:'📅 Past events \u2192',evlb:'🏆 Leaderboard \u2192',tuttag:'Tutorial',openwallet:'Open wallet \u2192',evnav:'📅 Events',wacta:'Register on WhatsApp',lbttl:'Season Leaderboard',lbtag:'Standings',about:'About',reg:'Register',regwa:'Register on WhatsApp',join:'Watch / Join',soon:'Registration opening soon',livenow:'Live now',winner:'Winner',livettl:'Now Playing',livetag:'Live',schttl:'Schedule',ptsttl:'Points',th_team:'Team',th_kills:'Kills',th_place:'Place',th_pts:'Points',scheduled:'Scheduled',done:'Finished',nosched:'Schedule coming soon.',nopts:'Points appear once matches start.',regdc:'Register on Discord',bo3ttl:'Best of 3 Results',bo3tag:'Round by round',th_total:'Total',th_rank:'#',bo3norounds:'Results appear here once a bracket is published.',sqview:'squads · tap to view',sqttl:'Registered Squads',sqmembers:'Members',sqopen:'Open slot',sqempty:'No squads registered yet — be the first!',scttl:'How Points Work',sctag:"Placement + kills",scintro:"Each match, your squad gets placement points from the official room result plus 1 point for every kill.",sckillt:"Kill points",sckilld:"1 point for every kill your squad gets in the match.",scplacet:"Total",scplaced:"Placement points and kill points from all matches are added together. The highest total wins.",scposh:"\ud83d\udcca Position points",scposd:"Where your squad finishes in each match gives placement points. Every kill adds 1 more point.",scposex:"Example: 1st in match 1 (12) + 3rd in match 2 (8) + 10th in match 3 (1) = 21 points.",msttl:'Match Settings',mstag:'Same every match',msintro:'The room is set up the same way every tournament, so nobody has an edge going in.',msgunt:'Gun Attributes',msgund:"Off — weapon skin stat bonuses don't apply.",msskillt:'Character Skills',msskilld:"On — your character's active/passive skill works as normal.",msmapt:'Map',msmapd:"Full map, normal settings — the zone shrinks as usual, nothing's changed there."},
 ne:{eye:'\u092b\u094d\u0930\u0940 \u092b\u093e\u092f\u0930 \u00b7 \u0928\u0947\u092a\u093e\u0932',h1:'\u091c\u0939\u093e\u0901 \u0928\u0947\u092a\u093e\u0932 <em>\u092a\u094d\u0930\u0924\u093f\u0938\u094d\u092a\u0930\u094d\u0927\u093e</em> \u0917\u0930\u094d\u091b',sub:'AyerFire \u0905\u0928\u094d\u0924\u0930\u094d\u0917\u0924 \u092b\u094d\u0930\u0940 \u092b\u093e\u092f\u0930 BR \u092a\u094d\u0930\u0924\u093f\u092f\u094b\u0917\u093f\u0924\u093e \u2014 \u0938\u093e\u0901\u091a\u094b \u0907\u0928\u093e\u092e, \u0932\u093e\u0907\u092d \u092c\u094d\u0930\u093e\u0915\u0947\u091f, \u0930\u0941\u092e-ID \u0930 \u0938\u093f\u091c\u0928 \u0932\u093f\u0921\u0930\u092c\u094b\u0930\u094d\u0921\u0964 \u090f\u0915\u094d\u0932\u0948 \u092c\u0928\u093e\u090f\u0915\u094b \u0930 \u091a\u0932\u093e\u090f\u0915\u094b\u0964',see:'\u0915\u0947 \u091a\u0932\u093f\u0930\u0939\u0947\u0915\u094b \u091b \u0939\u0947\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d',discord:'Discord \u092e\u093e \u091c\u094b\u0921\u093f\u0928\u0941\u0939\u094b\u0938\u094d',ttl:'\u092a\u094d\u0930\u0924\u093f\u092f\u094b\u0917\u093f\u0924\u093e',ttag:'\u0932\u093e\u0907\u092d + \u0906\u0909\u0901\u0926\u0948',howttl:'\u0915\u0938\u0930\u0940 \u0938\u0939\u092d\u093e\u0917\u0940 \u0939\u0941\u0928\u0947',s1t:'\u0938\u093e\u0907\u0928 \u0905\u092a \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d',s1d:'\u0928\u093f\u0903\u0936\u0941\u0932\u094d\u0915 \u0916\u093e\u0924\u093e \u092c\u0928\u093e\u0909\u0928\u0941\u0939\u094b\u0938\u094d\u0964 \u0924\u092a\u093e\u0908\u0902\u0915\u094b \u091f\u093f\u092e\u0915\u094b \u0928\u093e\u092e \u0930 \u0932\u094b\u0917\u094b \u0939\u0930\u0947\u0915 \u092a\u094d\u0930\u0924\u093f\u092f\u094b\u0917\u093f\u0924\u093e\u0915\u093e \u0932\u093e\u0917\u093f \u0938\u0947\u092d \u0939\u0941\u0928\u094d\u091b\u0964',s2t:'\u092a\u094b\u0907\u0928\u094d\u091f \u0932\u094b\u0921 \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d',s2d:'\u0935\u093e\u0932\u0947\u091f\u092e\u093e eSewa QR \u092c\u093e\u091f \u0924\u093f\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d \u0930 \u092d\u0941\u0915\u094d\u0924\u093e\u0928\u0940\u0915\u094b \u0938\u094d\u0915\u094d\u0930\u093f\u0928\u0938\u091f \u0905\u092a\u0932\u094b\u0921 \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d\u0964 \u091c\u093e\u0901\u091a\u092a\u091b\u093f \u092a\u094b\u0907\u0928\u094d\u091f \u0925\u092a\u093f\u0928\u094d\u091b (\u0967 \u092a\u094b\u0907\u0928\u094d\u091f = \u0930\u0941 \u0967)\u0964',s3t:'\u092a\u094b\u0907\u0928\u094d\u091f\u0932\u0947 \u091c\u094b\u0907\u0928 \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d',s3d:'\u092a\u094d\u0930\u0924\u093f\u092f\u094b\u0917\u093f\u0924\u093e\u092e\u093e Join \u0925\u093f\u091a\u094d\u0928\u0941\u0939\u094b\u0938\u094d\u0964 \u092b\u094d\u0930\u0940 \u092a\u094d\u0930\u0924\u093f\u092f\u094b\u0917\u093f\u0924\u093e \u0924\u0941\u0930\u0941\u0928\u094d\u0924\u0948 \u092a\u0915\u094d\u0915\u093e \u0939\u0941\u0928\u094d\u091b; \u092a\u0947\u0921 \u092a\u094d\u0930\u0935\u0947\u0936 \u0936\u0941\u0932\u094d\u0915 \u092a\u094b\u0907\u0928\u094d\u091f\u092c\u093e\u091f \u0915\u093e\u091f\u093f\u0928\u094d\u091b\u0964',s4t:'\u0938\u094d\u0932\u091f \u092a\u0915\u094d\u0915\u093e',s4d:'\u0938\u094d\u0915\u094d\u0935\u093e\u0921 \u092a\u0915\u094d\u0915\u093e \u092d\u090f\u092a\u091b\u093f \u0924\u092a\u093e\u0908\u0902 \u0916\u0947\u0932\u094d\u0928\u0941\u0939\u0941\u0928\u094d\u091b\u0964 \u091a\u0947\u0915-\u0907\u0928 \u091a\u093e\u0939\u093f\u0901\u0926\u0948\u0928\u0964',s5t:'Room ID \u092a\u093e\u0909\u0928\u0941\u0939\u094b\u0938\u094d',s5d:'\u0916\u0947\u0932 \u0938\u0941\u0930\u0941 \u0939\u0941\u0928\u0941\u092d\u0928\u094d\u0926\u093e \u0915\u0930\u093f\u092c \u096b \u092e\u093f\u0928\u0947\u091f\u0905\u0918\u093f Room ID \u0930 \u092a\u093e\u0938\u0935\u0930\u094d\u0921 \u0924\u092a\u093e\u0908\u0902\u0915\u094b \u091f\u093f\u0915\u091f\u092e\u093e \u0926\u0947\u0916\u093f\u0928\u094d\u091b\u0964',evpast:'📅 \u092a\u0941\u0930\u093e\u0928\u093e \u092a\u094d\u0930\u0924\u093f\u092f\u094b\u0917\u093f\u0924\u093e \u2192',evlb:'🏆 \u0932\u093f\u0921\u0930\u092c\u094b\u0930\u094d\u0921 \u2192',tuttag:'\u0938\u093f\u0915\u093e\u0907',openwallet:'\u0935\u093e\u0932\u0947\u091f \u0916\u094b\u0932\u094d\u0928\u0941\u0939\u094b\u0938\u094d \u2192',evnav:'📅 \u092a\u094d\u0930\u0924\u093f\u092f\u094b\u0917\u093f\u0924\u093e',wacta:'WhatsApp \u092e\u093e \u0926\u0930\u094d\u0924\u093e \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d',lbttl:'\u0938\u093f\u091c\u0928 \u0932\u093f\u0921\u0930\u092c\u094b\u0930\u094d\u0921',lbtag:'\u0938\u094d\u091f\u094d\u092f\u093e\u0928\u094d\u0921\u093f\u0919',about:'\u092c\u093e\u0930\u0947\u092e\u093e',reg:'\u0926\u0930\u094d\u0924\u093e \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d',regwa:'WhatsApp \u092e\u093e \u0926\u0930\u094d\u0924\u093e',join:'\u0939\u0947\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d / \u091c\u094b\u0921\u093f\u0928\u0941\u0939\u094b\u0938\u094d',soon:'\u0926\u0930\u094d\u0924\u093e \u091a\u093e\u0901\u0921\u0948 \u0916\u0941\u0932\u094d\u0926\u0948',livenow:'\u0905\u0939\u093f\u0932\u0947 \u0932\u093e\u0907\u092d',winner:'\u0935\u093f\u091c\u0947\u0924\u093e',livettl:'\u0905\u0939\u093f\u0932\u0947 \u091a\u0932\u093f\u0930\u0939\u0947\u0915\u094b',livetag:'\u0932\u093e\u0907\u092d',schttl:'\u0924\u093e\u0932\u093f\u0915\u093e',ptsttl:'\u0905\u0919\u094d\u0915',th_team:'\u091f\u093f\u092e',th_kills:'\u0915\u093f\u0932',th_place:'\u0938\u094d\u0925\u093e\u0928',th_pts:'\u0905\u0919\u094d\u0915',scheduled:'\u0924\u093e\u0932\u093f\u0915\u093e\u092c\u0926\u094d\u0927',done:'\u0938\u0915\u093f\u092f\u094b',nosched:'\u0924\u093e\u0932\u093f\u0915\u093e \u091a\u093e\u0901\u0921\u0948 \u0906\u0909\u0901\u0926\u0948\u0964',nopts:'\u0916\u0947\u0932 \u0938\u0941\u0930\u0941 \u092d\u090f\u092a\u091b\u093f \u0905\u0919\u094d\u0915 \u0926\u0947\u0916\u093f\u0928\u0947\u091b\u0964',regdc:'Discord \u092e\u093e \u0926\u0930\u094d\u0924\u093e',sqview:'\u0938\u094d\u0915\u094d\u0935\u093e\u0921 \u0939\u0947\u0930\u094d\u0928 \u091b\u0941\u0928\u0941\u0939\u094b\u0938\u094d',sqttl:'\u0926\u0930\u094d\u0924\u093e \u092d\u090f\u0915\u093e \u0938\u094d\u0915\u094d\u0935\u093e\u0921\u0939\u0930\u0942',sqmembers:'\u0938\u0926\u0938\u094d\u092f\u0939\u0930\u0942',sqopen:'\u0916\u093e\u0932\u0940 \u0938\u094d\u0925\u093e\u0928',sqempty:'\u0905\u0939\u093f\u0932\u0947\u0938\u092e\u094d\u092e \u0915\u0941\u0928\u0948 \u0938\u094d\u0915\u094d\u0935\u093e\u0921 \u0926\u0930\u094d\u0924\u093e \u092d\u090f\u0915\u094b \u091b\u0948\u0928 \u2014 \u092a\u0939\u093f\u0932\u094b \u0939\u0941\u0928\u0941\u0939\u094b\u0938\u094d!',scttl:'\u0905\u0919\u094d\u0915 \u0915\u0938\u0930\u0940 \u0926\u093f\u0907\u0928\u094d\u091b',sctag:"\u0938\u094d\u0925\u093e\u0928 + \u0915\u093f\u0932",scintro:"\u0939\u0930\u0947\u0915 \u092e\u094d\u092f\u093e\u091a\u092e\u093e \u0924\u092a\u093e\u0908\u0902\u0915\u094b \u0938\u094d\u0915\u094d\u0935\u093e\u0921\u0932\u0947 \u0906\u0927\u093f\u0915\u093e\u0930\u093f\u0915 \u0930\u0941\u092e \u0928\u0924\u093f\u091c\u093e\u0905\u0928\u0941\u0938\u093e\u0930 \u0938\u094d\u0925\u093e\u0928 \u0905\u0919\u094d\u0915 \u092a\u093e\u0909\u0901\u091b, \u0930 \u0939\u0930\u0947\u0915 \u0915\u093f\u0932\u0915\u094b \u0967 \u0905\u0919\u094d\u0915 \u0925\u092a\u093f\u0928\u094d\u091b\u0964",sckillt:"\u0915\u093f\u0932 \u0905\u0919\u094d\u0915",sckilld:"\u092e\u094d\u092f\u093e\u091a\u092e\u093e \u0924\u092a\u093e\u0908\u0902\u0915\u094b \u0938\u094d\u0915\u094d\u0935\u093e\u0921\u0932\u0947 \u0917\u0930\u0947\u0915\u094b \u0939\u0930\u0947\u0915 \u0915\u093f\u0932\u0915\u094b \u0967 \u0905\u0919\u094d\u0915\u0964",scplacet:"\u091c\u092e\u094d\u092e\u093e",scplaced:"\u0938\u092c\u0948 \u092e\u094d\u092f\u093e\u091a\u0915\u093e \u0938\u094d\u0925\u093e\u0928 \u0905\u0919\u094d\u0915 \u0930 \u0915\u093f\u0932 \u0905\u0919\u094d\u0915 \u091c\u094b\u0921\u093f\u0928\u094d\u091b\u0928\u094d\u0964 \u0938\u092c\u0948\u092d\u0928\u094d\u0926\u093e \u0927\u0947\u0930\u0948 \u091c\u092e\u094d\u092e\u093e \u0905\u0919\u094d\u0915 \u0939\u0941\u0928\u0947 \u0938\u094d\u0915\u094d\u0935\u093e\u0921 \u091c\u093f\u0924\u094d\u091b\u0964",scposh:"\ud83d\udcca \u0938\u094d\u0925\u093e\u0928 \u0905\u0919\u094d\u0915",scposd:"\u0939\u0930\u0947\u0915 \u092e\u094d\u092f\u093e\u091a\u092e\u093e \u0924\u092a\u093e\u0908\u0902\u0915\u094b \u0938\u094d\u0915\u094d\u0935\u093e\u0921 \u0915\u0941\u0928 \u0938\u094d\u0925\u093e\u0928\u092e\u093e \u0938\u0915\u093f\u092f\u094b, \u0924\u094d\u092f\u0938\u0932\u0947 \u0938\u094d\u0925\u093e\u0928 \u0905\u0919\u094d\u0915 \u0926\u093f\u0928\u094d\u091b\u0964 \u0939\u0930\u0947\u0915 \u0915\u093f\u0932\u0932\u0947 \u0967 \u0905\u0919\u094d\u0915 \u0925\u092a\u094d\u091b\u0964",scposex:"\u0909\u0926\u093e\u0939\u0930\u0923: \u092e\u094d\u092f\u093e\u091a \u0967 \u092e\u093e \u092a\u0939\u093f\u0932\u094b (12) + \u092e\u094d\u092f\u093e\u091a \u0968 \u092e\u093e \u0924\u0947\u0938\u094d\u0930\u094b (8) + \u092e\u094d\u092f\u093e\u091a \u0969 \u092e\u093e \u0926\u0936\u094c\u0902 (1) = 21 \u0905\u0919\u094d\u0915\u0964",msttl:'\u092e\u094d\u092f\u093e\u091a \u0938\u0947\u091f\u093f\u0919',mstag:'\u0939\u0930\u0947\u0915 \u092e\u094d\u092f\u093e\u091a\u092e\u093e \u0909\u0938\u094d\u0924\u0948',msintro:'\u0939\u0930\u0947\u0915 \u091f\u0941\u0930\u094d\u0928\u093e\u092e\u0947\u0928\u094d\u091f\u092e\u093e \u0930\u0941\u092e \u0909\u0938\u094d\u0924\u0948 \u0924\u0930\u093f\u0915\u093e\u0932\u0947 \u0938\u0947\u091f\u0905\u092a \u0939\u0941\u0928\u094d\u091b, \u0924\u094d\u092f\u0938\u0948\u0932\u0947 \u0915\u0938\u0948\u0932\u093e\u0908 \u092b\u093e\u0907\u0926\u093e \u0939\u0941\u0901\u0926\u0948\u0928\u0964',msgunt:'\u0917\u0928 \u090f\u091f\u094d\u0930\u093f\u092c\u094d\u092f\u0941\u091f',msgund:'\u0905\u092b \u2014 \u0939\u0924\u093f\u092f\u093e\u0930 \u0938\u094d\u0915\u093f\u0928\u0915\u094b \u0938\u094d\u091f\u094d\u092f\u093e\u091f \u092c\u094b\u0928\u0938 \u0932\u093e\u0917\u0942 \u0939\u0941\u0901\u0926\u0948\u0928\u0964',msskillt:'\u0915\u094d\u092f\u093e\u0930\u0947\u0915\u094d\u091f\u0930 \u0938\u094d\u0915\u093f\u0932',msskilld:'\u0905\u0928 \u2014 \u0924\u092a\u093e\u0908\u0902\u0915\u094b \u0915\u094d\u092f\u093e\u0930\u0947\u0915\u094d\u091f\u0930\u0915\u094b \u090f\u0915\u094d\u091f\u093f\u092d/\u092a\u094d\u092f\u093e\u0938\u093f\u092d \u0938\u094d\u0915\u093f\u0932 \u0938\u093e\u092e\u093e\u0928\u094d\u092f \u0930\u0942\u092a\u092e\u093e \u0915\u093e\u092e \u0917\u0930\u094d\u091b\u0964',msmapt:'\u0928\u0915\u094d\u0938\u093e',msmapd:'\u092b\u0941\u0932 \u092e\u094d\u092f\u093e\u092a, \u0938\u093e\u092e\u093e\u0928\u094d\u092f \u0938\u0947\u091f\u093f\u0919 \u2014 \u091c\u094b\u0928 \u0938\u0927\u0948\u0902 \u091c\u0938\u094d\u0924\u0948 \u0938\u093e\u0901\u0918\u0941\u0930\u093f\u0928\u094d\u091b, \u0924\u094d\u092f\u0938\u092e\u093e \u0915\u0941\u0928\u0948 \u092a\u0930\u093f\u0935\u0930\u094d\u0924\u0928 \u091b\u0948\u0928\u0964'}
};
let lang=lsGet('jd_lang')||'en';
function tr(k){return (T[lang]&&T[lang][k]!=null)?T[lang][k]:(T.en[k]!=null?T.en[k]:k)}
function applyLang(){
  document.documentElement.lang=lang;
  if(window.jdTabbarLang)window.jdTabbarLang(lang);
  document.querySelectorAll('[data-i18n]').forEach(function(el){var k=el.getAttribute('data-i18n');var v=tr(k);if(el.dataset.html==='1')el.innerHTML=v;else el.textContent=v;});
  var lb=document.getElementById('lang-btn');if(lb)lb.textContent=lang==='en'?'\u0928\u0947\u092a\u093e\u0932\u0940':'EN';
  var hc=document.getElementById('howto-cta');if(hc)hc.innerHTML=(typeof WHATSAPP_NUMBER==='string'&&WHATSAPP_NUMBER)?('<a class="btn-primary" href="'+esc(waLink(WA_DEFAULT_MSG))+'" target="_blank" rel="noopener">'+tr('wacta')+'</a>'):'';
  if(typeof zChrome==='function')zChrome();
  renderCur();
}
function toggleLang(){lang=lang==='en'?'ne':'en';lsSet('jd_lang',lang);applyLang();}
// ESC closes whichever modal overlay is currently open — checked in this order so
// only the topmost/most-recently-relevant one closes on a single press. authClose()
// already no-ops while the login gate is forced open, so this can't escape that.
document.addEventListener('keydown',e=>{
  if(e.key!=='Escape')return;
  const closers={'auth-overlay':authClose,'reg-overlay':regClose,'notif-overlay':notifHistClose,'roster-overlay':rosterClose,'msg-overlay':msgClose,'confirm-overlay':()=>confirmClose(false),'fx-overlay':fxShopClose,'regsuccess-overlay':regSuccessClose};
  for(const id in closers){
    const el=document.getElementById(id);
    if(el&&el.classList.contains('open')){closers[id]();break;}
  }
});
/* ── live public roster (Supabase) ──────────────────────────────────────────
   Squad names/logos on cards used to come straight from tournaments.json —
   hand-typed by the admin, so real in-app registrations never showed up there
   and the count never moved. get_public_roster() (see supabase/schema.sql) is
   a SECURITY DEFINER RPC that safely exposes just squad_name/squad_logo/
   tournament_slug/registered_at for confirmed+approved rows (never player_id
   or payment_screenshot) so anyone can read the real, live roster. Once it's
   loaded, it fully replaces the JSON's teams field for every render — no
   more manual "Squad 1 / Squad 2" placeholders to keep in sync by hand. */
let _liveRoster=new Map();  // tournament name -> [{squad_name, squad_logo}]
let _rosterCached=false;
let _rosterLoaded=false;
let _allTime=null,_arenaStats=null;
/* First-ever visit: wait for real data instead of flashing the built-in sample (its numbers would jump);
   the sample only appears if nothing real arrives within 7 s (offline / site down). */
let _sampleOK=false;
function renderCur(){if(_lastData)render(_lastData);else if(_sampleOK)render(ARENA_SAMPLE);}
setTimeout(()=>{if(!_lastData){_sampleOK=true;renderCur();}},7000);
/* Steady first paint: the last REAL data this browser saw (tournaments + all-time totals) is drawn at
   once, so a visit no longer flips sample data -> GitHub copy -> totals with the numbers jumping each
   time. ARENA_SAMPLE is only a fallback when nothing real has ever loaded. Refreshed after every render. */
const SNAP_KEY='jd_snap_v1';
let _snapBoot=false,_snapT=0;
(function(){try{const sn=JSON.parse(lsGet(SNAP_KEY)||'null');
  if(sn&&sn.doc&&Array.isArray(sn.doc.tournaments)){_lastData=sn.doc;_lastData._live=true;
    _allTime=sn.allTime?new Map(sn.allTime):null;_arenaStats=sn.stats||null;_snapBoot=true;}}catch(e){}})();
function saveSnap(){
  if(!_lastData||!_lastData._live)return;
  clearTimeout(_snapT);
  _snapT=setTimeout(()=>{try{lsSet(SNAP_KEY,JSON.stringify({doc:_lastData,allTime:_allTime?[..._allTime]:null,stats:_arenaStats}));}catch(e){}},1500);
}
// counts a stat up from its current number (only when it changes, so the 5s refresh doesn't replay it)
function setStat(id,n){
  const el=document.getElementById(id);if(!el)return;
  if(el.dataset.v==null&&_snapBoot){el.dataset.v=n;el.textContent=n.toLocaleString();return;}  // cached visit: no count-up replay
  const from=+(el.dataset.v||0);if(from===n&&el.dataset.v!=null)return;
  el.dataset.v=n;const t0=performance.now(),dur=900;
  const step=t=>{const k=Math.min(1,(t-t0)/dur),e=1-Math.pow(1-k,3);el.textContent=Math.round(from+(n-from)*e).toLocaleString();if(k<1)requestAnimationFrame(step);else{el.classList.remove('pop');void el.offsetWidth;el.classList.add('pop');}};
  requestAnimationFrame(step);
}  // tournament slug -> squads ever registered (get_arena_totals, includes past events)
// The roster carries every squad logo (~370 KB), so the 5 s poll only reads its fingerprint
// (public_roster_version, roster_version.sql) and downloads the roster when something changed.
// Called without arguments (after joining, withdrawing...) it always reloads.
let _rosterVer=null;
async function loadPublicRoster(poll){
  if(!sb)return;
  if(poll&&_rosterLoaded){
    const v=await sb.rpc('public_roster_version');
    if(!v.error&&v.data===_rosterVer)return;
    if(!v.error)_rosterVer=v.data;
  }
  const [{data,error},tot,st,ver]=await Promise.all([sb.rpc('get_public_roster'),sb.rpc('get_arena_totals'),sb.rpc('get_arena_stats'),poll?null:sb.rpc('public_roster_version')]);
  if(ver&&!ver.error)_rosterVer=ver.data;
  if(!st.error&&st.data&&st.data[0])_arenaStats=st.data[0];
  if(!tot.error&&tot.data)_allTime=new Map(tot.data.map(r=>[r.tournament_slug,r.squads||0]));
  if(error)return;
  const m=new Map();
  (data||[]).forEach(r=>{
    if(!m.has(r.tournament_slug))m.set(r.tournament_slug,[]);
    m.get(r.tournament_slug).push({squad_name:r.squad_name,squad_logo:r.squad_logo,effect:r.effect||'',pass:r.pass_tier||''});
  });
  _liveRoster=m;_rosterLoaded=true;
  rosterSave(m);
  renderCur();
}
/* The real squad list (registrations) is kept on the device, so the next open - or the app offline - shows the same
   squads every other device sees, never the admin's old typed list. Logos over ~12 KB are left out to stay small. */
function rosterSave(m){
  try{const o={};m.forEach((v,k)=>{o[k]=v.map(x=>({squad_name:x.squad_name,squad_logo:x.squad_logo&&x.squad_logo.length<12000?x.squad_logo:'',effect:x.effect,pass:x.pass}));});
    localStorage.setItem('jd_roster_v1',JSON.stringify({at:Date.now(),r:o}));}catch(e){}
}
(function rosterRestore(){
  try{const c=JSON.parse(localStorage.getItem('jd_roster_v1')||'null');
    if(c&&c.r&&Date.now()-c.at<7*864e5){_liveRoster=new Map(Object.entries(c.r));_rosterCached=true;}}catch(e){}
})();
function teamsFor(t){
  if(sb&&(_rosterLoaded||_rosterCached)){
    const live=_liveRoster.get(t.name);
    // Falls back to the admin-curated Manual squad list only when NOTHING has
    // actually self-registered for this tournament yet — once even one real
    // squad joins, the live roster takes over for name/logo/members (never a
    // mix of both there). Special effects are the one thing still looked up
    // from the Manual squad list by name — that's the only place they're set
    // (via "Load from live roster" + the effect dropdown), so without this a
    // real squad's effect would flash in on the first render (before the live
    // roster finishes loading) and then vanish the moment it does.
    if(live&&live.length){
      const fxByName=new Map((Array.isArray(t.teams)?t.teams:[]).map(x=>[String(x.name||'').trim().toLowerCase(),x.effect||'']));
      return live.map(x=>({name:x.squad_name||'Squad',logo:x.squad_logo||'',members:[],pass:x.pass||'',effect:x.effect||fxByName.get(String(x.squad_name||'').trim().toLowerCase())||''}));
    }
    // sign-ups happen in the app, so an event that isn't finished shows only who is really registered (even none) -
    // the typed list is only for old events that ran before in-app sign-up
    if(_rosterLoaded&&effectiveStatus(t)!=='completed')return [];
  }
  return Array.isArray(t.teams)?t.teams.map(x=>typeof x==='string'?{name:x,logo:'',members:[],effect:''}:{name:x.name,logo:x.logo||'',members:x.members||[],effect:x.effect||''}).filter(x=>x&&x.name):[];
}
/* "upcoming" flips to "live" on its own once the start time passes — one less
   thing the admin has to remember to toggle. "live" -> "completed" stays a
   manual admin action since only a human can declare a winner. */
// "500" / "1,000" typed bare in the editor reads as a currency amount, not a mystery number
/* Map image per event (maps/ff-*.jpg — the real Free Fire top-down maps, from the Free Fire
   wiki; © Garena). The admin picks the map; events saved before the field existed show Bermuda,
   the main battle royale map. A custom t.image still wins. */
const MAP_ART={bermuda:'Bermuda',purgatory:'Purgatory',kalahari:'Kalahari',alpine:'Alpine',nexterra:'NeXTerra'};
function mapOf(t){const k=String(t.map||'').toLowerCase();return MAP_ART[k]?k:'bermuda';}
/* Best of 3 (map2 / map3 set): one map per match, 'random' = picked when the room is made. */
/* Card picture for a best of 3: the three maps side by side, labelled M1 / M2 / M3 (🎲 tile for Random). */
function mapsStrip(t){
  return '<div class="tm-maps" aria-hidden="true">'+[t.map,t.map2,t.map3].map((k,i)=>{
    k=String(k||'random').toLowerCase();const m=MAP_ART[k];
    return `<div class="tm-map${m?'':' rnd'}"${m?` style="background-image:url('maps/ff-${k}.webp')"`:''}><b>M${i+1}</b><span>${m||'🎲 Random'}</span></div>`;
  }).join('')+'</div>';
}
function mapsText(t){
  if(!t.map2&&!t.map3)return '🗺️ '+MAP_ART[mapOf(t)];
  const n=k=>{k=String(k||'random').toLowerCase();return MAP_ART[k]||'🎲 Random';};
  return [t.map,t.map2,t.map3].map(n).join(' · ');
}
function fmtPrize(p){const v=String(p==null?'':p).trim();if(!v)return '—';return /^\d[\d,]*$/.test(v)?'Rs '+Number(v.replace(/,/g,'')).toLocaleString('en-IN'):v;}
function effectiveStatus(t){
  const s=(t.status||'upcoming').toLowerCase();
  // a declared winner means the event is over — the card flips to the champion even if
  // the admin typed the winner but didn't also switch the status to "completed"
  if(s!=='cancelled'&&String(t.winner||'').trim())return 'completed';
  if(s==='upcoming'&&t.start){
    const startMs=Date.parse(t.start);
    if(!isNaN(startMs)&&Date.now()>=startMs)return 'live';
  }
  return s;
}

/* Polled every 5s (see the setInterval below) so slot counts/roster feel live without a
   page reload — but re-writing arena-grid's innerHTML every tick would replay every squad
   chip's entrance animation (.troster > span's chipIn) and the slot-bar width transition on
   every single poll, even when nothing changed. So the grid HTML is only actually written
   when it differs from last time; ticks where nothing moved are a no-op past this point. */
let _lastGridHTML=null;
const CHIP_MAX=8; // squad chips shown on a card before collapsing into "+N more" (opens the full roster)
/* Results published without picking their tournament (bo3.tournament blank) belong to the
   event that started most recently — that's the one being played or just finished. */
function linkBo3(d){
  const B=d&&d.bo3;if(!B||B.tournament)return;
  const cand=(d.tournaments||[]).filter(t=>{const st=effectiveStatus(t);return st==='live'||st==='completed';}).sort((a,b)=>(Date.parse(b.start)||0)-(Date.parse(a.start)||0));
  if(cand[0])B.tournament=cand[0].name;
}
/* ── broadcast LIVE/NEXT bug + news ticker in the hero (styles in /broadcast.css) ──
   Built from the same tournaments.json data as the cards: LIVE only when an event really
   is live (effectiveStatus), otherwise NEXT with a countdown; hidden when nothing is on.
   Only rewritten when its content changes, so the 5-second poll doesn't restart the scroll. */
let _bcBugKey='',_bcTkHTML='',_bcStart=0;
function bcRender(d){
  const bug=document.getElementById('bc-bug'),tk=document.getElementById('bc-ticker'),track=document.getElementById('bc-tk-track');
  if(!bug||!tk||!track)return;
  const ne=lang==='ne',ts=d.tournaments||[],now=Date.now();
  const live=ts.filter(t=>effectiveStatus(t)==='live').sort((a,b)=>(Date.parse(b.start)||0)-(Date.parse(a.start)||0))[0];
  const ups=ts.filter(t=>effectiveStatus(t)==='upcoming').sort((a,b)=>(Date.parse(a.start)||9e15)-(Date.parse(b.start)||9e15));
  const next=ups.find(t=>Date.parse(t.start)>now);
  const ev=live||next;
  const key=ev?[live?'L':'N',ev.name,ev.start,lang].join('|'):'';
  if(key!==_bcBugKey){
    _bcBugKey=key;
    if(!ev){bug.hidden=true;_bcStart=0;}
    else{
      bug.hidden=false;bug.className='bc-bug '+(live?'live':'next');
      const tag=live?'<span class="bc-dot" aria-hidden="true"></span>'+(ne?'लाइभ':'LIVE'):(ne?'अर्को':'NEXT');
      bug.innerHTML=`<span class="bc-tag">${tag}</span><span class="bc-name">${esc(ev.name)}</span><span class="bc-time" id="bc-time"></span>`;
      bug.setAttribute('aria-label',(live?'Live now: ':'Next: ')+ev.name);
      _bcStart=live?0:Date.parse(ev.start);
      const tm=document.getElementById('bc-time');if(tm&&live)tm.textContent=ev.prize?(ne?'इनाम ':'PRIZE ')+ev.prize:(ne?'अहिले':'ON AIR');
      bcTick();
    }
  }
  // ticker items
  const items=[];
  const prize=t=>t.prize&&t.prize!=='—'?` · ${ne?'इनाम':'Prize'} <em>${esc(t.prize)}</em>`:'';
  const slotsOf=t=>{const sl=+t.slots||0,rg=teamsFor(t).length||+t.registered||0;return sl?` · ${rg}/${sl} ${ne?'स्क्वाड':'squads'}`:'';};
  if(live)items.push(`<span class="bc-tk-item">🔴 <b>${esc(live.name)}</b> ${ne?'अहिले लाइभ':'is live now'}${prize(live)}</span>`);
  ups.slice(0,3).forEach(t=>items.push(`<span class="bc-tk-item"><b>${esc(t.name)}</b> ${esc([t.date,t.time].filter(x=>x&&x!=='—').join(' · ')||'TBA')}${prize(t)}${slotsOf(t)}${/^free$/i.test(String(t.entry||'').trim())?' · '+(ne?'निःशुल्क':'Free entry'):''}</span>`));
  const done=ts.filter(t=>effectiveStatus(t)==='completed').sort((a,b)=>(Date.parse(b.start)||0)-(Date.parse(a.start)||0));
  done.slice(0,2).forEach(t=>{const w=winnerOf(t,d);if(w)items.push(`<span class="bc-tk-item">🏆 <b>${esc(w)}</b> ${ne?'ले जित्यो':'won'} ${esc(t.name)}</span>`);});
  try{const rows=(d.bo3&&d.bo3.published&&d.bo3.teams&&d.bo3.teams.length)?bo3Standings(d.bo3):[];if(rows[0])items.push(`<span class="bc-tk-item">${ne?'शीर्ष':'Top of the table'}: <b>${esc(rows[0].team)}</b> <em>${rows[0].totalPts||0} ${ne?'अङ्क':'pts'}</em></span>`);}catch(e){}
  items.push(`<span class="bc-tk-item">⚔️ <b>${ne?'क्ल्यास स्क्वाड':'Clash Squad challenges'}</b> ${ne?'२४/७ खुला — JD अंक जित्नुहोस्':'open 24/7 — 1v1 to 4v4, win JD points'}</span>`);
  if(items.length<2){tk.hidden=true;document.querySelector('.hero').classList.remove('has-ticker');return;}
  const set=items.join('');
  const html=`<div class="bc-tk-set">${set}</div><div class="bc-tk-set" aria-hidden="true">${set}</div>`;
  if(html!==_bcTkHTML){
    _bcTkHTML=html;track.innerHTML=html;
    track.style.setProperty('--bc-dur',Math.max(24,items.length*9)+'s');
    const lb=document.getElementById('bc-tk-label');if(lb)lb.textContent=ne?'समाचार':'Arena';
  }
  tk.hidden=false;document.querySelector('.hero').classList.add('has-ticker');
}
function bcTick(){
  const el=document.getElementById('bc-time');if(!el||!_bcStart)return;
  let ms=_bcStart-Date.now();
  if(ms<=0){el.textContent=lang==='ne'?'सुरु हुँदैछ':'STARTING';return;}
  const dd=Math.floor(ms/864e5),hh=Math.floor(ms%864e5/36e5),mm=Math.floor(ms%36e5/6e4),ss=Math.floor(ms%6e4/1e3),p=n=>String(n).padStart(2,'0');
  el.textContent=(dd?dd+'D ':'')+p(hh)+':'+p(mm)+':'+p(ss);
}
setInterval(bcTick,1000);
function render(d){
  linkBo3(d);
  _lastData=d;
  saveSnap();
  try{bcRender(d);}catch(e){}
  const grid=document.getElementById('arena-grid');if(!grid)return;
  // The section is "Live + Upcoming", so show it that way: live, then upcoming soonest
  // first, then finished newest first, cancelled last (tournaments.json is in admin order).
  // No/blank start (date TBA) sorts after dated events, not before them as epoch 0 would.
  const stOrder={live:0,upcoming:1,completed:2,cancelled:3},tms=t=>Date.parse(t.start)||Number.MAX_SAFE_INTEGER;
  const ts=(d.tournaments||[]).slice().sort((a,b)=>{
    const sa=stOrder[effectiveStatus(a)]??1,sb2=stOrder[effectiveStatus(b)]??1;
    if(sa!==sb2)return sa-sb2;
    return sa<=1?tms(a)-tms(b):(Date.parse(b.start)||0)-(Date.parse(a.start)||0);
  });
  const upcoming=ts.filter(t=>{const x=effectiveStatus(t);return x!=='completed'&&x!=='cancelled';});
  let gridHTML=upcoming.length?upcoming.map(t=>{
    const st=effectiveStatus(t);
    const teams=teamsFor(t);
    const slots=+t.slots||0,reg=(sb&&_rosterLoaded)?teams.length:(teams.length||+t.registered||0),pct=slots?Math.min(100,Math.round(reg/slots*100)):0;
    const full=slots>0&&reg>=slots&&st!=='completed'&&st!=='cancelled'&&!_myRegs.has(t.name);
    let btn;
    if(st==='cancelled')btn=`<span class="tbtn done">Cancelled</span>`;
    else if(st==='completed'){const w=winnerOf(t,d),wf=w?fxForSquad(t.name,w):null;btn=`<span class="tbtn done win">🏆 ${tr('winner')}: <b>${w?fxText(wf.fx,w):'TBA'}</b></span>`;}
    // Free tournaments waitlist via inAppRegBtn's "Join Waitlist" button below — don't also
    // show a static "Squads full" label right next to an actual clickable CTA that contradicts
    // it. Paid tournaments (no waitlist yet) and non-Supabase deploys still show it plainly.
    else if(full)btn=(sb&&!isPaidTournament(t))?'':`<span class="tbtn done">Squads full</span>`;
    else{const r=regLink(t);
      if(r){var lbl=st==='live'?tr('join'):(t.register_type==='discord'?tr('regdc'):(t.register_type==='url'?tr('reg'):((typeof WHATSAPP_NUMBER==='string'&&WHATSAPP_NUMBER)?tr('regwa'):tr('reg'))));btn=`<a class="tbtn" href="${esc(r)}" target="_blank" rel="noopener">${lbl}</a>`;}
      // No WhatsApp/Discord/URL link configured. If in-app registration (Supabase) is
      // available, that's the real, already-open path — the "Join" button below covers
      // it, so don't also claim registration is "opening soon" right next to it. Only
      // say that when there's genuinely no way to register at all.
      else if(sb)btn='';
      else btn=`<span class="tbtn done">${st==='live'?tr('livenow'):tr('soon')}</span>`;}
    const left=slots?Math.max(0,slots-reg):null;
    const open=st==='upcoming'||st==='live';
    const urgency=(open&&slots&&!_myRegs.has(t.name))?(left===0?`<span class="tm-urg full">Full${(sb&&!isPaidTournament(t))?' · waitlist open':''}</span>`:(left<=3?`<span class="tm-urg hot">🔥 ${left} slot${left===1?'':'s'} left</span>`:'')):'';
    const prizeTxt=fmtPrize(t.prize),entryTxt=String(t.entry||'Free');
    const host=String(t.host||'').replace(/^@+/,'').trim();
    const org=host?`<span class="tm-org host" title="Run by partner host @${esc(host)}"><i>${esc(host.charAt(0).toUpperCase())}</i>Hosted by @${esc(host)}</span>`
                  :`<span class="tm-org" title="Official JD Esports event"><img src="/logo.webp" alt="">JD Official</span>`;
    const bo3=!t.image&&(t.map2||t.map3);
    const media=`<div class="tcard-media${bo3?' bo3':''}" style="background-image:linear-gradient(180deg,rgba(17,24,39,0) 40%,rgba(17,24,39,.92) 100%)${bo3?'':`,url('${esc(t.image||('maps/ff-'+mapOf(t)+'.webp'))}')`}">${bo3?mapsStrip(t):''}${org}<div class="tm-over">${prizeTxt!=='—'?`<span class="tm-prize">🏆 ${esc(prizeTxt)}</span>`:''}<span class="tm-entry${/^free$/i.test(entryTxt.trim())?' free':''}">${/^free$/i.test(entryTxt.trim())?'Free entry':'Entry '+esc(entryTxt)}</span></div>${urgency}</div>`;
    const isPast=st==='completed'||st==='cancelled';
    return `<div class="tcard${isPast?' past':''}" data-tname="${esc(t.name)}" onclick="cardTap(event,this)">${media}<div class="tcard-body"><span class="tbadge ${st}">${st==='live'?'● Live':(st==='cancelled'?'✕ Cancelled':(st.charAt(0).toUpperCase()+st.slice(1)))}</span><div class="tname">${esc(t.name)}</div><div class="tgame">${esc(t.game||'Free Fire')}</div>${(st==='upcoming'&&t.start)?`<div class="tcount" data-start="${esc(t.start)}"></div><div class="tcount-bar"><span></span></div>`:''}<div class="tmeta"><div class="row"><span>Date</span><b>${esc(t.date||'TBA')}${t.time&&t.time!=='—'?' · '+esc(t.time):''}</b></div><div class="row"><span>Format</span><b>${esc(t.format||'BR')}</b></div><div class="row"><span>${t.map2||t.map3?'Maps':'Map'}</span><b>${esc(mapsText(t))}</b></div><div class="row"><span>Platform</span><b>📱 ${esc(platText(t))}</b></div>${host?`<div class="row"><span>Host</span><b>@${esc(host)}</b></div>`:''}</div>${host?`<p class="thost-note">Run by partner host <b>@${esc(host)}</b>: they send the room ID and pay the prize. JD Arena handles sign-up, slots and alerts.</p>`:''}${slots?`<div class="tslots"><span style="width:${pct}%"></span></div><button class="tslots-label" data-roster="${esc(t.name)}">${reg}/${slots} ${tr('sqview')}</button>`:''}${teams.length?`<div class="troster">${teams.slice(0,CHIP_MAX).map(tm=>{const fx=squadFx(tm);const cls=fx?' '+fx.cls:'';const badge=(fx&&fx.badge)?`<span class="fx-badge">${fx.badge}</span> `:'';const particles=fxParticlesHtml(fx);const nameHtml=fxNameHtml(fx,tm.name);return tm.logo?`<span class="${(fx?fx.cls:'')}"><img src="${esc(tm.logo)}" alt="">${badge}${nameHtml}${particles}</span>`:`<span class="nologo${cls}">${badge}${nameHtml}${particles}</span>`;}).join('')}${teams.length>CHIP_MAX?`<button type="button" class="chip-more" data-roster="${esc(t.name)}">+${teams.length-CHIP_MAX} more</button>`:''}</div>`:''}${btn}${inAppRegBtn(t,st,full)}</div></div>`;
  }).join(''):(lang==='ne'?'<p class="ev-empty">अहिले कुनै आगामी प्रतियोगिता छैन — अर्को प्रतियोगिता पहिले Discord मा घोषणा हुन्छ। त्यतिन्जेल <a href="/events/">पुराना प्रतियोगिता</a> हेर्नुहोस्।</p>':'<p class="ev-empty">No upcoming tournaments right now — the next one is announced on Discord first. Meanwhile, see <a href="/events/">past events</a>.</p>');
  // Finished/cancelled events live on /events/ (linked under the grid).
  if(gridHTML!==_lastGridHTML){
    _lastGridHTML=gridHTML;
    grid.innerHTML=gridHTML;
    grid.querySelectorAll('[data-reg]').forEach(b=>b.onclick=()=>registerInApp(b.getAttribute('data-reg')));
    grid.querySelectorAll('[data-checkin]').forEach(b=>b.onclick=()=>checkInForTournament(b.getAttribute('data-checkin')));
    grid.querySelectorAll('[data-confirm]').forEach(b=>b.onclick=()=>confirmAttendance(b.getAttribute('data-confirm')));
    grid.querySelectorAll('[data-pts-entry]').forEach(b=>b.onclick=e=>{e.stopPropagation();payEntryWithPoints(b.getAttribute('data-pts-entry'));});
    grid.querySelectorAll('[data-code-in]').forEach(i=>i.onclick=e=>e.stopPropagation());
    grid.querySelectorAll('[data-fx-buy]').forEach(b=>b.onclick=e=>{e.stopPropagation();fxShopOpen(b.getAttribute('data-fx-buy'));});
    grid.querySelectorAll('[data-cal]').forEach(b=>b.onclick=e=>{e.stopPropagation();calAdd(b.getAttribute('data-cal'));});
    grid.querySelectorAll('[data-gcal]').forEach(a=>a.onclick=e=>e.stopPropagation());
    grid.querySelectorAll('[data-withdraw]').forEach(b=>b.onclick=e=>{e.stopPropagation();withdrawSquad(b.getAttribute('data-withdraw'));});
    grid.querySelectorAll('[data-roster]').forEach(b=>b.onclick=e=>{e.stopPropagation();openRoster(b.getAttribute('data-roster'));});
  }
  updateNextMatch();
  loadReviewSummaries();
  renderBo3Board(d);
  renderPredictBoard(d);
  renderWinnerSpot(d);
  const foot=document.getElementById('arena-foot');if(foot)foot.textContent=d._live?'Live — updates whenever the bracket changes.':'Preview schedule — connect tournaments.json to go live.';
  const statT=document.getElementById('stat-tournaments'),statS=document.getElementById('stat-squads');
  // all-time: every event ever (past ones from the database + the ones listed now), and for
  // each the bigger of its database sign-ups and the squads shown on its card
  const perEvent=new Map(_allTime||[]);
  ts.forEach(t=>perEvent.set(t.name,Math.max(perEvent.get(t.name)||0,teamsFor(t).length)));
  if(statT)setStat('stat-tournaments',perEvent.size);
  if(statS)setStat('stat-squads',[...perEvent.values()].reduce((a,b)=>a+b,0));
  if(_arenaStats){
    setStat('stat-players',_arenaStats.players||0);
    const chw=document.getElementById('stat-ch-wrap');
    // 4 tiles max (2×2 on phones): the logo tile makes way once challenges have been played
    const lw=document.getElementById('stat-logo-wrap');if(lw)lw.hidden=!!_arenaStats.challenges;
    if(chw){chw.hidden=!_arenaStats.challenges;if(_arenaStats.challenges)setStat('stat-challenges',_arenaStats.challenges);}
  }
}
/* Tapping anywhere on a tournament card triggers its primary action — same precedence as
   the visible buttons (external register link wins over in-app if both exist). Taps on an
   inner interactive element (the link/button itself, squad logos) are left alone so their
   own handlers fire natively instead of double-triggering. */
function cardTap(e,el){
  if(e.target.closest('a,button,input,img'))return;
  const t=((_lastData||ARENA_SAMPLE).tournaments||[]).find(x=>x.name===el.dataset.tname);
  if(!t)return;
  const st=effectiveStatus(t);
  if(st==='completed'){openRoster(t.name);return;} // past-event row: tap shows who played
  if(st==='cancelled')return;
  const r=regLink(t);
  if(r){window.open(r,'_blank','noopener');return;}
  if(sb&&!_myRegs.has(t.name))registerInApp(t.name);
}
/* ── Best-of-3 standings: cumulative points/kills after R1, R1+R2, R1+R2+R3, ranked
   desc by points (tie-break: total kills desc, then name) at each stage. The R2/R3
   movement arrows compare each team's rank at consecutive cumulative stages — i.e. did
   they gain or lose position once that round's score was added in. ── */
function bo3Standings(bo3){
  const teams=(bo3&&bo3.teams)||[];
  const kp=+(bo3&&bo3.kill_pts)||0;   // points per kill (2026-10-25: 1); boards from before have none = kills 0 pts
  const stageTotals=upto=>teams.map(t=>{
    let pts=0,kills=0;
    for(let i=0;i<=upto;i++){const k=+((t.r&&t.r[i]&&t.r[i].kills)||0);pts+=+((t.r&&t.r[i]&&t.r[i].pts)||0)+k*kp;kills+=k;}
    return {team:t.team,pts,kills};
  });
  const rankOf=stage=>{
    const sorted=stage.slice().sort((a,b)=>b.pts-a.pts||b.kills-a.kills||String(a.team).localeCompare(String(b.team)));
    const m=new Map();sorted.forEach((x,i)=>m.set(x.team,i+1));return m;
  };
  const s1=stageTotals(0),s2=stageTotals(1),s3=stageTotals(2);
  const rk1=rankOf(s1),rk2=rankOf(s2),rk3=rankOf(s3);
  const arrow=(cur,prev)=>cur==null||prev==null?'same':cur<prev?'up':cur>prev?'down':'same';
  const totalOf=(stage,team)=>{const x=stage.find(s=>s.team===team);return x?x.pts:0;};
  return teams.map(t=>({
    team:t.team,logo:t.logo,
    r1k:+((t.r&&t.r[0]&&t.r[0].kills)||0),
    r2k:+((t.r&&t.r[1]&&t.r[1].kills)||0),
    r3k:+((t.r&&t.r[2]&&t.r[2].kills)||0),
    totalPts:totalOf(s3,t.team),
    rank:rk3.get(t.team),
    moveR2:arrow(rk2.get(t.team),rk1.get(t.team)),
    moveR3:arrow(rk3.get(t.team),rk2.get(t.team))
  })).sort((a,b)=>a.rank-b.rank);
}
function mvArrow(m){return m==='up'?'<span class="mv mv-up">▲</span>':m==='down'?'<span class="mv mv-down">▼</span>':'<span class="mv mv-same">–</span>';}
/* Winner spotlight: the champion of the most recently finished event, shown for 14 days
   after it starts. Only rewritten when its HTML changes (render() runs every 5s), and the
   confetti/pop entrance plays once per event per browser (localStorage), not every visit. */
let _lastSpotHTML=null;
const SPOT_DAYS=14;
function renderWinnerSpot(d){
  const box=document.getElementById('winner-spot');if(!box)return;
  const done=(d.tournaments||[]).filter(t=>effectiveStatus(t)==='completed'&&winnerOf(t,d)).filter(t=>{const s=Date.parse(t.start);return isNaN(s)||Date.now()-s<SPOT_DAYS*864e5;});
  done.sort((a,b)=>(Date.parse(b.start)||0)-(Date.parse(a.start)||0));
  const t=done[0];
  if(!t){if(_lastSpotHTML!==''){box.hidden=true;box.innerHTML='';_lastSpotHTML='';}return;}
  const w=winnerOf(t,d),f=fxForSquad(t.name,w),fx=f.fx;
  const B=d.bo3,rows=(B&&B.published&&B.tournament===t.name&&B.teams&&B.teams.length)?bo3Standings(B):[];
  const row=rows.find(r=>fxKey(r.team)===fxKey(w));
  const logo=(row&&row.logo)||f.logo;
  const prize=fmtPrize(t.prize);
  const ru=rows.filter(r=>fxKey(r.team)!==fxKey(w)).slice(0,2);
  const mini=r=>{const lf=fxForSquad(t.name,r.team),lg=r.logo||lf.logo;return lg?`<img src="${esc(lg)}" alt="">`:esc(String(r.team||'?').trim().charAt(0).toUpperCase());};
  const ruCard=(r,i)=>r?`<div class="ws-ru r${i+2}"><span class="ws-medal">${i?'🥉':'🥈'}</span><span class="ws-mini">${mini(r)}</span><span class="ws-plc">${i?'3rd':'2nd'}</span><b>${fxText(fxForSquad(t.name,r.team).fx,r.team)}</b><small><em>${r.totalPts}</em> pts</small></div>`:'<div></div>';
  const stat=(v,l,pre)=>`<div class="ws-stat"><b${typeof v==='number'?` data-count="${v}"`:''}>${pre||''}${typeof v==='number'?v.toLocaleString('en-IN'):esc(v)}</b><span>${l}</span></div>`;
  const prizeNum=/^Rs [\d,]+$/.test(prize)?Number(prize.replace(/\D/g,'')):null;
  const html=`<div class="ws"><div class="ws-bg" role="img" aria-label="Free Fire gameplay"></div><div class="ws-rays" aria-hidden="true"></div><div class="ws-in">`+
    `<span class="ws-eye">🏆 Champions</span><div class="ws-title" aria-hidden="true">Booyah!</div><div class="ws-ev"><b>${esc(t.name)}</b>${t.date?' · '+esc(t.date):''}</div>`+
    `<div class="ws-pod">${ruCard(ru[0],0)}<div class="ws-champ"><div class="ws-av${fx?' fxa-'+fx.key:''}"><span class="ws-crown">👑</span>${logo?`<img src="${esc(logo)}" alt="">`:esc(w.charAt(0).toUpperCase())}</div>`+
    `<div class="ws-name">${fxText(fx,w,true)}</div><div class="ws-lbl">🏆 ${tr('winner')}</div></div>${ruCard(ru[1],1)}</div>`+
    `<div class="ws-stats">${prize!=='—'?(prizeNum!=null?stat(prizeNum,'Prize','Rs '):stat(prize,'Prize')):''}${row?stat(row.totalPts,'Points'):''}</div>`+
    `<div class="ws-acts">${rows.length?`<a class="ws-cta" href="/leaderboard.html">Full results →</a>`:''}<button type="button" class="ws-share" data-share="${esc(w)}" data-ev="${esc(t.name)}">📣 Share</button></div>`+
    `</div></div>`;
  if(html===_lastSpotHTML)return;
  _lastSpotHTML=html;box.innerHTML=html;box.hidden=false;
  const key='jd-ws-seen:'+t.name+':'+w;let seen=true;
  try{seen=!!localStorage.getItem(key);if(!seen)localStorage.setItem(key,'1');}catch(e){}
  const sh=box.querySelector('.ws-share');
  if(sh)sh.onclick=async()=>{
    const text=`🏆 ${sh.dataset.share} won ${sh.dataset.ev} on JD Esports Arena! Booyah! 🔥`,url='https://jdesport.co.uk/';
    if(navigator.share){try{await navigator.share({title:'JD Arena champions',text,url});}catch(e){}return;}
    try{await navigator.clipboard.writeText(text+' '+url);sh.textContent='✅ Copied';setTimeout(()=>{sh.textContent='📣 Share';},1800);}catch(e){}
  };
  // stat numbers count up the first time the banner scrolls into view (skipped with reduced motion)
  if(!matchMedia('(prefers-reduced-motion:reduce)').matches&&'IntersectionObserver' in window){
    const nums=[...box.querySelectorAll('[data-count]')];
    nums.forEach(n=>{n.dataset.final=n.textContent;n.textContent=n.textContent.replace(/[\d,]+/,'0');});
    const io=new IntersectionObserver(es=>{if(!es.some(e=>e.isIntersecting))return;io.disconnect();
      const t0=performance.now(),dur=1100;
      const step=now=>{const k=Math.min(1,(now-t0)/dur),ease=1-Math.pow(1-k,3);
        nums.forEach(n=>{n.textContent=n.dataset.final.replace(/[\d,]+/,Math.round(+n.dataset.count*ease).toLocaleString('en-IN'));});
        if(k<1)requestAnimationFrame(step);};
      requestAnimationFrame(step);},{threshold:.4});
    io.observe(box);
  }
  if(!seen){
    const ws=box.querySelector('.ws');ws.classList.add('celebrate');
    const cols=['#FFD54A','#ff6b3d','#5fd3ff','#c86bff','#54e0a0','#fff'];
    for(let i=0;i<36;i++){const c=document.createElement('i');c.className='ws-conf';c.style.left=(Math.random()*100)+'%';c.style.background=cols[i%cols.length];c.style.animationDelay=(Math.random()*.8)+'s';ws.appendChild(c);setTimeout(()=>c.remove(),3800);}
  }
}
function renderBo3Board(d){
  const sec=document.getElementById('bo3board');if(!sec)return;
  const B=d.bo3;
  const has=B&&B.published&&B.teams&&B.teams.length;
  if(!has){sec.style.display='none';return;}
  sec.style.display='';
  const tl=document.getElementById('bo3-title-line');if(tl)tl.textContent=B.title||B.tournament||'';
  const rows=bo3Standings(B);
  // Top-3 podium (2nd · 1st · 3rd, the classic layout), logo or initial, only once
  // there are at least 3 squads with points so it never shows an empty step.
  const mySquad=((_myRegs.get(B.tournament)||{}).squad_name)||'';
  const pod=document.getElementById('bo3-podium');
  if(pod){
    const top=rows.slice(0,3);
    const step=(r,place)=>{if(!r)return '';const f=fxForSquad(B.tournament,r.team),fx=f.fx,logo=r.logo||f.logo;return `<div class="pod p${place}${r.team===mySquad?' mine':''}">${place===1?'<span class="pod-crown">👑</span>':''}<div class="pod-av${fx?' fxa-'+fx.key:''}">${logo?`<img src="${esc(logo)}" alt="">`:esc(String(r.team||'?').trim().charAt(0).toUpperCase())}</div><div class="pod-name">${fxText(fx,r.team)}</div><div class="pod-pts">${r.totalPts} pts</div><div class="pod-block"><span>${place}</span></div></div>`;};
    pod.innerHTML=top.length>=3&&top.some(r=>r.totalPts>0)?step(top[1],2)+step(top[0],1)+step(top[2],3):'';
  }
  const noKills=!(+B.kill_pts); // kill columns only on boards where kills score
  const kHead=noKills?'':`<th class="num">R1 ${tr('th_kills')}</th><th class="num">R2 ${tr('th_kills')}</th><th class="num">R3 ${tr('th_kills')}</th>`;
  document.getElementById('bo3-table').innerHTML=`<thead><tr><th>${tr('th_rank')}</th><th>${tr('th_team')}</th>${kHead}<th class="num">${tr('th_total')}</th></tr></thead><tbody>${rows.map(r=>`<tr${r.team===mySquad?' class="mine"':''}><td class="rk">${r.rank}</td><td>${fxText(fxForSquad(B.tournament,r.team).fx,r.team,true)}${r.team===mySquad?' <span class="you">YOU</span>':''}</td>${noKills?'':`<td class="num">${r.r1k}</td><td class="num">${r.r2k}${mvArrow(r.moveR2)}</td><td class="num">${r.r3k}${mvArrow(r.moveR3)}</td>`}<td class="tot">${r.totalPts}</td></tr>`).join('')}</tbody>`;
}
/* ── performance prediction: ranks currently-registered squads by season average
   points (get_tournament_squad_history()) and converts that to a win % via softmax —
   a squad with no history yet is scored at the league average rather than 0, so a
   brand-new squad isn't shown as having ~0% chance purely for being new. Only shown
   before real results are in for this bracket (hidden the moment renderBo3Board()
   has something to show instead). */
async function renderPredictBoard(d){
  const sec=document.getElementById('predictboard');if(!sec)return;
  const B=d.bo3||{};
  const hasLiveResults=B.published&&B.teams&&B.teams.length;
  const tournamentName=B.tournament;
  if(!sb||hasLiveResults||!tournamentName){sec.style.display='none';return;}
  try{
    const {data,error}=await sb.rpc('get_tournament_squad_history',{p_tournament_slug:tournamentName});
    if(error||!data||data.length<2){sec.style.display='none';return;}
    const withHistory=data.filter(r=>r.appearances>0);
    const leagueAvg=withHistory.length?withHistory.reduce((s,r)=>s+(+r.avg_points),0)/withHistory.length:10;
    const scored=data.map(r=>({...r,score:r.appearances>0?+r.avg_points:leagueAvg}));
    const TEMP=10; // softmax temperature, tuned for a typical 0-40 season-average-points range
    const exps=scored.map(r=>Math.exp(r.score/TEMP));
    const sumExp=exps.reduce((a,b)=>a+b,0)||1;
    const ranked=scored.map((r,i)=>({...r,prob:exps[i]/sumExp})).sort((a,b)=>b.prob-a.prob);
    sec.style.display='';
    const sub=document.getElementById('predict-sub');if(sub)sub.textContent=tournamentName;
    document.getElementById('predict-table').innerHTML=`<thead><tr><th>#</th><th>Squad</th><th class="num">Season avg pts</th><th class="num">Win %</th></tr></thead><tbody>${ranked.map((r,i)=>`<tr><td class="rk">${i+1}</td><td>${fxText(fxForSquad(tournamentName,r.squad_name).fx,r.squad_name)}</td><td class="num">${r.appearances>0?(+r.avg_points).toFixed(1):'—'}</td><td class="tot">${(r.prob*100).toFixed(0)}%</td></tr>`).join('')}</tbody>`;
  }catch(e){sec.style.display='none';}
}
function tick(){document.querySelectorAll('.tcount').forEach(el=>{const bar=el.nextElementSibling;const s=Date.parse(el.dataset.start);if(isNaN(s)){el.style.display='none';if(bar)bar.style.display='none';return}let diff=s-Date.now();if(diff<=0){el.textContent='⏱ Starting now';if(bar)bar.style.display='none';return}const d=Math.floor(diff/864e5),h=Math.floor(diff%864e5/36e5),m=Math.floor(diff%36e5/6e4),sec=Math.floor(diff%6e4/1e3);el.textContent='⏱ Starts in '+(d?d+'d ':'')+h+'h '+m+'m'+(d?'':' '+sec+'s')})}
/* Two copies of tournaments.json exist: the GitHub Pages file, and the live copy the
   publish-tournaments Edge Function also writes to public.site_content. The Pages file
   lags every publish (rebuild + a CDN cache that can hold it ~10 min, which `no-store`
   alone doesn't bypass), so whichever copy has the newer _published_at wins — admin
   changes show on the very next poll/refresh, and a manually committed newer file still
   beats an older live copy. Polling stays cheap: the live copy is only re-downloaded when
   its updated_at changes, and the Pages URL carries a 20s cache-busting bucket so the CDN
   refetches from GitHub at most that often instead of serving a stale copy for minutes. */
let _pagesDoc=null,_liveDoc=null,_liveStamp=null;
function pubTime(d){return (d&&Date.parse(d._published_at))||0;}
async function pollLiveContent(){
  if(!sb)return;
  const {data,error}=await sb.from('site_content').select('updated_at').eq('key','tournaments').maybeSingle();
  if(error||!data||data.updated_at===_liveStamp)return;
  const full=await sb.from('site_content').select('content,updated_at').eq('key','tournaments').maybeSingle();
  if(!full.error&&full.data&&full.data.content){_liveDoc=full.data.content;_liveStamp=full.data.updated_at;}
}
function fetchPagesDoc(){
  const bust='v='+Math.floor(Date.now()/20000);
  const same=(/^https?:$/.test(location.protocol))?new URL('tournaments.json?'+bust,location.href).href:null;
  const tryGet=u=>u?fetch(u,{cache:'no-store'}).then(r=>r.ok?r.json():Promise.reject()):Promise.reject();
  return tryGet(same).catch(()=>tryGet(TOURNAMENTS_URL+'?'+bust)).then(d=>{_pagesDoc=d;});
}
/* The instant live copy (site_content) is checked every poll - one tiny updated_at read; the GitHub Pages
   copy only once a minute (it lags publishes anyway). Re-render only when the winning copy changed. */
let _pagesAt=0,_shownDoc=null;
function refresh(){
  // the Pages file is ~140 KB (squad logos): read it once, then only while the instant live copy is unavailable
  // (it was re-downloaded every minute, ~8 MB an hour on mobile data for no newer content)
  const needPages=!_pagesDoc||(!_liveDoc&&Date.now()-_pagesAt>60000);
  if(needPages)_pagesAt=Date.now();
  return Promise.all([needPages?fetchPagesDoc().catch(()=>{}):null,pollLiveContent().catch(()=>{})]).then(()=>{
    const d=(_liveDoc&&_pagesDoc)?(pubTime(_liveDoc)>=pubTime(_pagesDoc)?_liveDoc:_pagesDoc):(_liveDoc||_pagesDoc);
    if(!d||d===_shownDoc)return;
    if(_lastData&&_lastData!==d&&pubTime(d)&&pubTime(d)<pubTime(_lastData))return;   // never step back to an older copy
    _shownDoc=d;d._live=true;render(d);
  });
}

/* ── accounts (Supabase Auth) — free, serverless, live 24/7, no laptop required ──
   Handles signup, email verification, login, forgot-password, in-app tournament
   registration, and the Notification History inbox (where room IDs show up). */
let _player=null;      // {id, email, tag}
let _authView='login';
let _googleFirstRun=false; // true only for the auto-opened "pick a username" prompt right after a Google sign-in; false when opened voluntarily via "Change username"
let _notifUnread=0;
let _roomCodes=new Map(); // tournament name -> {room_id, room_pass}, from the player's own notifications
// Offline ticket: the player's upcoming tickets (squad, slot, Room ID once sent) are kept on this device so
// offline.html can show them with no internet (match night on bad data is when they're needed most).
function saveOfflineTickets(){
  try{
    if(!_player){localStorage.removeItem('jd_offline_tickets');return;}
    const evs=new Map(((_lastData&&_lastData.tournaments)||[]).map(t=>[t.name,t]));
    const list=[..._myRegs].filter(([,r])=>r.status==='confirmed'||r.status==='approved').map(([slug,r])=>{
      const t=evs.get(slug)||{},rc=_roomCodes.get(slug)||{};
      return {event:slug,start:t.start||'',when:[t.date,t.time].filter(Boolean).join(' · '),squad:r.squad_name||'',slot:r.slot||null,
        confirmed:!!r.checked_in_at,room_id:rc.room_id||'',room_pass:rc.room_pass||''};
    }).filter(x=>!x.start||Date.parse(x.start)>Date.now()-4*3600e3).sort((a,b)=>(Date.parse(a.start)||9e15)-(Date.parse(b.start)||9e15)).slice(0,3);
    localStorage.setItem('jd_offline_tickets',JSON.stringify({at:new Date().toISOString(),player:_player.username||'',list}));
  }catch(e){}
}
let _notifHasLoadedOnce=false; // suppress the chime on the very first load (existing unread shouldn't "ding")
let _gateActive=false; // true while the whole site sits behind the forced login/signup gate
let _termsGateActive=false; // true while a signed-in player hasn't accepted the current Terms & Conditions yet
// Bump when the Terms or Privacy Policy change in a way players must accept again: anyone
// whose terms_accepted_at is older sees the accept box once on their next visit.
const TERMS_UPDATED_AT=Date.parse('2026-10-27T21:09:00Z');

/* Full login wall: nobody sees tournaments/prizes/how-to-join without an account. Runs
   after every _player change (see authRefreshPlayer) so it always reflects the real
   session state, not just page load. If accounts aren't configured on this deploy at all
   (sb is null), we deliberately DON'T gate — a config error should never lock everyone,
   including the owner, out of the whole site.
   Terms gate: covers accounts created before Terms & Conditions acceptance existed, or
   anyone who never actually accepted it (e.g. the checkbox request failed silently) —
   blocks the same way the login wall does, until they accept. */
function updateGate(){
  _gateActive=FORCE_LOGIN_GATE&&!!sb&&!_player;
  _termsGateActive=!_gateActive&&!!sb&&!!_player&&!_player.termsAccepted;
  const main=document.getElementById('main-content');if(main)main.style.display=_gateActive?'none':'';
  const header=document.querySelector('header');if(header)header.style.display=_gateActive?'none':'';
  const ov=document.getElementById('auth-overlay');if(!ov)return;
  const closeBtn=ov.querySelector('.fb-x');
  if(_gateActive){
    if(_authView!=='signup')_authView='login';
    authRender();
    ov.classList.add('open');
    if(closeBtn)closeBtn.style.display='none';
  }else if(_termsGateActive){
    _authView='acceptterms';
    authRender();
    ov.classList.add('open');
    if(closeBtn)closeBtn.style.display='none';
  }else{
    if(closeBtn)closeBtn.style.display='';
    ov.classList.remove('open');
  }
}

function authOpen(view){_authView=view||_authView||'login';document.getElementById('auth-overlay').classList.add('open');authRender();}
/* Settings: report/leaderboard/ban-list/about — utility pages, not account state, so
   this works whether or not you're logged in (unlike the account panel above it, which
   only ever renders for a signed-in _player). Same modal/view system as everything else
   here, just a view that isn't gated on auth state. */
function settingsOpen(){_authView='settings';document.getElementById('auth-overlay').classList.add('open');authRender();}
function authClose(){if(_gateActive||_termsGateActive)return;document.getElementById('auth-overlay').classList.remove('open');}
function authMsg(t,ok){const m=document.getElementById('au-msg');if(m){m.textContent=t;m.className='msg '+(ok?'ok':'err');}}

function authRender(){
  const el=document.getElementById('auth-body');if(!el)return;
  if(!sb){el.innerHTML='<h3>Accounts coming soon</h3><p class="sub">Sign-in isn\'t set up on this deploy yet.</p>';return;}
  if(_termsGateActive){
    el.innerHTML=`<h3>One more thing</h3><p class="sub">We've updated our Terms &amp; Conditions and added a Privacy Policy. Please review and accept them to keep using JD Esports Arena.</p>
      <label class="tc-check"><input type="checkbox" id="au-tc-accept-gate"><span>I am 13 or older (under 18: my parent or guardian agrees) and I agree to the <a href="/terms.html" target="_blank" rel="noopener">Terms &amp; Conditions</a> and <a href="/privacy/" target="_blank" rel="noopener">Privacy Policy</a></span></label>
      <div class="msg" id="au-msg"></div>
      <div class="row2"><button class="btn-primary" style="flex:1" onclick="authAcceptTermsGate()">Continue</button></div>
      <p class="sub" style="margin-top:16px"><button class="link" onclick="authLogout()">Log out instead</button></p>`;
    return;
  }
  if(_player&&_authView==='changepass'){
    el.innerHTML=`<h3>Change password</h3><p class="sub">Set a new password for your account.</p><label>New password</label><input id="au-newpass" type="password" placeholder="At least 6 characters"><div class="msg" id="au-msg"></div><div class="row2"><button class="btn-primary" style="flex:1" onclick="authSetNewPassword()">Save password</button></div><p class="sub" style="margin-top:16px"><button class="link" onclick="_authView='login';authRender();">Cancel</button></p>`;
    const first=el.querySelector('input');if(first)setTimeout(()=>first.focus(),50);
    return;
  }
  if(_player&&_authView==='report'){
    el.innerHTML=`<h3>Report a player/squad</h3><p class="sub">Emulator use in a mobile-only bracket, cheating, no-shows — whatever happened. Reports are never public; only a ban resulting from one shows up on the public ban list.</p>
      <label>Tournament (optional)</label><input id="rp-tournament" placeholder="e.g. JD Free Fire Open #3">
      <label>Who are you reporting?</label><input id="rp-reported" placeholder="Squad name or player tag/username" maxlength="60">
      <label>Evidence link (optional)</label><input id="rp-evidence" placeholder="Google Drive / Discord / YouTube clip URL">
      <label>What happened?</label><textarea id="rp-description" rows="4" placeholder="Describe it as specifically as you can" maxlength="1000"></textarea>
      <div class="msg" id="au-msg"></div>
      <div class="row2"><button class="btn-primary" style="flex:1" onclick="submitPlayerReport()">Submit report</button></div>
      <p class="sub" style="margin-top:16px"><button class="link" onclick="_authView='login';authRender();">Cancel</button></p>`;
    const first=el.querySelector('input');if(first)setTimeout(()=>first.focus(),50);
    return;
  }
  if(_player&&_authView==='chooseusername'){
    el.innerHTML=`<h3>${esc(_googleFirstRun?'Welcome! Pick a username':'Username & game ID')}</h3><p class="sub">${_googleFirstRun?"You signed in with Google — pick a username and add your Free Fire UID and in-game name so squadmates and admins can find you. You can change these later.":'Change your username, Free Fire UID or in-game name.'}</p>
      <label>Username</label><input id="au-username" autocomplete="off" maxlength="20" placeholder="3-20 letters, numbers, underscore" value="${esc(_player.username||'')}">
      <div class="msg" id="au-uname-msg"></div>
      ${gameIdFieldsHtml(_player.ff_uid,_player.ff_name)}
      ${_googleFirstRun?'<label class="tc-check"><input type="checkbox" id="au-tc-accept"><span>I am 13 or older (under 18: my parent or guardian agrees) and I agree to the <a href="/terms.html" target="_blank" rel="noopener">Terms &amp; Conditions</a> and <a href="/privacy/" target="_blank" rel="noopener">Privacy Policy</a></span></label>':''}
      <div class="msg" id="au-msg"></div>
      <div class="row2"><button class="btn-primary" style="flex:1" onclick="authSetUsername()">Save</button></div>
      ${_googleFirstRun?'<p class="sub" style="margin-top:16px"><button class="link" onclick="authClose()">Skip for now</button></p>':'<p class="sub" style="margin-top:16px"><button class="link" onclick="_authView=\'login\';authRender();">Cancel</button></p>'}`;
    const un=document.getElementById('au-username');
    if(un){un.addEventListener('input',checkUsernameLive);un.select();}
    setTimeout(()=>{const f=document.getElementById('au-username');if(f)f.focus();},50);
    return;
  }
  if(_authView==='support'){
    const waText='Hi JD Arena support! '+(_player&&_player.username?'My username: @'+_player.username+'. ':'')+'My problem: ';
    // Android app, signed in: one support chat - ZULU (AI) first, a JD team member when needed (chat.js JD Support)
    const appSupport=_player&&window.jdChat&&jdChat.inApp&&jdChat.support;
    el.innerHTML=`<h3>Help &amp; Support</h3><p class="sub">${appSupport?'Chat with JD Support: ZULU (AI) answers first, and a JD team member takes over whenever you need a person.':'Ask our AI assistant ZULU anything, any time — or talk to a person on WhatsApp or by phone.'}</p>
      <div class="pm-list">
        ${appSupport?'<button class="pm-row" onclick="authClose();jdChat.support()"><span class="pm-row-ic">🎧</span><span class="pm-row-txt">Chat with JD Support<small class="pm-row-sub">ZULU AI first · our team joins if needed</small></span><span class="pm-row-chev">›</span></button>':'<button class="pm-row" onclick="authClose();fbOpen()"><span class="pm-row-ic">🤖</span><span class="pm-row-txt">Chat with ZULU<small class="pm-row-sub">AI support · instant answers, 24/7</small></span><span class="pm-row-chev">›</span></button>'}
        <a class="pm-row" href="https://wa.me/${SUPPORT_PHONE}?text=${encodeURIComponent(waText)}" target="_blank" rel="noopener"><span class="pm-row-ic">💬</span><span class="pm-row-txt">WhatsApp support<small class="pm-row-sub">${esc(SUPPORT_PHONE_TXT)}</small></span><span class="pm-row-chev">›</span></a>
        <a class="pm-row" href="tel:+${SUPPORT_PHONE}"><span class="pm-row-ic">📞</span><span class="pm-row-txt">Call support<small class="pm-row-sub">${esc(SUPPORT_PHONE_TXT)}</small></span><span class="pm-row-chev">›</span></a>
      </div>
      <p class="pm-hint">For points, prizes or results, send your username and a screenshot so we can fix it fast.</p>
      <p class="sub" style="margin-top:16px"><button class="link" onclick="_authView='login';authRender();">Back</button></p>`;
    return;
  }
  if(_player&&_authView==='gameid'){
    el.innerHTML=`<h3>Game UID &amp; name</h3><p class="sub">Your Free Fire UID and in-game name, so admins can check who played. Only you and the JD Arena team can see them.</p>
      ${gameIdFieldsHtml(_player.ff_uid,_player.ff_name)}
      <div class="msg" id="au-msg"></div>
      <div class="row2"><button class="btn-primary" style="flex:1" onclick="authSaveGameId()">Save</button></div>
      <p class="sub" style="margin-top:16px"><button class="link" onclick="_authView='login';authRender();">Cancel</button></p>`;
    setTimeout(()=>{const f=document.getElementById('au-ffuid');if(f)f.focus();},50);
    return;
  }
  if(_authView==='settings'){
    let accountOnlyBlock='';
    if(_player){
      let discordRow;
      if(_player.discord_username){
        discordRow=`<div class="pm-row pm-row-static"><span class="pm-row-ic">💬</span><span class="pm-row-txt">@${esc(_player.discord_username)}</span><span class="pm-badge pm-badge-on">Connected</span></div>`;
      }else if(_discordLinkCode){
        discordRow=`<div class="pm-row pm-row-static" style="flex-direction:column;align-items:flex-start;gap:4px"><div class="auth-tag" style="margin:0;font-family:'Courier New',monospace;word-break:break-all">${esc(_discordLinkCode)}</div><p class="pm-hint" style="margin:0">Type <code>!link ${esc(_discordLinkCode)}</code> in the JD Esports Arena Discord server — expires in 10 minutes.</p></div>`;
      }else{
        discordRow=`<button class="pm-row" onclick="authLinkDiscord()"><span class="pm-row-ic">💬</span><span class="pm-row-txt">Link Discord</span><span class="pm-badge">Not connected</span></button>`;
      }
      const unlinkRow=_player.discord_username?'<p class="sub" style="margin:-8px 0 14px"><button class="link pm-unlink" onclick="authUnlinkDiscord()">Unlink Discord</button></p>':'';
      accountOnlyBlock=`<div class="pm-list">
        <button class="pm-row" onclick="_authView='changepass';authRender();"><span class="pm-row-ic">🔑</span><span class="pm-row-txt">Change password</span><span class="pm-row-chev">›</span></button>
        ${discordRow}
      </div>
      ${unlinkRow}`;
    }
    el.innerHTML=`<h3>Settings</h3><p class="sub">Reports, rules, downloads and other pages — not tied to your account.</p>
      ${accountOnlyBlock}
      <div class="pm-list">
        <button class="pm-row" onclick="authOpen('support')"><span class="pm-row-ic">🎧</span><span class="pm-row-txt">Help &amp; Support<small class="pm-row-sub">AI chat, WhatsApp or call</small></span><span class="pm-row-chev">›</span></button>
        <button class="pm-row" onclick="openReportFlow()"><span class="pm-row-ic">🚩</span><span class="pm-row-txt">Report a player/squad</span><span class="pm-row-chev">›</span></button>
        <a class="pm-row" href="/leaderboard.html"><span class="pm-row-ic">🏆</span><span class="pm-row-txt">Leaderboard</span><span class="pm-row-chev">›</span></a>
        <a class="pm-row" href="/ban-list.html"><span class="pm-row-ic">🛡️</span><span class="pm-row-txt">Ban List</span><span class="pm-row-chev">›</span></a>
        <a class="pm-row" href="/terms.html"><span class="pm-row-ic">📜</span><span class="pm-row-txt">Terms &amp; Conditions</span><span class="pm-row-chev">›</span></a>
        <a class="pm-row" href="${esc(MAIN_SITE_URL||'/about/')}"><span class="pm-row-ic">ℹ️</span><span class="pm-row-txt">About Us</span><span class="pm-row-chev">›</span></a>
      </div>
      <div class="pm-list">
        <button class="pm-row" onclick="downloadAndroid()"><span class="pm-row-ic">🤖</span><span class="pm-row-txt">Download for Android</span><span class="pm-row-chev">›</span></button>
        <button class="pm-row" onclick="downloadIOS()"><span class="pm-row-ic">🍎</span><span class="pm-row-txt">Download for iPhone</span><span class="pm-row-chev">›</span></button>
      </div>
      ${_player?`<p class="sub" style="margin-top:16px"><button class="link" onclick="_authView='login';authRender();">Back to account</button></p>
      <p class="sub" style="text-align:center;margin-top:28px"><button class="link" style="font-size:.68rem;color:var(--pm-muted,#9CA8BE)" onclick="const d=document.getElementById('acct-danger-zone');d.style.display=d.style.display==='none'?'block':'none';">Account management</button></p>
      <div id="acct-danger-zone" style="display:none;text-align:center;margin-top:6px"><button class="link pm-delete" onclick="authRequestDelete()">Delete account</button></div>`:''}`;
    return;
  }
  if(_player){
    const verifiedBadge=_player.verified?'<span class="pm-verified">✓ Verified</span>':'';
    const avatarBlock=`<div class="pm-avatar-wrap"><img class="pm-avatar" id="pm-avatar-img" src="${esc(_player.avatar||'/logo.webp')}" alt=""><button class="pm-avatar-edit" onclick="document.getElementById('pm-avatar-file').click()" aria-label="Change profile picture">📷</button><input type="file" id="pm-avatar-file" accept="image/*" style="display:none" onchange="authUploadAvatar(this)"></div>`;
    const regRows=[..._myRegs.entries()];
    // Upcoming/live first, then the rest; each row is a tap target that jumps to the card.
    const tByName=new Map(((_lastData||{}).tournaments||[]).map(t=>[t.name,t]));
    const stRank=n=>{const t=tByName.get(n);const st=t?effectiveStatus(t):'completed';return st==='live'?0:st==='upcoming'?1:2;};
    regRows.sort((a,b)=>stRank(a[0])-stRank(b[0]));
    const statusLabel=r=>r.checked_in_at&&(r.status==='confirmed'||r.status==='approved')?'Checked in':r.status==='no_show'?'No-show':(r.status.charAt(0).toUpperCase()+r.status.slice(1));
    const historyBlock=regRows.length?`<div class="pm-history"><div class="pm-history-title">Your tournaments</div>${regRows.map(([slug,r])=>{const t=tByName.get(slug);const st=t?effectiveStatus(t):'';const when=t&&t.date&&t.date!=='TBA'?esc(t.date)+(t.time&&t.time!=='TBA'?' · '+esc(t.time):''):'';
      return `<button type="button" class="pm-history-row pm-history-btn" onclick="authClose();setTimeout(()=>nmJump(this.dataset.t),250)" data-t="${esc(slug)}">${r.squad_logo?`<img class="pm-history-logo" src="${esc(r.squad_logo)}" alt="">`:`<span class="pm-history-logo">${st==='live'?'🔴':st==='upcoming'?'⚔️':'🏁'}</span>`}<span class="pm-history-main"><span class="pm-history-name">${esc(slug)}</span><span class="pm-history-squad">${[r.squad_name&&esc(r.squad_name),when||(st&&esc(st)),esc(regTicketCode(r))].filter(Boolean).join(' · ')}</span></span><span class="pm-history-status pm-status-${esc(r.checked_in_at&&r.status==='confirmed'?'confirmed':r.status)}">${esc(statusLabel(r))}</span></button>`;}).join('')}</div>`:'';
    el.innerHTML=`<h3 class="pm-title">Signed in</h3>${avatarBlock}<div class="auth-tag">@${esc(_player.username||'…')}</div><div class="pm-meta"><span>${esc(_player.email)}</span>${_player.tag?`<span class="pm-dot">●</span><span>ID ${esc(_player.tag)}</span>`:''}${verifiedBadge}</div>${_player.tag?'<p class="pm-hint">Only needed if you register outside the app.</p>':''}<div id="career-stats"></div><div class="msg" id="au-msg"></div>${historyBlock}<div class="pm-list">
        <button class="pm-row" id="acct-push-btn" onclick="enablePush()"><span class="pm-row-ic">🔔</span><span class="pm-row-txt">Enable push alerts</span><span class="pm-toggle" id="acct-push-toggle"></span></button>
        <button class="pm-row${_player.ff_uid?'':' warn'}" onclick="_authView='gameid';authRender();"><span class="pm-row-ic">🎮</span><span class="pm-row-txt">${_player.ff_uid?'Game UID &amp; name':'Add your Free Fire UID'}<small class="pm-row-sub">${_player.ff_uid?esc((_player.ff_name||'')+' · UID '+_player.ff_uid):'Needed so admins know who played'}</small></span><span class="pm-row-chev">›</span></button>
        <button class="pm-row" onclick="authChangeUsername()"><span class="pm-row-ic">✏️</span><span class="pm-row-txt">Change username</span><span class="pm-row-chev">›</span></button>
        <button class="pm-row" onclick="authOpen('support')"><span class="pm-row-ic">🎧</span><span class="pm-row-txt">Help &amp; Support<small class="pm-row-sub">AI chat, WhatsApp or call</small></span><span class="pm-row-chev">›</span></button>
        <button class="pm-row" onclick="authLogout()"><span class="pm-row-ic">↩</span><span class="pm-row-txt">Log out</span><span class="pm-row-chev">›</span></button>
      </div>`;
    updatePushBtn();
    loadCareerStats();
    return;
  }
  const gateIntro=_gateActive?'<div class="gate-intro"><b>JD Esports Arena</b><span>Sign in to see tournaments, prizes, and how to join.</span></div>':'';
  if(_authView==='signup'){
    el.innerHTML=gateIntro+`<h3>Create account</h3><p class="sub">Pick a username, then register for tournaments in-app.</p>
      ${googleBtnHtml()}
      <p class="sub" style="text-align:center;margin:-6px 0 14px">— or —</p>
      <label>Username</label><input id="au-username" autocomplete="off" maxlength="20" placeholder="3-20 letters, numbers, underscore">
      <div class="msg" id="au-uname-msg"></div>
      ${gameIdFieldsHtml('','')}
      <label class="tc-check"><input type="checkbox" id="au-tc-accept"><span>I am 13 or older (under 18: my parent or guardian agrees) and I agree to the <a href="/terms.html" target="_blank" rel="noopener">Terms &amp; Conditions</a> and <a href="/privacy/" target="_blank" rel="noopener">Privacy Policy</a></span></label>
      <label>Email</label><input id="au-email" type="email" autocomplete="email">
      <label>Password</label><input id="au-pass" type="password" autocomplete="new-password" placeholder="At least 6 characters">
      <div class="msg" id="au-msg"></div>
      <div class="row2"><button class="btn-primary" style="flex:1" onclick="authSignup()">Sign up</button></div>
      <p class="sub" style="margin-top:16px">Already have an account? <button class="link" onclick="authOpen('login')">Log in</button> · <button class="link" onclick="authOpen('support')">Need help?</button></p>`;
    const un=document.getElementById('au-username');
    if(un)un.addEventListener('input',checkUsernameLive);
  }else if(_authView==='forgot'){
    el.innerHTML=`<h3>Reset password</h3><p class="sub">We'll email you a reset link.</p>
      <label>Email</label><input id="au-email" type="email" autocomplete="email">
      <div class="msg" id="au-msg"></div>
      <div class="row2"><button class="btn-primary" style="flex:1" onclick="authForgot()">Send reset link</button></div>
      <p class="sub" style="margin-top:16px"><button class="link" onclick="authOpen('login')">Back to log in</button></p>`;
  }else{
    el.innerHTML=gateIntro+`<h3>Log in</h3><p class="sub">Log in to register and see your room IDs.</p>
      ${googleBtnHtml()}
      <p class="sub" style="text-align:center;margin:-6px 0 14px">— or —</p>
      <label>Email</label><input id="au-email" type="email" autocomplete="email">
      <label>Password</label><input id="au-pass" type="password" autocomplete="current-password">
      <div class="msg" id="au-msg"></div>
      <div class="row2"><button class="btn-primary" style="flex:1" onclick="authLogin()">Log in</button></div>
      <p class="sub" style="margin-top:16px">New here? <button class="link" onclick="authOpen('signup')">Create an account</button> · <button class="link" onclick="authOpen('forgot')">Forgot password?</button> · <button class="link" onclick="authOpen('support')">Need help?</button></p>`;
  }
  const first=el.querySelector('input');if(first)setTimeout(()=>first.focus(),50);
}

/* Free Fire UID + in-game name (game_id.sql set_my_game_id): asked at sign-up, on the username screen and in
   the account panel. */
const FF_UID_RE=/^[0-9]{6,13}$/;
function gameIdFieldsHtml(uid,name){
  return `<label>Free Fire UID</label><input id="au-ffuid" inputmode="numeric" autocomplete="off" maxlength="13" placeholder="Numbers on your Free Fire profile" value="${esc(uid||'')}">
      <label>In-game name</label><input id="au-ffname" autocomplete="off" maxlength="30" placeholder="Your name in Free Fire" value="${esc(name||'')}">`;
}
// null = fields not on screen; {err} = invalid; {uid,name} = ok
function gameIdRead(){
  const u=document.getElementById('au-ffuid'),n=document.getElementById('au-ffname');
  if(!u||!n)return null;
  const uid=u.value.replace(/\s/g,''),name=n.value.trim();
  if(!FF_UID_RE.test(uid))return {err:'Enter your Free Fire UID: 6-13 numbers (Free Fire > tap your profile picture > UID).'};
  if(!name||name.length>30)return {err:'Enter your Free Fire in-game name.'};
  return {uid,name};
}
async function gameIdSave(g){
  const {error}=await sb.rpc('set_my_game_id',{p_uid:g.uid,p_name:g.name});
  if(error)return error.message;
  if(_player){_player.ff_uid=g.uid;_player.ff_name=g.name;}
  return '';
}
async function authSaveGameId(){
  const g=gameIdRead();if(!g)return;
  if(g.err){authMsg(g.err);return;}
  authMsg('Saving…',true);
  const err=await gameIdSave(g);
  if(err){authMsg(err);return;}
  authMsg('Saved!',true);
  setTimeout(()=>{_authView='login';authRender();},700);
}
/* Facebook, Instagram, Messenger, TikTok... open links in their own built-in browser, and Google refuses to sign
   in there (403 disallowed_useragent). Many players arrive from those apps, so offer the real browser instead. */
function inAppBrowser(){
  const u=navigator.userAgent||'';
  if(JD_APP||!/FBAN|FBAV|FB_IAB|FBIOS|Instagram|Messenger|musical_ly|TikTok|BytedanceWebview|Snapchat|Line\//i.test(u))return '';
  return /Instagram/i.test(u)?'Instagram':/musical_ly|TikTok|Bytedance/i.test(u)?'TikTok':/Snapchat/i.test(u)?'Snapchat':/Line\//.test(u)?'LINE':/Messenger/i.test(u)?'Messenger':'Facebook';
}
function openInBrowser(){
  const q=new URLSearchParams(location.search);q.delete('fbclid');
  const path=location.pathname+(q.toString()?'?'+q:''),url=location.origin+path;
  if(/Android/i.test(navigator.userAgent))location.href='intent://'+location.host+path+'#Intent;scheme=https;package=com.android.chrome;S.browser_fallback_url='+encodeURIComponent(url)+';end';
  else location.href='x-safari-'+url; // iOS 17+ opens Safari; older iPhones follow the steps on screen
}
function googleBtnHtml(){
  const iab=inAppBrowser();
  const note=iab?`<div class="iab-note"><b>Opened from ${esc(iab)}?</b> Google sign-in doesn't work inside ${esc(iab)}. ${isIosDevice()?'Tap ••• at the top and choose "Open in external browser", or log in with email below.':'Open JD Arena in Chrome to use Google, or log in with email below.'}${isIosDevice()?'':' <button type="button" class="link" onclick="openInBrowser()">Open in Chrome</button>'}</div>`:'';
  return note+'<button class="btn-ghost" style="width:100%;margin-bottom:14px" onclick="authGoogleSignIn()">🔐 Continue with Google</button>';
}
const USERNAME_RE=/^[A-Za-z0-9_]{3,20}$/;
let _unameTimer=null;
function checkUsernameLive(){
  clearTimeout(_unameTimer);
  const el=document.getElementById('au-username'),msg=document.getElementById('au-uname-msg');
  if(!el||!msg)return;
  const v=el.value.trim();
  if(!v){msg.textContent='';msg.className='msg';return;}
  if(!USERNAME_RE.test(v)){msg.textContent='3-20 letters, numbers, or underscore only.';msg.className='msg err';return;}
  msg.textContent='Checking…';msg.className='msg';
  _unameTimer=setTimeout(async()=>{
    const {data,error}=await sb.rpc('is_username_taken',{check_username:v});
    if(document.getElementById('au-username').value.trim()!==v)return; // typed on since — stale result
    if(error){msg.textContent='';msg.className='msg';return;}
    msg.textContent=data?'That username is taken.':'✓ Available';
    msg.className='msg '+(data?'err':'ok');
  },400);
}

/* Google sign-in for players (not just admin): same Supabase Google provider as the
   admin gate, so once that's enabled this works too, no extra setup. Supabase marks
   OAuth sign-ins as email-confirmed automatically — meaning a player who signs up this
   way never touches the rate-limited confirmation mailer at all, unlike the email/
   password path above. handle_new_user() already falls back to an auto-generated
   'player_xxxxxxxx' username when there's no username in the OAuth metadata (see
   coalesce(...) in schema.sql), so this never fails at account-creation time — it just
   means a first-time Google player starts with a generic username they can change later.
   Doesn't replace the email/password flow above; both create rows in the same players
   table via the same trigger. */
async function authGoogleSignIn(){
  const iab=inAppBrowser();
  if(iab){
    const ios=isIosDevice();
    if(await confirmBox('Open in '+(ios?'Safari':'Chrome')+' for Google',iab+"'s built-in browser can't sign in with Google - Google blocks it.\n\n"+(ios?'Tap ••• at the top and choose "Open in external browser", then Continue with Google. ':'Open JD Arena in Chrome and tap Continue with Google there. ')+'Or log in with your email and password here.',ios?'Try Safari':'Open in Chrome','Use email'))openInBrowser();
    return;
  }
  authMsg('Redirecting to Google…',true);
  // Google sends the browser away and fully back — a JS variable wouldn't survive that
  // round trip, so this flag rides in sessionStorage instead. It's how the getSession()
  // handler near the bottom of this file knows to auto-open the username prompt only for
  // a sign-in that JUST completed, never for a plain returning-session page load.
  sessionStorage.setItem('jd_google_flow','1');
  // app 2.0: Google refuses sign-in inside an app WebView, so it runs in a Chrome tab and /app-auth/ hands the
  // session back to the app (jdarena://auth), which loads it here
  if(JD_APP){
    const {data,error}=await sb.auth.signInWithOAuth({provider:'google',options:{redirectTo:location.origin+'/app-auth/',skipBrowserRedirect:true}});
    if(error||!data||!data.url){sessionStorage.removeItem('jd_google_flow');authMsg('Google sign-in isn\'t set up on this deploy yet.');return;}
    JD_APP.openAuth(data.url);return;
  }
  const {error}=await sb.auth.signInWithOAuth({provider:'google',options:{redirectTo:location.href.split('#')[0]}});
  if(error){sessionStorage.removeItem('jd_google_flow');authMsg('Google sign-in isn\'t set up on this deploy yet.');}
}
async function authSetUsername(){
  const uname=document.getElementById('au-username').value.trim();
  if(!USERNAME_RE.test(uname)){authMsg('Pick a username: 3-20 letters, numbers, or underscore.');return;}
  const g=gameIdRead();
  if(g&&g.err){authMsg(g.err);return;}
  const tc=document.getElementById('au-tc-accept');
  if(tc&&!tc.checked){authMsg('Please confirm your age and accept the Terms & Privacy Policy to continue.');return;}
  authMsg('Saving…',true);
  if(g){const gerr=await gameIdSave(g);if(gerr){authMsg(gerr);return;}}
  if(uname!==_player.username){
    const {error}=await sb.rpc('set_my_username',{new_username:uname});
    if(error){authMsg(/duplicate|unique|taken|constraint/i.test(error.message)?'That username is taken — try another.':error.message);return;}
  }
  if(tc)await sb.rpc('accept_terms');
  await authRefreshPlayer();
  authMsg('Saved!',true);
  _authView='login';
  setTimeout(authClose,900);
}
function authChangeUsername(){_googleFirstRun=false;_authView='chooseusername';authRender();}
const AVATAR_MAX_PX=128; // same size/quality as squad logos
const AVATAR_SIGN_TTL=60*60*24; // signed URL good for a day — cheap to re-mint every page load, never stored anywhere
/* Avatars live in the private `avatars` Storage bucket at {uid}/avatar.jpg (RLS: only the
   owning auth.uid() can read/write that path) — never in the players table, and never public.
   A plain <img src> can't send an auth header, so a signed URL (the auth baked into the query
   string itself) is what makes a private file paintable in an <img> tag at all. */
async function loadMyAvatarUrl(){
  if(!_player)return;
  const {data,error}=await sb.storage.from('avatars').createSignedUrl(`${_player.id}/avatar.jpg`,AVATAR_SIGN_TTL);
  _player.avatar=(!error&&data)?data.signedUrl:null;
}
function authUploadAvatar(input){
  const f=input.files&&input.files[0];input.value='';
  if(!f)return;
  if(!f.type.startsWith('image/')){authMsg('Please choose an image file.');return;}
  resizeToDataUri(f,AVATAR_MAX_PX,0.85,async dataUri=>{
    authMsg('Uploading…',true);
    const blob=await (await fetch(dataUri)).blob();
    const {error}=await sb.storage.from('avatars').upload(`${_player.id}/avatar.jpg`,blob,{upsert:true,contentType:'image/jpeg'});
    if(error){authMsg(error.message);return;}
    await loadMyAvatarUrl();
    const img=document.getElementById('pm-avatar-img');if(img)img.src=_player.avatar||'/logo.webp';
    updateAcctBtn();
    authMsg('Profile picture updated!',true);
  });
}
async function authSignup(){
  const uname=document.getElementById('au-username').value.trim();
  const email=document.getElementById('au-email').value.trim(),pass=document.getElementById('au-pass').value;
  if(!USERNAME_RE.test(uname)){authMsg('Pick a username: 3-20 letters, numbers, or underscore.');return;}
  const g=gameIdRead();
  if(g&&g.err){authMsg(g.err);return;}
  const tc=document.getElementById('au-tc-accept');
  if(tc&&!tc.checked){authMsg('Please confirm your age and accept the Terms & Privacy Policy to continue.');return;}
  if(!email||pass.length<6){authMsg('Enter a valid email and a password of 6+ characters.');return;}
  authMsg('Checking username…',true);
  const {data:taken}=await sb.rpc('is_username_taken',{check_username:uname});
  if(taken){authMsg('That username is taken — try another.');return;}
  authMsg('Creating account…',true);
  const {data:signUpData,error}=await sb.auth.signUp({email,password:pass,options:{data:Object.assign({username:uname},g?{ff_uid:g.uid,ff_name:g.name}:{}),emailRedirectTo:location.href.split('#')[0]}});
  if(error){authMsg(/duplicate|unique|taken|constraint|saving new user/i.test(error.message)?'That username was just taken — try another.':error.message);return;}
  if(signUpData&&signUpData.session){
    // Email confirmation is off on this project — the account is live immediately, no
    // separate verify step, so this IS "account creation" and the right moment to ask for push.
    await sb.rpc('accept_terms');
    await authRefreshPlayer();
    authClose();
    maybeAskPush();
    return;
  }
  // Supabase's anti-enumeration protection: signing up with an email that already has a
  // confirmed account returns HTTP 200 with a *fake* user (no error, no new row, no email
  // sent) instead of an error — the only tell is an empty identities[] array. Without this
  // check we'd show "Check your email" as if it worked, which is exactly the bug where
  // re-signing-up with the same email looked successful but sent nothing.
  if(signUpData&&signUpData.user&&Array.isArray(signUpData.user.identities)&&signUpData.user.identities.length===0){
    document.getElementById('auth-body').innerHTML=`<h3>Account already exists</h3><p class="sub"><b>${esc(email)}</b> already has an account — no new email was sent.</p><div class="row2"><button class="btn-primary" style="flex:1" onclick="authOpen('login')">Log in</button></div><p class="sub" style="margin-top:16px"><button class="link" onclick="authOpen('forgot')">Forgot password?</button></p>`;
    return;
  }
  document.getElementById('auth-body').innerHTML=`<h3>Check your email</h3><p class="sub">We sent a verification link to <b>${esc(email)}</b>. Click it and you'll be signed in automatically. (Check spam if it doesn't show up in a minute.)</p><div class="row2"><button class="btn-primary" style="flex:1" onclick="authOpen('login')">Back to log in</button></div>`;
}

async function authLogin(){
  const email=document.getElementById('au-email').value.trim(),pass=document.getElementById('au-pass').value;
  if(!email||!pass){authMsg('Enter your email and password.');return;}
  authMsg('Logging in…',true);
  const {error}=await sb.auth.signInWithPassword({email,password:pass});
  if(error){authMsg(/email not confirmed/i.test(error.message)?'Verify your email first — check your inbox for the link.':error.message);return;}
  await authRefreshPlayer();
  authClose();
}

async function authForgot(){
  const email=document.getElementById('au-email').value.trim();
  if(!email){authMsg('Enter your email.');return;}
  authMsg('Sending…',true);
  const {error}=await sb.auth.resetPasswordForEmail(email,{redirectTo:location.origin+'/reset-password/'});
  if(error){authMsg(error.message);return;}
  authMsg('Reset link sent — check your email.',true);
}

async function authLogout(){
  await forgetPushDevice(); // while still signed in: the delete only matches this player's own rows
  await sb.auth.signOut();
  _player=null;_myRegs=new Map();_roomCodes=new Map();_notifUnread=0;try{localStorage.removeItem('jd_offline_tickets');}catch(e){}_discordLinkCode=null;
  trackPresence();
  updateAcctBtn();updateNotifHistBtn();updateGate();renderCur();
}
async function authAcceptTermsGate(){
  const cb=document.getElementById('au-tc-accept-gate');
  if(!cb||!cb.checked){authMsg('Please confirm your age and accept the Terms & Privacy Policy to continue.');return;}
  authMsg('Saving…',true);
  const {error}=await sb.rpc('accept_terms');
  if(error){authMsg(error.message);return;}
  _player.termsAccepted=true;
  _authView='login';
  updateGate();
  claimAppPerks();
}

/* ── Discord account linking ── generates a one-time code (see create_discord_link_code()
   in schema.sql) the player types into the Discord bot as `!link <code>` — that's the only
   proof the bot has that a given Discord user owns this JD Arena account. Lets send-room-code /
   publish-results DM the player directly instead of that living only on the website. */
let _discordLinkCode=null;
async function authLinkDiscord(){
  const {data,error}=await sb.rpc('create_discord_link_code');
  if(error){authMsg(error.message);return;}
  _discordLinkCode=data;
  authRender();
}
async function authUnlinkDiscord(){
  if(!confirm('Unlink Discord? Room IDs will stop being sent there.'))return;
  const {error}=await sb.rpc('unlink_discord_account');
  if(error){authMsg(error.message);return;}
  _player.discord_username=null;_discordLinkCode=null;
  authRender();
}

/* ── delete account ── two-step, both requiring an explicit click: (1) request a
   confirmation email — this reuses Supabase Auth's own magic-link sender, which already
   goes out over the Gmail SMTP set up for verify/reset emails (see SUPABASE_SETUP.md), so
   there's no dependency on the optional Resend email channel used elsewhere. Clicking the
   emailed link only re-authenticates the browser; it does NOT delete anything by itself —
   that only happens after (2) the user clicks "Yes, permanently delete" on the panel the
   link lands on (see the _deleteConfirmFlow branch in onAuthStateChange below). ── */
async function authRequestDelete(){
  if(!_player)return;
  if(!confirm("This starts account deletion. We'll email a confirmation link to "+_player.email+" — nothing is deleted until you click it and confirm again. Continue?"))return;
  authMsg('Sending confirmation email…',true);
  const redirectTo=location.origin+location.pathname+'?confirm_delete=1';
  const {error}=await sb.auth.signInWithOtp({email:_player.email,options:{emailRedirectTo:redirectTo,shouldCreateUser:false}});
  if(error){authMsg(error.message);return;}
  authMsg("Check your email and click the link (it's sent via our normal sign-in email, that's expected) — you'll land back here to confirm deletion.",true);
}

function openReportFlow(){if(!_player){authOpen('login');return;}_authView='report';authRender();}
async function submitPlayerReport(){
  const tournament_slug=(document.getElementById('rp-tournament')||{}).value||'';
  const reported=(document.getElementById('rp-reported')||{}).value||'';
  const evidence_url=(document.getElementById('rp-evidence')||{}).value||'';
  const description=(document.getElementById('rp-description')||{}).value||'';
  if(!reported.trim()){authMsg('Who are you reporting?');return;}
  if(!description.trim()){authMsg('Describe what happened.');return;}
  authMsg('Submitting…',true);
  try{
    const {error}=await sb.rpc('submit_report',{p_tournament_slug:tournament_slug,p_reported:reported,p_evidence_url:evidence_url,p_description:description});
    if(error)throw error;
    _authView='login';
    showMsg('Report submitted',"Thanks — this stays private and goes straight to Prabin for review. It's never public unless it results in a ban.");
  }catch(e){authMsg('Failed: '+e.message);}
}
async function authConfirmDeleteAccount(){
  const {data:{session}}=await sb.auth.getSession();
  if(!session){authMsg('Your confirmation link expired — request a new one from the account menu.');return;}
  authMsg('Deleting…',true);
  try{
    const r=await fetch(EDGE_FN_BASE+'/confirm-account-delete',{method:'POST',headers:{Authorization:'Bearer '+session.access_token}});
    if(!r.ok)throw new Error(await r.text());
    await sb.auth.signOut();
    forgetPushDevice();
    _player=null;_myRegs=new Map();_roomCodes=new Map();_notifUnread=0;try{localStorage.removeItem('jd_offline_tickets');}catch(e){}
    trackPresence();
    // updateGate()/authRender() below would otherwise overwrite auth-body (login form) —
    // showMsg() uses its own dedicated overlay, so it's untouched by that.
    showMsg('Account deleted','Your account has been deleted.');
    updateAcctBtn();updateNotifHistBtn();updateGate();renderCur();
  }catch(e){authMsg('Could not delete your account: '+e.message);}
}

/* App perks: the first time a signed-in player opens the installed app, claim_app_perks()
   (schema.sql) gives a free 7-day Lite effect, the 📱 badge and early access — once per
   account. Then ask for push alerts, the main reason the app is required on phones. */
async function claimAppPerks(){
  if(!sb||!_player||_player.app||!_player.termsAccepted||!isStandaloneApp())return; // after the terms box, never on top of it
  const {data,error}=await sb.rpc('claim_app_perks',{p_effect:'glow'});
  if(error)return;
  _player.app=true;updateAcctBtn();
  if(data&&data.new){
    loadMyRegs(); // picks up the new pass
    const push=pushSupported()&&pushPerm()!=='granted';
    const ok=await confirmBox('📱 Welcome to the app!',
      'Your free 7-day Lite squad effect (Glow) is on, your username now has the 📱 badge, and you can join marked events 24 hours early.'+(push?'\n\nTurn on notifications so you get room IDs and check-in alerts the moment they are sent.':''),
      push?'Turn on notifications':'Nice!',push?'Later':'Close');
    if(ok&&push)enablePush();
  }
}
async function authRefreshPlayer(){
  const {data:{user}}=await sb.auth.getUser();
  if(!user){_player=null;updateAcctBtn();updateGate();trackPresence();return;}
  let tag=null,uname=null;
  const {data}=await sb.from('players').select('player_tag, username, discord_username, terms_accepted_at, squad_name, squad_logo, app_installed_at, ff_uid, ff_name').eq('id',user.id).single();
  if(data){tag=data.player_tag;uname=data.username;}
  _player={id:user.id,email:user.email,tag:tag,username:uname,discord_username:data&&data.discord_username||null,avatar:null,termsAccepted:!!(data&&data.terms_accepted_at&&Date.parse(data.terms_accepted_at)>=TERMS_UPDATED_AT),verified:!!user.email_confirmed_at,squad_name:(data&&data.squad_name)||'',squad_logo:(data&&data.squad_logo)||''};
  _player.app=!!(data&&data.app_installed_at);
  _player.ff_uid=(data&&data.ff_uid)||'';_player.ff_name=(data&&data.ff_name)||'';
  {const md=user.user_metadata||{};if(!_player.ff_uid&&FF_UID_RE.test(md.ff_uid||'')&&md.ff_name)gameIdSave({uid:md.ff_uid,name:md.ff_name});}
  updateAcctBtn();
  updateGate();
  trackPresence();
  ensurePushSubscribed();
  if(JD_APP&&typeof JD_APP.area==='function'){try{const a=JD_APP.area();if(a)_area=a;}catch(e){}}
  saveArea();
  if(_player.app)appAskPush(); // a first app open asks inside claimAppPerks' welcome instead
  claimAppPerks();
  claimInvite();
  await loadMyAvatarUrl();
  updateAcctBtn();
  const avImg=document.getElementById('pm-avatar-img');if(avImg&&_player.avatar)avImg.src=_player.avatar;
  await loadMyRegs();
  loadNotifications(false);
  loadStreak();
}

/* Daily check-in streak (daily_checkin.sql). A badge and a streak count only, no points. */
async function loadStreak(checkin){
  const box=document.getElementById('streak');if(!box)return;
  if(!sb||!_player){box.hidden=true;return;}
  const {data,error}=await sb.rpc(checkin?'daily_checkin':'my_streak');
  if(error||!data){box.hidden=true;return;}
  const n=data.streak||0,done=!!data.checked_today,week=n%7||(n?7:0);
  const title=done?(n===1?'Day 1 – streak started!':`${n}-day streak 🔥`):n?`${n}-day streak – check in to keep it`:'Start your daily streak';
  box.innerHTML=`<span class="fl" aria-hidden="true">${done?'🔥':'🕯️'}</span><span class="tx"><b>${esc(title)}</b>`+
    `<small>Best ${data.best||0} day${data.best===1?'':'s'} · ${data.total||0} check-in${data.total===1?'':'s'}${n>=7?' · '+Math.floor(n/7)+' full week'+(n>=14?'s':''):''}</small>`+
    `<span class="days" aria-label="${week} of 7 days this week">${Array.from({length:7},(_,i)=>`<i class="${i<week?'on':''}"></i>`).join('')}</span></span>`+
    `<button type="button" id="streak-btn"${done?' disabled':''}>${done?'Checked in ✓':'Check in'}</button>`;
  box.hidden=false;
  if(checkin){box.classList.remove('pop');void box.offsetWidth;box.classList.add('pop');}
  const b=document.getElementById('streak-btn');if(b&&!done)b.onclick=()=>{b.disabled=true;loadStreak(true);};
}

/* MEGA invites (mega.sql): /mega/?r=<code> keeps the inviter (a host's @handle or a player's tag) on this device;
   right after the squad joins a MEGA event it's credited once (mega_set_ref ignores other events). /?join=<event>
   (the Join button on /mega/) opens that event's Join form once the events are loaded. */
async function megaCredit(name){
  let code=null;try{code=localStorage.getItem('jd_mega_ref');}catch(e){}
  if(!code||!sb||!_player)return;
  try{const {data}=await sb.rpc('mega_set_ref',{p_slug:name,p_code:code});if(data&&data.ok)localStorage.removeItem('jd_mega_ref');}catch(e){}
}
(function(){
  const q=new URLSearchParams(location.search),j=q.get('join');
  if(!j)return;
  q.delete('join');try{history.replaceState(history.state,'',location.pathname+(q.toString()?'?'+q:'')+'#tournaments');}catch(e){}
  let tries=0;const t=setInterval(()=>{
    if(++tries>40){clearInterval(t);return;}
    const b=[...document.querySelectorAll('[data-reg]')].find(x=>x.getAttribute('data-reg')===j);
    if(b){clearInterval(t);b.scrollIntoView({block:'center'});b.click();}
  },500);
})();

/* ?ticket=<event> (tapping a tournament alert): scroll to that event's card, where the ticket is, and flash it. */
(function(){
  const q=new URLSearchParams(location.search),slug=q.get('ticket');
  if(!slug)return;
  q.delete('ticket');try{history.replaceState(history.state,'',location.pathname+(q.toString()?'?'+q:'')+'#tournaments');}catch(e){}
  let tries=0;const t=setInterval(()=>{
    if(++tries>40){clearInterval(t);return;}
    const c=[...document.querySelectorAll('.tcard[data-tname]')].find(x=>x.getAttribute('data-tname')===slug);
    if(!c||(_player&&!_myRegsLoaded&&tries<20))return;
    clearInterval(t);
    const tk=c.querySelector('.mt')||c;
    tk.scrollIntoView({block:'center',behavior:'smooth'});
    tk.classList.add('jd-flash');setTimeout(()=>tk.classList.remove('jd-flash'),2600);
  },500);
})();

/* Pull to refresh (ui.js sends jd-refresh): fresh events, squads, my tickets and alerts - no page reload. */
window.addEventListener('jd-refresh',e=>{
  if(e.detail.kind!=='page')return;
  e.preventDefault();
  e.detail.wait(Promise.all([Promise.resolve(refresh()),loadPublicRoster(true),_player?loadMyRegs():0,_player?loadNotifications(false,true):0]).catch(()=>{}));
});

/* Invite links (jdesport.co.uk/?ref=JD-XXXXX): the code is kept on this device until the visitor signs in, then
   set_referrer() links the two accounts once (new players only, first 14 days - checked server-side). */
(function(){const m=/[?&]ref=([A-Za-z0-9_@-]{3,30})/.exec(location.search);if(m)try{localStorage.setItem('jd_ref',m[1]);}catch(e){}})();
async function claimInvite(){
  let code=null;try{code=localStorage.getItem('jd_ref');}catch(e){}
  if(!code||!sb||!_player)return;
  try{localStorage.removeItem('jd_ref');}catch(e){}
  const {data,error}=await sb.rpc('set_referrer',{p_code:code});
  if(!error&&data&&data.inviter)showMsg('Invite accepted 🤝',`You joined with ${data.inviter}'s invite. When your squad wins its first prize, you both get +40 points.`);
}
function updateAcctBtn(){
  const su=document.getElementById('signup-btn'),ac=document.getElementById('acct-btn'),ad=document.getElementById('admin-btn'),st=document.getElementById('settings-btn');
  if(typeof window.jdTabbarMe==='function')window.jdTabbarMe(_player?{avatar:_player.avatar||'',name:_player.username||'',at:Date.now()}:null);
  if(!ac)return;
  document.body.classList.toggle('signed-in',!!_player);
  if(!_player){const sk=document.getElementById('streak');if(sk)sk.hidden=true;}
  const pp=document.getElementById('pts-pill');if(pp)pp.hidden=!_player;
  const np=document.getElementById('nav-pts');if(np)np.hidden=!_player;
  if(typeof renderFxShow==='function')setTimeout(renderFxShow,0);
  if(st)st.style.display=_player?'':'none';
  if(_player){
    if(su)su.style.display='none';
    ac.classList.add('acct-btn-signed');
    ac.innerHTML=`<img class="acct-avatar-mini" src="${esc(_player.avatar||'/logo.webp')}" alt="">${esc(_player.username||_player.tag||'Account')}${_player.app?' <span class="app-badge" title="JD Arena app user">📱</span>':''}`;
    ac.onclick=()=>{location.href='/profile/';}; // profile has its own page; account settings stay reachable via /?account=1
    if(ad)ad.style.display=((_player.email||'').toLowerCase()===ADMIN_EMAIL.toLowerCase())?'':'none';
    {const zb=document.getElementById('zulu-admin-btn');if(zb&&ad)zb.style.display=ad.style.display;}
    const md=document.getElementById('mod-btn');
    if(md){ md.style.display='none'; if(typeof sb!=='undefined'&&sb) sb.rpc('is_moderator').then(r=>{ md.style.display=r.data?'':'none'; }).catch(()=>{}); }
  }else{
    if(su)su.style.display='';
    ac.classList.remove('acct-btn-signed');
    ac.textContent='Login';
    ac.onclick=()=>authOpen('login');
    if(ad)ad.style.display='none';
    {const zb=document.getElementById('zulu-admin-btn');if(zb)zb.style.display='none';}
    const md=document.getElementById('mod-btn'); if(md)md.style.display='none';
  }
}

async function authSetNewPassword(){
  const p=document.getElementById('au-newpass').value;
  if(p.length<6){authMsg('At least 6 characters.');return;}
  const {error}=await sb.auth.updateUser({password:p});
  if(error){authMsg(error.message);return;}
  authMsg("Password updated — you're logged in.",true);
  _authView='login';
  await authRefreshPlayer();
  setTimeout(authClose,1200);
}

if(sb){
  initPresence();
  sb.auth.onAuthStateChange((event,session)=>{
    if(session&&(event==='SIGNED_IN'||event==='INITIAL_SESSION')&&!_emailVerifyFlow&&!_deleteConfirmFlow){
      let n=null;try{n=sessionStorage.getItem('jd_next');if(n)sessionStorage.removeItem('jd_next');}catch(e){}
      if(n){setTimeout(()=>{location.href=n;},50);return;}
    }
    if(event==='PASSWORD_RECOVERY'){
      _authView='login';
      document.getElementById('auth-body').innerHTML=`<h3>Set a new password</h3><label>New password</label><input id="au-newpass" type="password" placeholder="At least 6 characters"><div class="msg" id="au-msg"></div><div class="row2"><button class="btn-primary" style="flex:1" onclick="authSetNewPassword()">Save password</button></div>`;
      document.getElementById('auth-overlay').classList.add('open');
    }else if(event==='SIGNED_IN'&&_emailVerifyFlow){
      _emailVerifyFlow=false;
      history.replaceState(null,'',location.pathname+location.search.replace(/[?&]type=signup[^&]*/,''));
      authRefreshPlayer().then(()=>{
        showMsg('Verified!',"Email verified — you're signed in!");
        maybeAskPush();
      });
    }else if(event==='SIGNED_IN'&&_deleteConfirmFlow){
      _deleteConfirmFlow=false;
      history.replaceState(null,'',location.pathname+location.search.replace(/[?&]confirm_delete=1/,''));
      authRefreshPlayer().then(()=>{
        // Explicit-click gate: landing here from the emailed link must never delete by
        // itself (mail scanners/prefetchers open links automatically) — it only shows this
        // panel; authConfirmDeleteAccount() only runs on the button click below.
        document.getElementById('auth-body').innerHTML=`<h3>Confirm account deletion</h3><p class="sub">This permanently deletes your account${_player&&_player.username?' (@'+esc(_player.username)+')':''}, including your registrations and notification history. This cannot be undone.</p><div class="msg" id="au-msg"></div><div class="row2"><button class="btn-primary" style="flex:1;background:#ff7676" onclick="authConfirmDeleteAccount()">Yes, permanently delete</button></div><p class="sub" style="margin-top:16px"><button class="link" onclick="authClose()">Cancel</button></p>`;
        document.getElementById('auth-overlay').classList.add('open');
      });
    }
  });
  sb.auth.getSession().then(({data:{session}})=>{
    if(!session){updateGate();return;}
    authRefreshPlayer().then(()=>{
      // Only the sign-in that JUST completed (flag set in authGoogleSignIn, right before
      // the redirect to Google) triggers this — a returning player who already has a
      // session on a normal page load never gets interrupted by it.
      if(sessionStorage.getItem('jd_google_flow')){
        sessionStorage.removeItem('jd_google_flow');
        if(_player&&/^player_[0-9a-f]{8}$/i.test(_player.username||'')){
          _googleFirstRun=true;
          _authView='chooseusername';
          document.getElementById('auth-overlay').classList.add('open');
          authRender();
        }
      }
    });
  });
}else{
  const main=document.getElementById('main-content');if(main)main.style.display='';
  const header=document.querySelector('header');if(header)header.style.display='';
}

/* in-app tournament registration — squad name + an optional player-uploaded logo, resized
   client-side (mirrors jd-admin-970f8094.html's team-logo upload) before being stored as a small
   base64 data URI. This logo is shown back to the player only (their own registered card) —
   it's a separate list from the admin-managed public roster in tournaments.json, so it does
   NOT appear on the public tournament cards; see the "Known gap" note in SUPABASE_SETUP.md.

   Paid tournaments (entry != "Free") additionally require a payment-screenshot upload and
   register with status:'pending' instead of 'confirmed' — the admin approves/rejects from
   jd-admin-970f8094.html's Pending Payments panel (see SUPABASE_SETUP.md step 13). Room codes,
   reminders, and results notifications all skip pending/rejected registrations. */
const REG_LOGO_MAX_PX=128;
const PAY_SCREENSHOT_MAX_PX=640;
function isPaidTournament(t){const e=String((t&&t.entry)||'').trim().toLowerCase();return !!e&&e!=='free';}
let _myRegsLoaded=false;
let _myPass=null,_myPassEnd=null; // current effect pass (effect_passes row) and when the last stacked pass ends
let _myRegs=new Map(); // tournament name -> {id, squad_name, squad_logo, status, checked_in_at}
let _regTarget=null,_regLogoData=null,_regPayData=null;
async function loadMyRegs(){
  if(!sb||!_player){_myRegs=new Map();return;}
  const {data}=await sb.from('registrations').select('id, tournament_slug, squad_name, squad_logo, status, checked_in_at, verified_at, effect, paid_points, promoted_at, created_at').eq('player_id',_player.id);
  _myRegsLoaded=true;
  loadWallet();
  _myRegs=new Map((data||[]).map(r=>[r.tournament_slug,{id:r.id,squad_name:r.squad_name,squad_logo:r.squad_logo,status:r.status||'confirmed',checked_in_at:r.checked_in_at||null,promoted_at:r.promoted_at||null,created_at:r.created_at||null,verified_at:r.verified_at||null,effect:r.effect||'',paid_points:r.paid_points||0,squad_logo:r.squad_logo||(_player&&_player.squad_logo)||''}]));
  // slot number per tournament (rule: sit in the seat matching your app slot)
  try{const {data:sl}=await sb.rpc('my_tournament_slots');(sl||[]).forEach(x=>{const r=_myRegs.get(x.tournament_slug);if(r)r.slot=x.slot;});}catch(e){}
  // place in the waitlist queue (waitlist_position.sql - Pro pass first, then sign-up time)
  if([..._myRegs.values()].some(r=>r.status==='waitlisted'))try{const {data:wp}=await sb.rpc('my_waitlist_positions');(wp||[]).forEach(x=>{const r=_myRegs.get(x.tournament_slug);if(r){r.wpos=x.pos;r.wtotal=x.total;r.wpro=x.pro;}});}catch(e){}
  saveOfflineTickets();
  const pr=await sb.from('effect_passes').select('tier, effect, starts_at, expires_at').eq('player_id',_player.id).gt('expires_at',new Date().toISOString()).order('starts_at',{ascending:true});
  const passes=pr.data||[];
  _myPass=passes.find(x=>Date.parse(x.starts_at)<=Date.now())||null;
  _myPassEnd=passes.length?passes[passes.length-1].expires_at:null;
  renderCur();
}
async function registerInApp(name){
  if(!sb)return;
  if(!_player){authOpen('login');return;}
  const t=((_lastData||ARENA_SAMPLE).tournaments||[]).find(x=>x.name===name)||{};
  const slots=+t.slots||0;
  const paid=isPaidTournament(t);
  const full=slots&&teamsFor(t).length>=slots&&!_myRegs.has(name);
  // Paid tournaments still hard-reject when full — there's no paid waitlist yet (see
  // register_for_tournament() in schema.sql). Free ones let the modal open; the RPC
  // waitlists automatically and auto-promotes the moment a confirmed slot frees up.
  if(full&&paid){showMsg('Tournament full',"All "+slots+" squad slots are taken.",true);return;}
  /* no points, no registration: straight to Load points (the server refuses it too - register_for_tournament) */
  if(paid&&!canAfford(entryAmount(t))){
    const need=entryAmount(t)-(+_wallet||0);
    confirmBox('🪙 Load points to join',`${name} costs ${entryAmount(t)} points to join. You have ${walletLabel()} - load ${need} more points, then come back and join in one tap.`,'Load points','Later')
      .then(ok=>{if(ok)goWallet('load');});
    return;
  }
  /* free events: 3 rewarded ads first when the ad gate is on (ads.js + ad_gate.sql; Weekly Pass skips it) */
  if(!paid&&!_myRegs.has(name)&&window.jdAds&&!(await jdAds.gate(sb,name)))return;
  _regTarget=name;_regLogoData=null;_regPayData=null;
  document.getElementById('reg-tname').textContent=name;
  // saved squad: name pre-filled, logo reused — they only upload again to change it
  document.getElementById('reg-squad').value=_player.squad_name||'';
  const fi=document.getElementById('reg-logo-file');if(fi)fi.value='';
  const pv=document.getElementById('reg-logo-preview');
  if(pv){if(_player.squad_logo){pv.src=_player.squad_logo;pv.style.display='block';}else{pv.style.display='none';pv.src='';}}
  const ln=document.getElementById('reg-logo-note');
  if(ln)ln.textContent=_player.squad_logo?'Using your saved logo. Choose a new image only if you want to change it — it replaces the old one everywhere.':'Upload once — it is saved to your profile for every future tournament.';
  const payWrap=document.getElementById('reg-pay-wrap');if(payWrap)payWrap.style.display=paid?'':'none';
    const wo=document.getElementById('reg-wa-on'),wi=document.getElementById('reg-wa');if(wo)wo.checked=true;if(wi)wi.value='';const _wb=document.getElementById('reg-wa-box');if(_wb)_wb.hidden=false;regWaFill();regWaPreview();
  regQuickSetup(false);
  myContact().then(()=>{if(_regTarget===name)regQuickSetup(true);});
  const pp=document.getElementById('reg-pay-price');if(pp)pp.textContent='Entry '+(t.entry||'');
  const ps=document.getElementById('reg-pay-steps');if(ps){const pr=entryAmount(t);ps.innerHTML=paid?`<div class="pts-line" style="font-size:.8rem;color:var(--body)">Entry <b style="color:var(--gold-l)">${pr} points</b> · You have <b style="color:var(--gold-l)">${walletLabel()}</b>${canAfford(pr)?' — paid automatically when you register.':''}</div>`+(!canAfford(pr)?`<button type="button" class="pts-btn ghost" style="margin-top:8px" onclick="goWallet('load')">➕ Load points (need ${pr-_wallet} more)</button>`:''):'';}
  const payNote=document.getElementById('reg-pay-note');if(payNote)payNote.textContent='The entry is paid from your points when you register.';
  const rok=document.getElementById('reg-rules-ok');if(rok)rok.checked=false;
  // squads that registered and didn't show up before get a final warning (they can still join)
  // Android players not yet in the APK get a download button on the join form
  const ga=document.getElementById('reg-getapp');if(ga)ga.style.display=JD_TWA||!isAndroidDevice()?"none":"inline-flex";
  const ns=document.getElementById('reg-noshow');if(ns){ns.hidden=true;sb.rpc('my_no_show_count').then(({data})=>{if(+data>0){const n=document.getElementById('reg-noshow-n');if(n)n.textContent=Math.min(+data,3);ns.hidden=false;}},()=>{});}
  const pf=document.getElementById('reg-pay-file');if(pf)pf.value='';
  const ppv=document.getElementById('reg-pay-preview');if(ppv){ppv.style.display='none';ppv.src='';}
  const msg=document.getElementById('reg-msg');
  if(msg){
    if(full){msg.textContent="This tournament is full — you'll join the waitlist and be confirmed automatically if a slot opens up.";msg.className='msg warn';}
    else{msg.textContent='';msg.className='msg';}
  }
  document.getElementById('reg-overlay').classList.add('open');
}
function regWaToggle(){const on=(document.getElementById('reg-wa-on')||{}).checked,b=document.getElementById('reg-wa-box');if(b){b.hidden=!on;if(on){regWaFill();document.getElementById('reg-wa').focus();}}}
/* Country calling codes (ITU E.164). The first group is where most JD Arena players live or
   work; the rest are A–Z. Only the chosen country is remembered on this device (jd_wa_cc),
   never the number. */
const WA_COMMON='NP|Nepal|977,IN|India|91,QA|Qatar|974,AE|United Arab Emirates|971,SA|Saudi Arabia|966,MY|Malaysia|60,KW|Kuwait|965,OM|Oman|968,BH|Bahrain|973,JP|Japan|81,KR|South Korea|82,GB|United Kingdom|44,US|United States|1,AU|Australia|61,CA|Canada|1';
const WA_ALL='AF|Afghanistan|93,AL|Albania|355,DZ|Algeria|213,AD|Andorra|376,AO|Angola|244,AR|Argentina|54,AM|Armenia|374,AU|Australia|61,AT|Austria|43,AZ|Azerbaijan|994,BS|Bahamas|1,BH|Bahrain|973,BD|Bangladesh|880,BB|Barbados|1,BY|Belarus|375,BE|Belgium|32,BZ|Belize|501,BJ|Benin|229,BT|Bhutan|975,BO|Bolivia|591,BA|Bosnia and Herzegovina|387,BW|Botswana|267,BR|Brazil|55,BN|Brunei|673,BG|Bulgaria|359,BF|Burkina Faso|226,BI|Burundi|257,KH|Cambodia|855,CM|Cameroon|237,CA|Canada|1,CV|Cape Verde|238,CF|Central African Republic|236,TD|Chad|235,CL|Chile|56,CN|China|86,CO|Colombia|57,KM|Comoros|269,CG|Congo|242,CD|Congo (DR)|243,CR|Costa Rica|506,CI|Côte d’Ivoire|225,HR|Croatia|385,CU|Cuba|53,CY|Cyprus|357,CZ|Czechia|420,DK|Denmark|45,DJ|Djibouti|253,DO|Dominican Republic|1,EC|Ecuador|593,EG|Egypt|20,SV|El Salvador|503,GQ|Equatorial Guinea|240,ER|Eritrea|291,EE|Estonia|372,SZ|Eswatini|268,ET|Ethiopia|251,FJ|Fiji|679,FI|Finland|358,FR|France|33,GA|Gabon|241,GM|Gambia|220,GE|Georgia|995,DE|Germany|49,GH|Ghana|233,GR|Greece|30,GT|Guatemala|502,GN|Guinea|224,GY|Guyana|592,HT|Haiti|509,HN|Honduras|504,HK|Hong Kong|852,HU|Hungary|36,IS|Iceland|354,IN|India|91,ID|Indonesia|62,IR|Iran|98,IQ|Iraq|964,IE|Ireland|353,IL|Israel|972,IT|Italy|39,JM|Jamaica|1,JP|Japan|81,JO|Jordan|962,KZ|Kazakhstan|7,KE|Kenya|254,KW|Kuwait|965,KG|Kyrgyzstan|996,LA|Laos|856,LV|Latvia|371,LB|Lebanon|961,LS|Lesotho|266,LR|Liberia|231,LY|Libya|218,LI|Liechtenstein|423,LT|Lithuania|370,LU|Luxembourg|352,MO|Macau|853,MG|Madagascar|261,MW|Malawi|265,MY|Malaysia|60,MV|Maldives|960,ML|Mali|223,MT|Malta|356,MR|Mauritania|222,MU|Mauritius|230,MX|Mexico|52,MD|Moldova|373,MC|Monaco|377,MN|Mongolia|976,ME|Montenegro|382,MA|Morocco|212,MZ|Mozambique|258,MM|Myanmar|95,NA|Namibia|264,NP|Nepal|977,NL|Netherlands|31,NZ|New Zealand|64,NI|Nicaragua|505,NE|Niger|227,NG|Nigeria|234,MK|North Macedonia|389,NO|Norway|47,OM|Oman|968,PK|Pakistan|92,PS|Palestine|970,PA|Panama|507,PG|Papua New Guinea|675,PY|Paraguay|595,PE|Peru|51,PH|Philippines|63,PL|Poland|48,PT|Portugal|351,QA|Qatar|974,RO|Romania|40,RU|Russia|7,RW|Rwanda|250,SA|Saudi Arabia|966,SN|Senegal|221,RS|Serbia|381,SC|Seychelles|248,SL|Sierra Leone|232,SG|Singapore|65,SK|Slovakia|421,SI|Slovenia|386,SO|Somalia|252,ZA|South Africa|27,KR|South Korea|82,SS|South Sudan|211,ES|Spain|34,LK|Sri Lanka|94,SD|Sudan|249,SR|Suriname|597,SE|Sweden|46,CH|Switzerland|41,SY|Syria|963,TW|Taiwan|886,TJ|Tajikistan|992,TZ|Tanzania|255,TH|Thailand|66,TL|Timor-Leste|670,TG|Togo|228,TT|Trinidad and Tobago|1,TN|Tunisia|216,TR|Turkey|90,TM|Turkmenistan|993,UG|Uganda|256,UA|Ukraine|380,AE|United Arab Emirates|971,GB|United Kingdom|44,US|United States|1,UY|Uruguay|598,UZ|Uzbekistan|998,VE|Venezuela|58,VN|Vietnam|84,YE|Yemen|967,ZM|Zambia|260,ZW|Zimbabwe|263';
const waFlag=iso=>iso.replace(/./g,c=>String.fromCodePoint(127397+c.charCodeAt(0)));
const waParse=s=>s.split(',').map(x=>{const p=x.split('|');return {iso:p[0],name:p[1],code:p[2]};});
function regWaFill(){
  const sel=document.getElementById('reg-wa-cc');if(!sel||sel.options.length)return regWaCountry();
  const opt=c=>`<option value="${c.iso}">${waFlag(c.iso)} ${esc(c.name)} (+${c.code})</option>`;
  sel.innerHTML=`<optgroup label="Common">${waParse(WA_COMMON).map(opt).join('')}</optgroup><optgroup label="All countries">${waParse(WA_ALL).map(opt).join('')}</optgroup>`;
  let iso='NP';try{iso=localStorage.getItem('jd_wa_cc')||'NP';}catch(e){}
  sel.value=iso;if(!sel.value)sel.value='NP';
  regWaCountry(true);
}
function regWaCc(){const sel=document.getElementById('reg-wa-cc'),iso=(sel&&sel.value)||'NP';return waParse(WA_COMMON+','+WA_ALL).find(c=>c.iso===iso)||{iso:'NP',name:'Nepal',code:'977'};}
function regWaCountry(quiet){
  const c=regWaCc();
  document.getElementById('reg-wa-flag').textContent=waFlag(c.iso);
  document.getElementById('reg-wa-code').textContent='+'+c.code;
  const wi=document.getElementById('reg-wa');if(wi)wi.placeholder=c.iso==='NP'?'98XXXXXXXX':'Your number';
  if(!quiet){try{localStorage.setItem('jd_wa_cc',c.iso);}catch(e){}if(wi)wi.focus();}
  regWaPreview();
}
// The full international number: country code + the number without its leading 0 (UK 07… →
// +447…). A number typed or pasted with + or 00 already has its code and is used as is.
function regWaNumber(){
  const raw=((document.getElementById('reg-wa')||{}).value||'').replace(/[\s\-().]/g,'');
  if(!raw)return '';
  if(/^\+/.test(raw))return raw;
  if(/^00/.test(raw))return '+'+raw.slice(2);
  return '+'+regWaCc().code+raw.replace(/^0+/,'');
}
// same rule as set_registration_whatsapp() server-side (digits with an optional +, 7-15 long),
// plus Nepal's 10-digit mobiles starting with 9
function regWaError(){
  const n=regWaNumber();
  if(!n)return 'Enter your WhatsApp number — it\'s required.';
  if(!/^\+[0-9]{7,15}$/.test(n))return 'That number doesn\'t look right. Check the country and the number.';
  if(/^\+977/.test(n)&&!/^\+9779[0-9]{9}$/.test(n))return 'Nepal mobile numbers have 10 digits and start with 9 (98XXXXXXXX).';
  return '';
}
function regWaPreview(){
  const el=document.getElementById('reg-wa-preview');if(!el)return;
  const n=regWaNumber(),err=n?regWaError():'';
  el.className='wa-preview'+(err?' bad':'');
  el.innerHTML=n?(err?esc(err):'We\'ll text <b>'+esc(n)+'</b> on WhatsApp'):'';
}
function regWaValue(){if(!(document.getElementById('reg-wa-on')||{}).checked)return '';return regWaNumber();}
/* Saved squad contact (player_contacts, saved_contact.sql): the WhatsApp number + device of the last
   registration live on the account, so a returning squad just confirms - the rules box stays required. */
let _myContact=null;
async function myContact(){
  if(!sb||!_player)return null;
  if(_myContact&&_myContact._id===_player.id)return _myContact;
  try{const {data}=await sb.rpc('my_contact');_myContact=Object.assign({},data||{},{_id:_player.id});}catch(e){_myContact={_id:_player.id};}
  return _myContact;
}
// "+97798…" -> country select + national number in the form
function regWaSet(num){
  const wi=document.getElementById('reg-wa'),sel=document.getElementById('reg-wa-cc');if(!wi||!num)return;
  const d=String(num).replace(/^\+/,''),all=waParse(WA_COMMON+','+WA_ALL);
  let c=null;for(const x of all)if(d.startsWith(x.code)&&(!c||x.code.length>c.code.length))c=x;
  if(c&&c.iso!=='NP'&&d.startsWith('977'))c=all.find(x=>x.iso==='NP');
  if(c&&sel){sel.value=c.iso;regWaCountry(true);wi.value=d.slice(c.code.length);}
  else wi.value='+'+d;
  regWaPreview();
}
function regWaMask(n){const s=String(n||'');if(s.length<8)return s;return (s.startsWith('+977')?'+977 '+s.slice(4,6):s.slice(0,4))+'•••••'+s.slice(-3);}
// quick=true when the saved contact has loaded: a saved squad name + number = one-tap card
function regQuickSetup(loaded){
  const c=_myContact||{},q=document.getElementById('reg-quick'),a=document.getElementById('reg-edit-a'),b=document.getElementById('reg-edit-b');
  const name=(_player&&_player.squad_name)||'',quick=loaded&&!!c.whatsapp&&name.length>=2;
  if(loaded&&c.whatsapp){regWaSet(c.whatsapp);const fg=document.getElementById('reg-wa-forget');if(fg)fg.hidden=false;}
  if(loaded&&c.device_type){const dv=document.getElementById('reg-device');if(dv)dv.value=c.device_type;}
  if(q)q.hidden=!quick;if(a)a.hidden=quick;if(b)b.hidden=quick;
  const sbt=document.getElementById('reg-submit');if(sbt)sbt.textContent=quick?'✅ Confirm & join':'Register';
  if(!quick)return;
  const av=document.getElementById('rq-av');
  if(av)av.innerHTML=_player.squad_logo?`<img src="${esc(_player.squad_logo)}" alt="">`:esc(name.trim()[0].toUpperCase());
  document.getElementById('rq-name').textContent=name;
  const dv=(document.getElementById('reg-device')||{}).value==='emulator'?'🖥️ Emulator':'📱 Mobile';
  document.getElementById('rq-meta').textContent=dv+' · 💬 '+regWaMask(c.whatsapp);
}
function regQuickEdit(){
  document.getElementById('reg-quick').hidden=true;
  document.getElementById('reg-edit-a').hidden=false;document.getElementById('reg-edit-b').hidden=false;
  document.getElementById('reg-submit').textContent='Register';
  document.getElementById('reg-squad').focus();
}
async function regWaForget(){
  try{await sb.rpc('forget_my_whatsapp');}catch(e){}
  _myContact=Object.assign({},_myContact||{},{whatsapp:null});
  const wi=document.getElementById('reg-wa');if(wi)wi.value='';regWaPreview();
  const fg=document.getElementById('reg-wa-forget');if(fg)fg.hidden=true;
  const m=document.getElementById('reg-msg');if(m){m.textContent='Saved number removed from your account. Type a number to register.';m.className='msg';}
}
function regClose(){document.getElementById('reg-overlay').classList.remove('open');_regTarget=null;}
function resizeToDataUri(file,maxPx,quality,cb){
  const img=new Image(),reader=new FileReader();
  reader.onload=()=>{
    img.onload=()=>{
      const scale=Math.min(1,maxPx/Math.max(img.width,img.height));
      const w=Math.max(1,Math.round(img.width*scale)),h=Math.max(1,Math.round(img.height*scale));
      const cv=document.createElement('canvas');cv.width=w;cv.height=h;
      cv.getContext('2d').drawImage(img,0,0,w,h);
      cb(cv.toDataURL('image/jpeg',quality));
    };
    img.src=reader.result;
  };
  reader.readAsDataURL(file);
}
(function(){
  const fi=document.getElementById('reg-logo-file');if(!fi)return;
  fi.addEventListener('change',e=>{
    const f=e.target.files[0];if(!f)return;
    resizeToDataUri(f,REG_LOGO_MAX_PX,0.85,dataUri=>{
      _regLogoData=dataUri;
      const pv=document.getElementById('reg-logo-preview');if(pv){pv.src=dataUri;pv.style.display='block';}
    });
  });
})();
(function(){
  const fi=document.getElementById('reg-pay-file');if(!fi)return;
  fi.addEventListener('change',e=>{
    const f=e.target.files[0];if(!f)return;
    resizeToDataUri(f,PAY_SCREENSHOT_MAX_PX,0.85,dataUri=>{
      _regPayData=dataUri;
      const pv=document.getElementById('reg-pay-preview');if(pv){pv.src=dataUri;pv.style.display='block';}
    });
  });
})();
async function submitRegister(){
  const name=_regTarget;if(!name)return;
  const t=((_lastData||ARENA_SAMPLE).tournaments||[]).find(x=>x.name===name)||{};
  const paid=isPaidTournament(t);
  const squad=document.getElementById('reg-squad').value.trim()||null;
  const msg=document.getElementById('reg-msg');
  if(!squad||squad.length<2){msg.textContent='Enter your squad name (at least 2 characters).';msg.className='msg err';document.getElementById('reg-squad').focus();return;}
  const wa=regWaNumber();
  const waErr=regWaError();
  if(!wa||waErr){msg.textContent=waErr||'Add your WhatsApp number — it\'s required so we can send your Room ID and reminders.';msg.className='msg err';const _b=document.getElementById('reg-wa-box');if(_b)_b.hidden=false;document.getElementById('reg-wa').focus();return;}
  const rok=document.getElementById('reg-rules-ok');
  if(rok&&!rok.checked){msg.textContent='Please agree to the tournament rules to get your slot.';msg.className='msg err';rok.focus();return;}
  msg.textContent='Registering…';msg.className='msg';
  const status=paid?'pending':'confirmed';
  // Goes through register_for_tournament() (see schema.sql) instead of a plain insert —
  // that RPC re-checks the slot cap and inserts inside one advisory-locked transaction
  // server-side, so a rush of joins right at capacity can't over-subscribe the tournament
  // the way a client-only check (registerInApp's early gate above) could.
  const deviceType=(document.getElementById('reg-device')||{}).value||'mobile';
  const {data:reg,error}=await sb.rpc('register_for_tournament',{p_tournament_slug:name,p_squad_name:squad,p_squad_logo:_regLogoData,p_status:status,p_payment_screenshot:_regPayData,p_device_type:deviceType});
  if(error){
    if(/duplicate/i.test(error.message))msg.textContent="You're already registered for this one.";
    else if(/tournament full/i.test(error.message))msg.textContent='This tournament just filled up — all squad slots are taken.';
    else if(/ADS_NEEDED/.test(error.message)){msg.textContent=error.message.replace(/^.*ADS_NEEDED:\s*/,'');msg.className='msg err';if(window.jdAds)jdAds.gate(sb,name,true).then(ok=>{if(ok)submitRegister();});return;}
    else if(/weekly pass/i.test(error.message)){msg.innerHTML=esc(error.message.replace(/\s*Get it at jdesport\.co\.uk\/pass\.?$/,''))+' <a href="/pass/" style="color:var(--gold-l);font-weight:700;text-decoration:underline">Get a Weekly Pass →</a>';}
    else msg.textContent=error.message; // covers the ban / mobile-only / emulator-only messages raised server-side, already human-readable
    msg.className='msg err';return;
  }
  // reg.status is what the RPC actually stored — 'waitlisted' if the tournament was full
  // when this landed, which can differ from the 'status' we asked for above.
  let effectiveStatus=(reg&&reg.status)||status;
  _player.squad_name=squad;if(_regLogoData)_player.squad_logo=_regLogoData;
  // optional WhatsApp reminder number — a failure here never undoes the registration
  if(wa&&reg&&reg.id){try{await sb.rpc('set_registration_whatsapp',{p_reg_id:reg.id,p_whatsapp:wa});_myContact=Object.assign({},_myContact||{},{whatsapp:wa,device_type:deviceType});}catch(e){}}
  // Paid: entry is paid in points only — taken straight away when the wallet covers it.
  let codeErr='';
  if(paid&&effectiveStatus==='pending'&&canAfford(entryAmount(t))){
    const rr=await sb.rpc('pay_entry_with_points',{p_tournament_slug:name});
    if(rr.error)codeErr=rr.error.message;else{effectiveStatus='approved';loadWallet();}
  }
  _myRegs.set(name,{id:reg&&reg.id,squad_name:squad,squad_logo:_regLogoData||_player.squad_logo||"",status:effectiveStatus,checked_in_at:null,paid_points:effectiveStatus==='approved'&&paid?entryAmount(t):0});
  megaCredit(name);
  regClose();
  regSuccessOpen(t,effectiveStatus,reg);
  if(codeErr){const n=document.getElementById('rs-note');if(n)n.innerHTML+=`<br><br><b>Payment not completed:</b> ${esc(codeErr)} Your place is held — you can pay from your ticket.`;}
  renderCur();
  loadPublicRoster(); // pulls the new registration into the public count/roster right away instead of waiting for the 45s poll
}
// Ticket shown to the player is just their registration row's own id, short-formed — not a
// separate value stored anywhere, so there's nothing new to keep in sync. It's for the
// player's own reference/screenshot, not looked up anywhere else in the app.
function regTicketCode(reg){
  const id=(reg&&reg.id)||'';
  return id?('JD-'+id.replace(/-/g,'').slice(0,8).toUpperCase()):'—';
}
function regSuccessOpen(t,status,reg){
  const pending=status==='pending',waitlisted=status==='waitlisted';
  document.getElementById('rs-title').textContent=waitlisted?"You're on the waitlist":(pending?'Place held — pay with points':'Registration successful');
  document.getElementById('rs-name').textContent=t.name;
  document.getElementById('rs-note').innerHTML=waitlisted
    ?"All squad slots are taken right now — you'll be <b>automatically confirmed</b> the moment one opens up, no need to do anything else."
    :(pending
      ?"Your place is held. Load points in your <a href=\"/wallet/\">JD wallet</a> (pay the eSewa QR, then upload the payment screenshot), then tap <b>Pay</b> on your ticket to confirm your slot."
      :"Your <b>Room ID and Password</b> will appear in Notification History once released by the host. Please arrive 15 minutes before the match starts.");
  document.getElementById('rs-tournament').textContent=t.name;
  document.getElementById('rs-ticket').textContent=regTicketCode(reg);
  const prizeRow=document.getElementById('rs-prize-row');
  if(t.prize){prizeRow.style.display='';document.getElementById('rs-prize').textContent=t.prize;}
  else prizeRow.style.display='none';
  const entryEl=document.getElementById('rs-entry');
  entryEl.textContent=isPaidTournament(t)?(t.entry||''):'FREE';
  entryEl.className='rs-val'+(isPaidTournament(t)?'':' ok');
  document.getElementById('rs-platform').textContent=platText(t);
  const statusEl=document.getElementById('rs-status');
  statusEl.textContent=waitlisted?'Waitlisted':(pending?'Pending verification':'Registered ✓');
  statusEl.className='rs-val'+(waitlisted||pending?' warn':' ok');
  const rc=document.getElementById('rs-cal');if(rc){rc.innerHTML=calBtnHtml(t);const b=rc.querySelector('[data-cal]');if(b)b.onclick=()=>calAdd(t.name);}
  document.getElementById('regsuccess-overlay').classList.add('open');
}
/* ── Add to calendar: a standard .ics event with three alarms (1 hour, 15 minutes and
   5 minutes before), which the phone's own calendar app opens (iPhone Calendar, Google
   Calendar / Samsung Calendar on Android), so players get an alarm even with the site
   closed. Plus a Google Calendar link for desktop. Only shown when the start time is known. ── */
function calTimes(t){const ms=Date.parse(t&&t.start);if(isNaN(ms))return null;return {start:ms,end:ms+2*3600e3};}
function calStamp(ms){return new Date(ms).toISOString().replace(/[-:]/g,'').replace(/\.\d{3}/,'');}
function calEsc(v){return String(v||'').replace(/\\/g,'\\\\').replace(/\n/g,'\\n').replace(/([,;])/g,'\\$1');}
// RFC 5545: lines longer than 75 bytes are folded (CRLF + space); 60 characters keeps
// multi-byte text (·, Devanagari) under the limit
function calFold(l){let o='';while(l.length>60){o+=l.slice(0,60)+'\r\n ';l=l.slice(60);}return o+l;}
function calBtnHtml(t){
  const c=calTimes(t);if(!c||c.start<Date.now())return '';
  const g='https://calendar.google.com/calendar/render?action=TEMPLATE&text='+encodeURIComponent('JD Arena: '+t.name)+'&dates='+calStamp(c.start)+'/'+calStamp(c.end)+'&details='+encodeURIComponent('Free Fire tournament on JD Esports Arena. Your Room ID and password appear on your ticket at https://jdesport.co.uk about 5 minutes before the start.')+'&location='+encodeURIComponent('https://jdesport.co.uk');
  return `<div class="mt-cal"><button type="button" class="mt-cal-btn" data-cal="${esc(t.name)}">📅 Add to calendar</button><a class="mt-cal-g" data-gcal href="${esc(g)}" target="_blank" rel="noopener">Google Calendar</a></div>`;
}
function calAdd(name){
  const t=((_lastData||ARENA_SAMPLE).tournaments||[]).find(x=>x.name===name),c=calTimes(t);
  if(!c){showMsg('No start time yet','This tournament doesn\'t have a start time yet. Add it to your calendar once the time is announced.');return;}
  const uid='jd-'+String(name).toLowerCase().replace(/[^a-z0-9]+/g,'-')+'@jdesport.co.uk';
  const alarm=(min,txt)=>['BEGIN:VALARM','ACTION:DISPLAY','DESCRIPTION:'+calEsc(txt),'TRIGGER:-PT'+min+'M','END:VALARM'];
  const ics=['BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//JD Esports Arena//Tournaments//EN','CALSCALE:GREGORIAN','METHOD:PUBLISH',
    'BEGIN:VEVENT','UID:'+uid,'DTSTAMP:'+calStamp(Date.now()),'DTSTART:'+calStamp(c.start),'DTEND:'+calStamp(c.end),
    'SUMMARY:'+calEsc('JD Arena: '+name),
    'DESCRIPTION:'+calEsc('Free Fire tournament on JD Esports Arena'+(t.format?' ('+t.format+')':'')+'. Your Room ID and password appear on your ticket at https://jdesport.co.uk about 5 minutes before the start. Be online 15 minutes early.'),
    'LOCATION:'+calEsc('https://jdesport.co.uk'),'URL:https://jdesport.co.uk/#tournaments','STATUS:CONFIRMED']
    .concat(alarm(60,name+' starts in 1 hour'),alarm(15,name+' starts in 15 minutes. Get online.'),alarm(5,name+': room ID is out now on your ticket'),['END:VEVENT','END:VCALENDAR']).map(calFold).join('\r\n');
  const file='jd-arena-'+String(name).toLowerCase().replace(/[^a-z0-9]+/g,'-')+'.ics';
  try{
    const f=new File([ics],file,{type:'text/calendar'});
    // phones: hand the event straight to the calendar app through the share sheet when possible
    if(navigator.canShare&&navigator.canShare({files:[f]})&&/Android|iPhone|iPad/i.test(navigator.userAgent)){navigator.share({files:[f],title:'JD Arena: '+name}).catch(()=>calDownload(ics,file));return;}
  }catch(e){}
  calDownload(ics,file);
}
function calDownload(ics,file){
  const url=URL.createObjectURL(new Blob([ics],{type:'text/calendar;charset=utf-8'}));
  const a=document.createElement('a');a.href=url;a.download=file;document.body.appendChild(a);a.click();a.remove();
  setTimeout(()=>URL.revokeObjectURL(url),4000);
  if(typeof toast==='function')toast('Calendar file saved. Open it to add the event with alarms.');
}
function regSuccessClose(){document.getElementById('regsuccess-overlay').classList.remove('open');}
function regSuccessViewNotif(){regSuccessClose();notifHistOpen();}
// Check-in opens 12 hours before a tournament's start (check_in_for_tournament() in
// schema.sql refuses anything earlier). No client-side close: the button keeps showing
// until tournament-reminders' forfeit sweep (about 10 minutes before start) releases the
// unchecked slots, so there is never a gap where a player can't check in but hasn't been
// released yet.
const CHECKIN_WINDOW_MS=12*60*60*1000;
// Check-in was removed (Oct 2026): confirmed squads keep their slot, and tournament-reminders
// no longer forfeits anyone. Set to true (with CHECKIN_REQUIRED there) to bring it back.
const CHECKIN_REQUIRED=false;
function checkinWindowOpen(t){
  if(!CHECKIN_REQUIRED)return false;
  const startMs=Date.parse(t&&t.start);
  return !isNaN(startMs)&&(startMs-Date.now())<=CHECKIN_WINDOW_MS;
}
async function checkInForTournament(name){
  if(!sb||!_player)return;
  const {data,error}=await sb.rpc('check_in_for_tournament',{p_tournament_slug:name});
  if(error){showMsg('Check-in failed',error.message,true);return;}
  const r=_myRegs.get(name)||{};
  _myRegs.set(name,{...r,checked_in_at:(data&&data.checked_in_at)||new Date().toISOString()});
  renderCur();
}
// Confirmation rule (2026-10): after registering, a squad must tap "Confirm you're playing".
// Squads not confirmed by 24h before start are removed by jd_confirm_sweep() (schema.sql),
// seats freed and entry points refunded. The confirm window is open from now until start.
const CONFIRM_REQUIRED=true;
// Confirmation window: opens 48h before start, closes 24h before.
function confirmWindowOpen(t){const s=Date.parse(t&&t.start);if(isNaN(s))return false;const n=Date.now();return n>=s-48*3600*1000&&n<s-24*3600*1000;}
function confirmBeforeWindow(t){const s=Date.parse(t&&t.start);return !isNaN(s)&&Date.now()<s-48*3600*1000;}
function confirmOpensAt(t){const s=Date.parse(t&&t.start);return isNaN(s)?'':new Date(s-48*3600*1000).toLocaleString([],{weekday:'short',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'});}
// got the slot from the waitlist or signed up after the 24h deadline: can confirm right up to the start (late_confirm.sql)
function lateUp(t,r){const s=Date.parse(t&&t.start),n=Date.now();if(!r||isNaN(s)||n<s-48*3600*1000||n>=s)return false;
  return !!r.promoted_at||Date.parse(r.created_at)>=s-24*3600*1000;}
function confirmDeadline(t){const s=Date.parse(t&&t.start);return isNaN(s)?'':new Date(s-24*3600*1000).toLocaleString([],{weekday:'short',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'});}
async function confirmAttendance(name){
  if(!sb||!_player)return;
  const {data,error}=await sb.rpc('confirm_attendance',{p_slug:name});
  if(error){showMsg('Could not confirm',error.message,true);return;}
  const r=_myRegs.get(name)||{};
  _myRegs.set(name,{...r,checked_in_at:(data&&data.checked_in_at)||new Date().toISOString()});
  renderCur();
}
/* Match ticket: everything a registered player needs on match day, on the card itself —
   squad + ticket code (tap to copy), a 3-step tracker (Registered → Checked in → Room
   code), and whatever the next action is. Once the room code is sent it shows right
   here with copy buttons. Deliberately nothing that changes every second (the grid only
   re-renders when its HTML changes) — the live countdown lives in the next-match bar. */
function matchTicketHtml(t,r){
  const rc=_roomCodes.get(t.name),checked=!!r.checked_in_at,win=checkinWindowOpen(t);
  const code=regTicketCode(r);
  const steps=CONFIRM_REQUIRED?[['Registered',true],['Confirmed',checked],['Room code',!!rc]]:(CHECKIN_REQUIRED?[['Registered',true],['Checked in',checked],['Room code',!!rc]]:[['Registered',true],['Slot kept',true],['Room code',!!rc]]);
  const cur=steps.findIndex(x=>!x[1]);
  const stepHtml=steps.map(([l,done],i)=>`<li class="${done?'done':(i===cur?'now':'')}"><i>${done?'✓':i+1}</i><span>${l}</span></li>`).join('');
  const slot=r.slot?`<div class="mt-slot" role="note" aria-label="Your slot: number ${r.slot}"><span class="mt-slot-no" aria-hidden="true"><i>SLOT</i><b>${r.slot}</b></span><span class="mt-slot-tx"><b>Your slot: #${r.slot}</b><small>Sit in seat ${r.slot} when you enter the room</small></span></div>`:'';
  let next;
  if(rc){
    next=`<div class="mt-room"><div class="mt-room-h"><span class="mt-live-dot"></span>Room is open — join now</div><div class="mt-room-row"><button type="button" class="mt-copy" data-copy="${esc(rc.room_id)}"><span>Room ID</span><b>${esc(rc.room_id)}</b><em>Tap to copy</em></button>${rc.room_pass?`<button type="button" class="mt-copy" data-copy="${esc(rc.room_pass)}"><span>Password</span><b>${esc(rc.room_pass)}</b><em>Tap to copy</em></button>`:''}</div></div>`;
  }else if(CONFIRM_REQUIRED&&!checked&&!confirmWindowOpen(t)&&lateUp(t,r)){
    next=`<button class="inapp-reg mt-checkin" data-confirm="${esc(t.name)}">✅ Confirm you're playing</button><div class="mt-next warn">🎟 ${r.promoted_at?'You got this slot from the waitlist':'You joined after the main deadline'}. Confirm now so the slot stays yours.</div>`;
  }else if(CONFIRM_REQUIRED&&!checked&&confirmWindowOpen(t)){
    const dl=confirmDeadline(t);
    next=`<button class="inapp-reg mt-checkin" data-confirm="${esc(t.name)}">✅ Confirm you're playing</button><div class="mt-next warn">Confirm${dl?` by <b>${esc(dl)}</b>`:''} (24h before start) or your seat is given to another squad. We need real players!</div>`;
  }else if(CONFIRM_REQUIRED&&!checked&&confirmBeforeWindow(t)){
    const op=confirmOpensAt(t);
    next=`<div class="mt-next">⏰ Confirmation opens 48 hours before start${op?` (<b>${esc(op)}</b>)`:''} — we'll remind you. Confirm then, or your seat is released.</div>`;
  }else if(CONFIRM_REQUIRED&&!checked){
    next=`<div class="mt-next warn">⚠️ Confirmation has closed (24h before start). If you didn't confirm, your seat may be released to another squad.</div>`;
  }else if(checked||!CHECKIN_REQUIRED){
    next=`<div class="mt-next">🔑 Your Room ID and password will appear here about 5 minutes before the match starts.</div>`;
  }else if(win){
    next=`<button class="inapp-reg mt-checkin" data-checkin="${esc(t.name)}">✅ Check in now</button><div class="mt-next warn">Check in at least 10 minutes before the start, otherwise your slot is released to the waitlist.</div>`;
  }else{
    const startMs=Date.parse(t.start);
    const opens=isNaN(startMs)?'':new Date(startMs-CHECKIN_WINDOW_MS).toLocaleString([],{weekday:'short',hour:'2-digit',minute:'2-digit'});
    next=`<div class="mt-next">⏰ Check-in opens 12 hours before start${opens?` (<b>${esc(opens)}</b>)`:''} — we will send you a reminder.</div>`;
  }
  const logo=r.squad_logo?`<img class="mt-logo" src="${esc(r.squad_logo)}" alt="">`:`<span class="mt-logo mt-logo-empty">${esc((r.squad_name||'?').trim().charAt(0).toUpperCase()||'?')}</span>`;
  return `<div class="mt"><div class="mt-head">${logo}<div class="mt-squad"><b>${esc(r.squad_name||'Your squad')}</b><small>${checked?'Confirmed ✓':(CONFIRM_REQUIRED?'Confirm needed':'You\'re in')}${r.verified_at?' · <span class="mt-ver">✅ Verified</span>':''}</small></div><button type="button" class="mt-code" data-copy="${esc(code)}" title="Tap to copy your ticket code">🎫 ${esc(code)}</button></div><ol class="mt-steps">${stepHtml}</ol>${slot}${next}${calBtnHtml(t)}${fxTicketHtml(t,r)}${canWithdraw(t)?`<button type="button" class="mt-withdraw" data-withdraw="${esc(t.name)}">Withdraw squad</button>`:''}</div>`;
}
function fxTicketHtml(t,r){
  const own=SQUAD_FX[r.effect],pass=fxPassNow(),pk=pass&&SQUAD_FX[pass.effect];
  if(own)return `<div class="mt-fx on">✨ ${esc(own.tag)} effect active for this tournament</div>`;
  if(pk)return `<div class="mt-fx on">✨ ${esc(pk.tag)} · ${pass.tier==='pro'?'Pro':'Lite'} pass until ${esc(fxDate(_myPassEnd||pass.expires_at))} <button type="button" class="link" data-fx-buy="${esc(t.name)}" style="margin-left:6px;background:none;border:none;color:var(--gold-l);text-decoration:underline;cursor:pointer;font:inherit">Change</button></div>`;
  if(!canWithdraw(t))return '';
  return `<button type="button" class="mt-fx-buy" data-fx-buy="${esc(t.name)}">✨ Squad effects · from Rs 2</button>`;
}
function entryCodeBoxHtml(t,r){
  const price=entryAmount(t);
  return `<div class="mt-codebox"><p>⏳ <b>Place held.</b> Pay the entry from your points to confirm your slot.</p>${ptsPayHtml(price,'Entry',`data-pts-entry="${esc(t.name)}"`)}</div>`;
}
async function payEntryWithPoints(name){
  const t=((_lastData||ARENA_SAMPLE).tournaments||[]).find(x=>x.name===name)||{};
  const price=entryAmount(t);
  const ok=await confirmBox(`Pay ${price} points?`,`${price} points will be taken from your wallet to confirm your squad for ${name}. Withdraw more than 24 hours before the start for a full refund to your wallet (10% on the last day).`,'Pay '+price+' points','Cancel');
  if(!ok)return;
  const {data,error}=await sb.rpc('pay_entry_with_points',{p_tournament_slug:name});
  if(error){showMsg('Payment not completed',error.message,true);return;}
  const r=_myRegs.get(name);if(r){r.status='approved';r.paid_points=price;}
  megaCredit(name);
  showMsg('Entry confirmed',`${price} points paid. Your squad is confirmed for ${name}. Wallet balance: ${data&&data.balance!=null?data.balance:'—'} points.`);
  await loadWallet();await loadPublicRoster();renderCur();
}
function earlyAccess(t){
  if(String(t.early_access||'').toLowerCase()!=='yes')return '';
  const open=Date.parse(t.reg_opens);if(isNaN(open)||Date.now()>=open)return '';
  return Date.now()<open-864e5?'closed':'app-only';
}
function fmtOpen(iso){const d=new Date(iso);return isNaN(d)?'soon':d.toLocaleString([],{weekday:'short',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'});}
function inAppRegBtn(t,st,full){
  if(st==='cancelled')return _myRegs.has(t.name)?`<div class="inapp-reg-done rejected"><span>✕ This tournament was cancelled — sorry for the mix-up, watch Discord for the reschedule</span></div>`:'';
  if(st==='completed')return sb?`<div class="review-summary" data-review-summary="${esc(t.name)}"></div>`:'';
  if(!sb)return '';
  if(_myRegs.has(t.name)){
    const r=_myRegs.get(t.name);
    if(r.status==='waitlisted')return `<div class="inapp-reg-done pending"><span>🕒 Waitlisted${r.squad_name?' as '+esc(r.squad_name):''} — we'll confirm you automatically if a slot opens · Ticket ${esc(regTicketCode(r))}</span></div>${r.wpos?`<div class="mt-wpos"><b>${r.wpos===1?"You're next in line":'#'+r.wpos+' in line'}</b><span>${r.wtotal} squad${r.wtotal===1?'':'s'} waiting${r.wpro?' · ⭐ your Pro pass puts you ahead':' · Pro pass holders move up first'}. Squads that don't confirm lose their slot, so keep alerts on.</span></div>`:''}${canWithdraw(t)?`<button type="button" class="mt-withdraw" data-withdraw="${esc(t.name)}">Withdraw squad</button>`:''}`;
    if(r.status==='pending')return `<div class="inapp-reg-done pending">${r.squad_logo?`<img class="reg-logo" src="${esc(r.squad_logo)}" alt="">`:''}<span>${r.squad_name?esc(r.squad_name)+' · ':''}Ticket ${esc(regTicketCode(r))}</span></div>${entryCodeBoxHtml(t,r)}${canWithdraw(t)?`<button type="button" class="mt-withdraw" data-withdraw="${esc(t.name)}">Withdraw squad</button>`:''}`;
    if(r.status==='rejected')return `<div class="inapp-reg-done rejected"><span>✕ Payment could not be verified — please contact the organiser on Discord</span></div>`;
    if(r.status==='no_show')return `<div class="inapp-reg-done rejected"><span>✕ Check-in was missed, so this slot was released</span></div>`;
    if(r.status==='confirmed'||r.status==='approved'||!r.status)return matchTicketHtml(t,r);
    if(r.checked_in_at)return `<div class="inapp-reg-done">${r.squad_logo?`<img class="reg-logo" src="${esc(r.squad_logo)}" alt="">`:''}<span>✓ Checked in${r.squad_name?' as '+esc(r.squad_name):''} — see you there! · Ticket ${esc(regTicketCode(r))}</span>${r.verified_at?'<span class="reg-verified">✅ Verified</span>':''}</div>`;
    if(checkinWindowOpen(t))return `<button class="inapp-reg" data-checkin="${esc(t.name)}">✅ Check In Now</button>`;
    return `<div class="inapp-reg-done">${r.squad_logo?`<img class="reg-logo" src="${esc(r.squad_logo)}" alt="">`:''}<span>✓ Registered${r.squad_name?' as '+esc(r.squad_name):''} — Ticket ${esc(regTicketCode(r))} · room details will be sent to Notification History</span>${r.verified_at?'<span class="reg-verified">✅ Verified</span>':''}</div>`;
  }
  // Paid tournaments still have no waitlist (see registerInApp's early gate) — only free
  // ones show "Join Waitlist" here; the button still opens the normal registration modal,
  // the RPC just lands them as waitlisted instead of confirmed.
  // Early access (admin: early_access + reg_opens): app users can join 24h before reg_opens;
  // register_for_tournament() enforces the same window server-side.
  const ea=earlyAccess(t);
  if(ea==='closed')return `<button class="inapp-reg" disabled>Opens ${esc(fmtOpen(t.reg_opens))}</button><div class="ea-note">⚡ App users can join 24 hours earlier</div>`;
  if(ea==='app-only'&&!(_player&&_player.app))return `<button class="inapp-reg" disabled>📱 App early access until ${esc(fmtOpen(t.reg_opens))}</button><div class="ea-note">Install the JD Arena app on your phone to join now</div>`;
  if(ea==='app-only')return `<button class="inapp-reg" data-reg="${esc(t.name)}">⚡ Join early (app)</button>`;
  if(full)return isPaidTournament(t)?`<button class="inapp-reg" disabled>Squads full</button>`:`<button class="inapp-reg" data-reg="${esc(t.name)}">Join Waitlist</button>`;
  return `<button class="inapp-reg" data-reg="${esc(t.name)}">Join</button>`;
}

/* ── reviews (trust feature): public, but only postable by someone who was actually
   confirmed/approved for the tournament (enforced server-side by
   submit_tournament_review() in schema.sql — this client code can't be trusted to
   gate it alone). Populated after render() rather than inline in the template
   string above since it needs a Supabase round-trip per completed card. ── */
function starString(avg){const n=Math.max(0,Math.min(5,Math.round(avg)));return '★'.repeat(n)+'☆'.repeat(5-n);}
async function loadReviewSummaries(){
  if(!sb)return;
  for(const el of document.querySelectorAll('[data-review-summary]')){
    const name=el.getAttribute('data-review-summary');
    const reg=_myRegs.get(name);
    const canReview=!!reg&&(reg.status==='confirmed'||reg.status==='approved');
    let summaryHtml='';
    try{
      const {data,error}=await sb.from('tournament_reviews').select('rating').eq('tournament_slug',name);
      const rows=error?[]:(data||[]);
      if(rows.length){
        const avg=rows.reduce((s,r)=>s+r.rating,0)/rows.length;
        summaryHtml=`<span class="stars">${starString(avg)}</span> ${avg.toFixed(1)} · ${rows.length} review${rows.length===1?'':'s'} <button class="link seeall-btn">See all</button>`;
      }
    }catch(e){}
    if(!summaryHtml&&!canReview){el.remove();continue;}
    el.innerHTML=summaryHtml;
    const seeBtn=el.querySelector('.seeall-btn');
    if(seeBtn)seeBtn.onclick=e=>{e.stopPropagation();toggleReviewList(el,name);};
    if(canReview){
      const box=document.createElement('div');box.className='review-box';
      const rateBtn=document.createElement('button');rateBtn.type='button';rateBtn.className='link';rateBtn.textContent='⭐ Rate this tournament';
      rateBtn.onclick=e=>{e.stopPropagation();openReviewForm(box,name);};
      box.appendChild(rateBtn);
      el.appendChild(box);
    }
  }
}
async function toggleReviewList(el,name){
  const existing=el.querySelector('.review-list');
  if(existing){existing.remove();return;}
  const list=document.createElement('div');list.className='review-list';list.textContent='Loading…';
  el.appendChild(list);
  const {data,error}=await sb.rpc('get_tournament_reviews',{p_tournament_slug:name});
  if(error||!data||!data.length){list.textContent='No reviews yet.';return;}
  list.innerHTML=data.map(r=>`<div class="review-item"><span class="stars">${starString(r.rating)}</span><span class="who">@${esc(r.username||'player')}</span>${r.comment?' — '+esc(r.comment):''}</div>`).join('');
}
function openReviewForm(box,name){
  box.innerHTML=`<div class="review-form" onclick="event.stopPropagation()">
    <div class="stars-pick" data-picked="0">${[1,2,3,4,5].map(n=>`<span data-star="${n}">★</span>`).join('')}</div>
    <textarea placeholder="Optional comment — how was it run?" maxlength="500"></textarea>
    <div class="row2" style="margin-top:8px;display:flex;gap:8px">
      <button type="button" class="btn-primary" style="flex:1">Submit</button>
      <button type="button" class="link">Cancel</button>
    </div>
    <div class="msg" style="margin-top:6px;font-size:.78rem"></div>
  </div>`;
  const form=box.querySelector('.review-form');
  const pick=form.querySelector('.stars-pick');
  const stars=[...pick.querySelectorAll('span')];
  stars.forEach(s=>s.onclick=()=>{
    const n=+s.getAttribute('data-star');
    pick.setAttribute('data-picked',n);
    stars.forEach(x=>x.classList.toggle('on',+x.getAttribute('data-star')<=n));
  });
  const msgEl=form.querySelector('.msg');
  form.querySelector('.btn-primary').onclick=async()=>{
    const rating=+pick.getAttribute('data-picked');
    if(!rating){msgEl.textContent='Pick a star rating first.';msgEl.style.color='#ff7676';return;}
    const comment=form.querySelector('textarea').value.trim();
    msgEl.textContent='Submitting…';msgEl.style.color='';
    try{
      const {error}=await sb.rpc('submit_tournament_review',{p_tournament_slug:name,p_rating:rating,p_comment:comment});
      if(error)throw error;
      box.innerHTML='<p style="margin:4px 0 0;color:var(--silver);font-size:.8rem">✓ Thanks — your review is posted.</p>';
    }catch(e){msgEl.textContent='Failed: '+e.message;msgEl.style.color='#ff7676';}
  };
  form.querySelector('.link').onclick=()=>{
    box.innerHTML='';
    const rateBtn=document.createElement('button');rateBtn.type='button';rateBtn.className='link';rateBtn.textContent='⭐ Rate this tournament';
    rateBtn.onclick=e=>{e.stopPropagation();openReviewForm(box,name);};
    box.appendChild(rateBtn);
  };
}

/* tap-to-copy for match-ticket / next-match buttons — delegated on document so it
   keeps working after the grid re-renders, and stops the tap from reaching cardTap */
document.addEventListener('click',e=>{
  const b=e.target.closest('[data-copy]');if(!b)return;
  e.stopPropagation();
  const text=b.getAttribute('data-copy');
  const done=()=>{b.classList.add('copied');const em=b.querySelector('em');const old=em?em.textContent:null;if(em)em.textContent='✓ Copied';else{b.dataset.label=b.dataset.label||b.innerHTML;b.innerHTML='✓ Copied';}
    if(navigator.vibrate)try{navigator.vibrate(15);}catch(x){}
    setTimeout(()=>{b.classList.remove('copied');if(em)em.textContent=old;else if(b.dataset.label){b.innerHTML=b.dataset.label;delete b.dataset.label;}},1300);};
  if(navigator.clipboard&&navigator.clipboard.writeText)navigator.clipboard.writeText(text).then(done,()=>{});
  else{try{const ta=document.createElement('textarea');ta.value=text;document.body.appendChild(ta);ta.select();document.execCommand('copy');ta.remove();done();}catch(x){}}
},true);

/* ── next-match bar: follows the player around the site with their soonest upcoming
   match — live countdown, a Check in button once the window opens, and the room code
   the moment it's sent. Tap the text to jump to that tournament's card; × hides it for
   this match for the rest of the session. ── */
function nextMatch(){
  if(!_player||!_lastData)return null;
  let best=null;
  for(const t of (_lastData.tournaments||[])){
    const r=_myRegs.get(t.name);if(!r||!(r.status==='confirmed'||r.status==='approved'))continue;
    const st=effectiveStatus(t);if(st!=='upcoming'&&st!=='live')continue;
    const ms=Date.parse(t.start);if(isNaN(ms))continue;
    if(st==='live'&&!_roomCodes.get(t.name))continue; // already started, nothing actionable
    const hot=_roomCodes.has(t.name)?1:0; // a released room code is the most urgent thing on screen
    if(!best||hot>best.hot||(hot===best.hot&&ms<best.ms))best={t,r,ms,hot};
  }
  return best;
}
function nmDismissed(name){try{return sessionStorage.getItem('jd_nm_hide')===name;}catch(e){return false;}}
function nmDismiss(name){try{sessionStorage.setItem('jd_nm_hide',name);}catch(e){}const el=document.getElementById('next-match');if(el){el.classList.remove('show');el.hidden=true;}}
function nmCountdown(ms){
  let d=Math.max(0,ms-Date.now());const day=Math.floor(d/864e5);d-=day*864e5;const h=Math.floor(d/36e5);d-=h*36e5;const m=Math.floor(d/6e4);const sec=Math.floor((d-m*6e4)/1000);
  return day?`${day}d ${h}h ${m}m`:h?`${h}h ${m}m`:`${m}m ${String(sec).padStart(2,'0')}s`;
}
let _nmKey='';
function updateNextMatch(){
  const el=document.getElementById('next-match');if(!el)return;
  const nm=nextMatch();
  if(!nm||nmDismissed(nm.t.name)){el.hidden=true;el.classList.remove('show');_nmKey='';return;}
  const {t,r,ms}=nm,rc=_roomCodes.get(t.name),win=checkinWindowOpen(t)&&!r.checked_in_at;
  const mode=rc?'room':win?'checkin':'count';
  const key=t.name+'|'+mode+'|'+(rc?rc.room_id+rc.room_pass:'');
  if(key!==_nmKey){
    _nmKey=key;
    const action=rc?`<button type="button" class="nm-btn" data-copy="${esc(rc.room_id)}">Copy ID ${esc(rc.room_id)}</button>`
      :win?`<button type="button" class="nm-btn" onclick="checkInForTournament(this.dataset.t)" data-t="${esc(t.name)}">Check in</button>`
      :'';
    const label=rc?'🔑 Room code is out':win?'✅ Check-in is open':'⚔️ Your next match';
    el.className='next-match '+mode;
    el.innerHTML=`<button type="button" class="nm-main" onclick="nmJump(this.dataset.t)" data-t="${esc(t.name)}"><small>${label}</small><b>${esc(t.name)}</b><span class="nm-count"></span></button>${action}<button type="button" class="nm-x" aria-label="Hide" onclick="nmDismiss(this.dataset.t)" data-t="${esc(t.name)}">×</button>`;
    el.hidden=false;requestAnimationFrame(()=>el.classList.add('show'));
  }
  const c=el.querySelector('.nm-count');
  if(c)c.textContent=rc?(r.squad_name?'as '+r.squad_name:''):(ms>Date.now()?'starts in '+nmCountdown(ms):'starting now');
}
function nmJump(name){
  const card=[...document.querySelectorAll('.tcard')].find(c=>c.dataset.tname===name);
  if(!card)return;
  card.scrollIntoView({behavior:'smooth',block:'center'});
  card.classList.remove('flash');void card.offsetWidth;card.classList.add('flash');
}
setInterval(()=>{if(!document.hidden)updateNextMatch();},1000);

/* notification history */
function notifHistOpen(){
  document.getElementById('notif-overlay').classList.add('open');
  updatePushBtn();
  loadNotifications(true);
  maybeAskPush(); // one click both opens history and, if push permission was never answered, prompts for it -- safe no-op if already granted/denied/not configured
}
function notifHistClose(){document.getElementById('notif-overlay').classList.remove('open');}

/* squad roster modal — shows all `slots` positions for a tournament (filled ones with
   logo/name/members, empty ones as "Open slot") from tournaments.json's admin-curated
   `teams` list. Not live registration data (see SUPABASE_SETUP.md's "Known gap"). */
function sqNum(i){return String(i+1).padStart(2,'0');}
function sqCardHtml(tm,i){
  const members=Array.isArray(tm.members)?tm.members.filter(Boolean):[];
  const fx=squadFx(tm);
  const initial=esc((String(tm.name||'?').trim()[0]||'?').toUpperCase());
  const crown=(fx&&fx.badge)?`<span class="sq-crown">${fx.badge}</span>`:'';
  const logo=`<div class="sq-av">${crown}${tm.logo?`<img src="${esc(tm.logo)}" alt="">`:`<div class="sqitem-nologo">${initial}</div>`}</div>`;
  const name=fx?`<span class="fx-name">${esc(tm.name)}</span>`:esc(tm.name);
  const mem=members.length?`<div class="sqitem-members" title="${esc(tr('sqmembers'))}">${members.map(m=>`<span>${esc(m)}</span>`).join('')}</div>`:'';
  const deco=fx?`<span class="sqfx-shine"></span>${sqfxParticles()}`:'';
  return `<div class="sqitem${fx?' sqfx sqfx-'+fx.key:''}">${deco}<span class="sq-no">${sqNum(i)}</span>${logo}<div class="sqitem-body">${fx?`<span class="sqfx-tag">${fx.tag}</span>`:''}<div class="sqitem-name">${name}${tm.pass==='pro'?'<span class="sq-pro" title="Weekly Pro">PRO</span>':''}</div>${mem}</div></div>`;
}
function openRoster(name){
  const t=((_lastData||ARENA_SAMPLE).tournaments||[]).find(x=>x.name===name);
  if(!t)return;
  const teams=teamsFor(t);
  const slots=+t.slots||teams.length;
  document.getElementById('roster-ttl').textContent=tr('sqttl');
  const filled=teams.map((tm,i)=>sqCardHtml(tm,i));
  const empty=Array.from({length:Math.max(0,slots-teams.length)},(_,k)=>`<div class="sqitem empty"><span class="sq-no">${sqNum(teams.length+k)}</span><div class="sqitem-nologo">+</div><div class="sqitem-body"><div class="sqitem-name">${tr('sqopen')}</div></div></div>`);
  const pct=slots?Math.min(100,Math.round(teams.length/slots*100)):0;
  document.getElementById('roster-sub').innerHTML=`${esc(t.name)}<div class="sq-head"><div class="sq-meter"><span style="width:${pct}%"></span></div><span class="sq-count">${teams.length}/${slots}</span></div>`;
  document.getElementById('roster-list').innerHTML=(filled.concat(empty).join(''))||`<p class="sub">${tr('sqempty')}</p>`;
  document.getElementById('roster-overlay').classList.add('open');
}
function rosterClose(){document.getElementById('roster-overlay').classList.remove('open');document.getElementById('roster-list').innerHTML='';}
/* drop-in for alert() styled to match the site instead of the browser's native
   popup — same "blocks until dismissed" feel (dedicated overlay, doesn't get
   closed by other overlays' open/close toggling), just themed. */
/* ── Entries are paid in points only (loaded on /wallet/ with an eSewa screenshot).
   PAY_WHATSAPP is only the contact for hand refunds of older join-code entries; effect
   codes are still redeemed in the effects shop with redeem_code(). Kept separate from
   WHATSAPP_NUMBER, which also changes every Register button. ── */
const PAY_WHATSAPP='447343082738';
const PAY_WHATSAPP_LABEL='+44 7343 082738 · jd.lmt.np';
/* ── points wallet: balance pill in the header (visible whenever signed in, even at 0).
   Loading, withdrawing and history live on their own page, /wallet/ (wallet/index.html).
   Balances only change server-side — see the wallet section of schema.sql. ── */
/* security lock banner — system_state.locked pauses every points movement server-side
   (see security_sweep in schema.sql); this just tells players why a payment failed. */
async function checkLock(){
  if(!sb)return;
  const {data}=await sb.from('system_state').select('locked').eq('id',1).maybeSingle();
  let b=document.getElementById('lock-banner');
  if(data&&data.locked){
    if(!b){b=document.createElement('div');b.id='lock-banner';b.setAttribute('role','status');b.style.cssText='position:sticky;top:0;z-index:70;padding:10px 16px;text-align:center;font-size:.84rem;font-weight:600;background:linear-gradient(100deg,#5a1d1d,#3a1414);color:#ffd6d6;border-bottom:1px solid rgba(255,120,120,.4)';b.textContent='⚠️ Payments, withdrawals and codes are paused for a quick security check. Your points are safe, and free tournaments run as normal.';document.body.prepend(b);}
  }else if(b)b.remove();
}
setTimeout(renderFxShow,600);
function goWallet(tab){location.href='/wallet/'+(tab?'#'+tab:'');}
let _wallet=0,_walletLoaded=false,_walletUnlimited=false;
function canAfford(n){return _walletUnlimited||_wallet>=n;}
function walletLabel(){return _walletUnlimited?'100B':String(_wallet);}
async function loadWallet(){
  if(!sb||!_player){_wallet=0;return;}
  const {data}=await sb.from('wallets').select('balance, unlimited').eq('player_id',_player.id).maybeSingle();
  const prev=_wallet;_wallet=(data&&data.balance)||0;_walletUnlimited=!!(data&&data.unlimited);_walletLoaded=true;
  const el=document.getElementById('pts-bal');if(el)el.textContent=walletLabel();
  const nb=document.getElementById('nav-pts-bal');if(nb)nb.textContent=walletLabel();
  const pill=document.getElementById('pts-pill');
  if(pill&&pill.dataset.seen&&_wallet>prev){pill.classList.remove('bump');void pill.offsetWidth;pill.classList.add('bump');} // points just arrived
  if(pill)pill.dataset.seen='1';
}
/* pay-with-points block used on tickets, the registration form and the effect shop */
function ptsPayHtml(price,label,action){
  const enough=canAfford(price);
  return `<div class="pts-pay"><div class="pts-line">${esc(label)}: <b>${price} points</b> · You have <b>${walletLabel()}</b></div>`
    +(enough?`<button type="button" class="pts-btn" ${action}><span class="jd-coin sm" aria-hidden="true">JD</span> Pay ${price} points</button>`
            :`<button type="button" class="pts-btn ghost" onclick="event.stopPropagation();goWallet('load')">➕ Load points (need ${price-_wallet} more)</button>`)
    +`</div>`;
}
function payWaLink(msg){return 'https://wa.me/'+PAY_WHATSAPP+'?text='+encodeURIComponent(msg||'');}
const FX_PLANS={
  fx_game:{name:'Single match',price:'Rs 2',per:'This tournament only',tier:'game'},
  fx_lite_week:{name:'Lite week',price:'Rs 5',per:'7 days · basic effects',tier:'lite'},
  fx_week:{name:'Pro week',price:'Rs 10',per:'7 days · every effect',tier:'pro',popular:true},
  fx_month:{name:'Pro month',price:'Rs 30',per:'30 days · every effect',tier:'pro',best:true}
};
let _fxShop={name:null,plan:'fx_month',effect:'bullets',mode:'buy'};
function fxPassNow(){return _myPass&&Date.parse(_myPass.starts_at)<=Date.now()&&Date.parse(_myPass.expires_at)>Date.now()?_myPass:null;}
function fxDate(iso){try{return new Date(iso).toLocaleDateString([],{day:'numeric',month:'short'});}catch(e){return '';}}
// tournaments a single-match effect can go on: your confirmed squads in matches that haven't started
function fxGameTargets(){
  const ts=((_lastData||ARENA_SAMPLE).tournaments||[]);
  return [..._myRegs.entries()].filter(([n,r])=>(r.status==='confirmed'||r.status==='approved')&&canWithdraw(ts.find(t=>t.name===n))).map(([n])=>n);
}
function fxShopOpen(name,mode){
  if(!sb)return;
  if(!_player){authOpen('login');return;}
  const pass=fxPassNow();
  const targets=fxGameTargets();
  if(!name||!targets.includes(name))name=targets[0]||null;
  _fxShop={name,plan:name?'fx_game':'fx_month',effect:name?'gold':'bullets',mode:mode||(pass?'change':'buy')};
  if(_fxShop.mode==='change'&&pass)_fxShop.effect=pass.effect;
  document.getElementById('fx-sub').textContent=`Make ${_player.squad_name||'your squad'} stand out on every tournament card, squad list and challenge. Effects are cosmetic only.`;
  const fc=document.getElementById('fx-code');if(fc)fc.value='';
  document.getElementById('fx-msg').textContent='';document.getElementById('fx-msg').className='msg';
  document.getElementById('fx-submit').disabled=false;
  fxShopRender();
  document.getElementById('fx-overlay').classList.add('open');
}
function fxShopRender(){
  const r=Object.assign({squad_name:_player.squad_name,squad_logo:_player.squad_logo},_myRegs.get(_fxShop.name)||{});
  const targets=fxGameTargets();
  const pass=fxPassNow(),change=_fxShop.mode==='change'&&pass;
  const tier=change?pass.tier:FX_PLANS[_fxShop.plan].tier;
  if(!fxTierOk(tier,_fxShop.effect))_fxShop.effect=Object.keys(SQUAD_FX).find(k=>fxTierOk(tier,k));
  const info=document.getElementById('fx-passinfo');
  if(pass){info.hidden=false;info.innerHTML=`✨ ${pass.tier==='pro'?'Pro':'Lite'} pass active until <b>${esc(fxDate(_myPassEnd||pass.expires_at))}</b>`+(change?`<button type="button" onclick="_fxShop.mode='buy';fxShopRender()">Buy or extend a plan</button>`:`<button type="button" onclick="_fxShop.mode='change';_fxShop.effect=fxPassNow().effect;fxShopRender()">Just change my effect</button>`);}
  else{info.hidden=true;info.innerHTML='';}
  document.getElementById('fx-plans-wrap').hidden=!!change;
  document.getElementById('fx-pay').hidden=!!change;
  document.getElementById('fx-plans').innerHTML=Object.entries(FX_PLANS).map(([k,pl])=>`<button type="button" class="fx-plan${k===_fxShop.plan?' on':''}" onclick="_fxShop.plan='${k}';fxShopRender()">${pl.best?'<span class="best">Best value</span>':(pl.popular?'<span class="best pop">Popular</span>':'')}<b>${esc(pl.name)}</b><span class="pr">${esc(pl.price)}</span><small>${esc(pl.per)}</small></button>`).join('');
  document.getElementById('fx-pick').innerHTML=Object.values(SQUAD_FX).map(f=>{
    const ok=fxTierOk(tier,f.key);
    return `<button type="button" data-fx="${f.key}" class="${f.key===_fxShop.effect?'on':''}${ok?'':' lock'}" ${ok?`onclick="_fxShop.effect='${f.key}';fxShopRender()"`:`disabled title="Included in Pro plans"`}>${ok?'':'🔒 '}${esc(f.tag)}${f.hot?'<span class="hot">🔥</span>':''}${f.tier==='pro'?'<span class="pro">PRO</span>':''}</button>`;
  }).join('');
  document.getElementById('fx-preview').innerHTML=sqCardHtml({name:r.squad_name||'Your squad',logo:r.squad_logo||'',members:[],effect:_fxShop.effect},0);
  const pl=FX_PLANS[_fxShop.plan];
  const price=parseInt(pl.price.replace(/[^0-9]/g,''),10);
  // single match = one specific tournament you're confirmed in
  const tw=document.getElementById('fx-tourney-wrap'),gameBlocked=_fxShop.plan==='fx_game'&&!targets.length;
  tw.innerHTML=_fxShop.plan!=='fx_game'||change?''
    :(targets.length?`<label>For which tournament?</label><select id="fx-tourney" onchange="_fxShop.name=this.value">${targets.map(n=>`<option value="${esc(n)}"${n===_fxShop.name?' selected':''}>${esc(n)}</option>`).join('')}</select>`
      :'<p class="sub" style="margin:8px 0 0;color:var(--warm-l,#FFC66B)">Single match needs a tournament you\'re confirmed in. Join one first — or pick a weekly or monthly pass, which works everywhere.</p>');
  if(_fxShop.plan==='fx_game'&&targets.length&&!targets.includes(_fxShop.name))_fxShop.name=targets[0];
  document.getElementById('fx-pay-steps').innerHTML=`<div class="pts-line" style="font-size:.8rem;color:var(--body)">${esc(pl.name)}: <b style="color:var(--gold-l)">${price} points</b> · You have <b style="color:var(--gold-l)">${walletLabel()}</b></div>`+(!canAfford(price)?`<button type="button" class="pts-btn ghost" style="margin-top:8px" onclick="goWallet('load')">➕ Load points (need ${price-_wallet} more)</button>`:'');
  document.getElementById('fx-submit').disabled=!!gameBlocked;
  document.getElementById('fx-submit').innerHTML=change?'Save effect':('<span class="jd-coin sm" aria-hidden="true">JD</span> Pay '+(_walletUnlimited?'(admin) ':'')+parseInt(pl.price.replace(/[^0-9]/g,''),10)+' points &amp; activate');
}
/* homepage showcase: live previews of the effects, paused while scrolled off-screen */
const FX_SHOWCASE=[['liquid','Glass Wolves'],['spatial','Sky Squad'],['brutal','Raw Gang'],['bullets','Night Raiders'],['blade','Red Samurai'],['legend','Diamond Kings'],['galaxy','Cosmic Crew'],['thunder','Storm Riders'],['gold','Kings XI'],['fire','Inferno Squad'],['neon','Night Shift']];
function renderFxShow(){
  const box=document.getElementById('fx-show');if(!box)return;
  const mine=_player&&_player.squad_name;
  box.innerHTML=FX_SHOWCASE.map(([k,sample],i)=>{const f=SQUAD_FX[k];if(!f)return '';
    return `<div class="fx-show-item"><div class="fx-show-lbl"><b>${esc(f.tag)}${f.hot?' 🔥':''}</b><span class="tier${f.tier==='pro'?'':' std'}">${f.tier==='pro'?'Pro':'From Rs 2'}</span></div>${sqCardHtml({name:mine||sample,logo:(_player&&_player.squad_logo)||'',members:[],effect:k},i)}</div>`;}).join('');
  if(!box._io&&'IntersectionObserver' in window){box._io=new IntersectionObserver(es=>es.forEach(e=>box.classList.toggle('fx-paused',!e.isIntersecting)),{rootMargin:'100px'});box._io.observe(box);}
}
function fxShowCta(){
  if(!sb)return;
  if(!_player){authOpen('signup');return;}
  fxShopOpen(null);
}
function fxShopClose(){document.getElementById('fx-overlay').classList.remove('open');document.getElementById('fx-preview').innerHTML='';}
async function fxShopSubmit(){
  const msg=document.getElementById('fx-msg'),btn=document.getElementById('fx-submit');
  const tag=(SQUAD_FX[_fxShop.effect]||{}).tag||'Squad';
  const change=_fxShop.mode==='change'&&fxPassNow();
  let res;
  if(change){
    btn.disabled=true;msg.className='msg';msg.textContent='Saving…';
    res=await sb.rpc('set_pass_effect',{p_effect:_fxShop.effect});
  }else{
    const code=((document.getElementById('fx-code')||{}).value||'').trim();
    btn.disabled=true;msg.className='msg';
    if(code){msg.textContent='Checking your code…';res=await sb.rpc('redeem_code',{p_code:code,p_tournament_slug:_fxShop.name,p_effect:_fxShop.effect});}
    else{msg.textContent='Paying with points…';res=await sb.rpc('buy_effect_with_points',{p_kind:_fxShop.plan,p_effect:_fxShop.effect,p_tournament_slug:_fxShop.name});}
  }
  if(res.error){btn.disabled=false;msg.className='msg err';msg.textContent=res.error.message||'Something went wrong. Please try again.';return;}
  fxShopClose();
  await loadMyRegs();await loadWallet();
  if(change)showMsg('Effect updated',`Your squad now shows the ${tag} effect.`);
  else{
    const d=res.data||{};
    showMsg('Effect activated',d.kind==='fx_game'
      ?`${tag} is now live on your squad for ${_fxShop.name}.`
      :`Your ${FX_PLANS[d.kind]?FX_PLANS[d.kind].name:'pass'} is active until ${fxDate(d.expires_at)}${Date.parse(d.starts_at)>Date.now()+60000?` (it starts ${fxDate(d.starts_at)}, when your current pass ends)`:''}. ${tag} shows on every tournament you join. You can change the effect any time from your ticket.`);
  }
  await loadPublicRoster();
  renderCur();
}
/* Styled yes/no dialog (native confirm() looks out of place and blocks the page).
   Resolves true only when the player presses the confirm button. */
let _confirmResolve=null;
function confirmBox(title,body,okLabel,cancelLabel){
  document.getElementById('confirm-title').textContent=title;
  document.getElementById('confirm-body').textContent=body;
  document.getElementById('confirm-ok').textContent=okLabel||'Confirm';
  document.getElementById('confirm-cancel').textContent=cancelLabel||'Cancel';
  document.getElementById('confirm-overlay').classList.add('open');
  return new Promise(res=>{_confirmResolve=res;});
}
function confirmClose(ok){
  document.getElementById('confirm-overlay').classList.remove('open');
  if(_confirmResolve){const r=_confirmResolve;_confirmResolve=null;r(!!ok);}
}
/* Player withdraws their own squad. Uses the existing "players delete own registration"
   RLS policy; the waitlist trigger (promote_from_waitlist) then fills the freed slot.
   RLS turns a disallowed delete into "0 rows, no error", so success is only reported
   when the row actually comes back from .select(). Not offered once the room code is
   out or the match is live — see canWithdraw(). */
function entryAmount(t){const m=String((t&&t.entry)||'').replace(/,/g,'').match(/\d+(\.\d+)?/);return m?+m[0]:0;}
// Refund rule for a withdrawn paid entry: full refund, or 10% ("late cancellation") within
// the last 24 hours before the start. After room details / kickoff, canWithdraw() is false.
function refundInfo(t){
  const startMs=Date.parse(t&&t.start);
  const late=!isNaN(startMs)&&startMs-Date.now()<24*3600*1000;
  const pct=late?10:100;
  return {late,pct,amount:Math.floor(entryAmount(t)*pct/100)};
}
function canWithdraw(t){
  if(!t||_roomCodes.has(t.name))return false;
  const st=String(t.status||'upcoming').toLowerCase();
  if(st!=='upcoming')return false;
  const startMs=Date.parse(t.start);
  return isNaN(startMs)||Date.now()<startMs;
}
async function withdrawSquad(name){
  const r=_myRegs.get(name);
  const t=((_lastData||ARENA_SAMPLE).tournaments||[]).find(x=>x.name===name);
  if(!sb||!_player||!r||!r.id||!t)return;
  if(!canWithdraw(t)){showMsg('Withdrawal closed','This match has already started or the room details have been released, so squads can no longer withdraw. Contact the organiser on Discord if there is a problem.',true);return;}
  const squad=r.squad_name||'Your squad';
  const isPaid=isPaidTournament(t);
  const rf=refundInfo(t),code=regTicketCode(r);
  const back=r.paid_points>0?(rf.late?Math.floor(r.paid_points*0.1):r.paid_points):0;
  const fee=!isPaid?'This was a free entry, so there is nothing to refund.'
    :r.paid_points>0
      ?(rf.late
        ?`Late cancellation: the match starts within 24 hours, so ${back} of your ${r.paid_points} points (10%) go back to your wallet.`
        :`All ${r.paid_points} points go back to your wallet straight away.`)
      :(r.status==='approved'||r.status==='confirmed')
        ?`This entry was paid with a join code, so the refund is sent by hand (${rf.late?'10% on the last day':'full refund'}). Message us on WhatsApp (${PAY_WHATSAPP_LABEL}) with your ticket code ${code}.`
        :'No points were taken for this held place.';
  const ok=await confirmBox(`Withdraw ${squad}?`,
    `${squad} will be removed from ${name} and the slot released to the next team.\n\n${fee}\n\nYou can register again later if a slot is still open.`,
    'Withdraw squad','Keep my spot');
  if(!ok)return;
  const {data,error}=await sb.rpc('withdraw_registration',{p_tournament_slug:name});
  if(error){showMsg('Withdrawal failed',error.message,true);return;}
  _myRegs.delete(name);
  const got=(data&&data.refund)||0;
  showMsg('Squad withdrawn',`${squad} has been removed from ${name} and the slot has been released.`+(got?`\n\n${got} points were refunded to your wallet.`:(isPaid&&r.paid_points===0&&(r.status==='approved'||r.status==='confirmed')?`\n\n${fee}`:'')));
  await loadWallet();
  await loadPublicRoster();
  renderCur();
}
function showMsg(title,body,isErr){
  document.getElementById('msg-title').textContent=title;
  document.getElementById('msg-body').textContent=body;
  const icon=document.getElementById('msg-icon');
  icon.textContent=isErr?'!':'✓';
  icon.className='msg-icon'+(isErr?' err':'');
  document.getElementById('msg-overlay').classList.add('open');
}
function msgClose(){document.getElementById('msg-overlay').classList.remove('open');}
function updateNotifHistBtn(){
  const b=document.getElementById('notif-badge'),btn=document.getElementById('notifhist-btn');if(!b)return;
  if(_notifUnread>0){b.textContent=_notifUnread>99?'99+':_notifUnread;b.hidden=false;}else{b.hidden=true;}
  const nc=document.getElementById('nav-notif-count');if(nc){nc.textContent=b.textContent;nc.hidden=!(_notifUnread>0);}
  const nt=document.getElementById('nav-toggle-btn');if(nt)nt.classList.toggle('has-unread',_notifUnread>0);
  if(btn){btn.classList.toggle('has-unread',_notifUnread>0);btn.setAttribute('aria-label',_notifUnread>0?`Notifications, ${_notifUnread} unread`:'Notifications');}
}
// one-shot bell swing when something new lands; re-triggerable by removing/re-adding the class
function ringBell(){const btn=document.getElementById('notifhist-btn');if(!btn)return;btn.classList.remove('ring');void btn.offsetWidth;btn.classList.add('ring');}
// register_for_tournament() (schema.sql) drops a "TICKET::<code>::<status>" notification
// alongside every registration — same ticket code as regTicketCode()/the success modal, just
// persisted so it's not a one-time popup. Rendered as a small styled card (reusing the
// success modal's .rs-table/.rs-row look) instead of plain text; everything else (prize,
// entry, platform) is looked up from tournaments.json by tournament_slug, not stored twice.
function notifTicketHtml(n,unreadClass){
  const parts=n.body.split('::');
  const ticket=parts[1]||'—',status=parts[2]||'confirmed',pending=status==='pending',waitlisted=status==='waitlisted';
  const t=((_lastData||ARENA_SAMPLE).tournaments||[]).find(x=>x.name===n.tournament_slug)||{};
  const paid=isPaidTournament(t);
  const prizeRow=t.prize?`<div class="rs-row"><span class="rs-lbl">💰 Prize Pool</span><span class="rs-val">${esc(t.prize)}</span></div>`:'';
  const cur=_myRegs.get(n.tournament_slug);
  const withdrawn=_myRegsLoaded&&(!cur||regTicketCode(cur)!==ticket);
  const statusText=withdrawn?'Withdrawn':(waitlisted?'Waitlisted 🕒':(pending?'Pending verification':'Registered ✓'));
  return `<div class="notif-item${unreadClass}"><div class="t">${esc(n.title)}</div><div class="rs-table" style="margin:8px 0 0">`
    +`<div class="rs-row"><span class="rs-lbl">🪪 Ticket</span><span class="rs-val">${esc(ticket)}</span></div>`
    +prizeRow
    +`<div class="rs-row"><span class="rs-lbl">🎫 Entry</span><span class="rs-val${paid?'':' ok'}">${paid?esc(t.entry||''):'FREE'}</span></div>`
    +`<div class="rs-row"><span class="rs-lbl">📱 Platform</span><span class="rs-val">${esc(platText(t))}</span></div>`
    +`<div class="rs-row"><span class="rs-lbl">🛡 Status</span><span class="rs-val${withdrawn?'':(waitlisted||pending?' warn':' ok')}">${statusText}</span></div>`
    +`</div>${notifTimeHtml(n.created_at)}</div>`;
}
function notifTimeHtml(iso){
  const d=new Date(iso),s=(Date.now()-d)/1000;
  const rel=s<60?'just now':s<3600?Math.floor(s/60)+'m ago':s<86400?Math.floor(s/3600)+'h ago':s<604800?Math.floor(s/86400)+'d ago':d.toLocaleDateString();
  return `<div class="ts" title="${esc(d.toLocaleString())}">${esc(rel)}</div>`;
}
function copyRoom(btn,id,pass){
  const text='Room ID: '+id+(pass?'\nPassword: '+pass:'');
  (navigator.clipboard?navigator.clipboard.writeText(text):Promise.reject()).then(()=>{btn.textContent='✓ Copied';btn.classList.add('done');setTimeout(()=>{btn.textContent='Copy';btn.classList.remove('done');},1400);}).catch(()=>{btn.textContent='Copy failed';});
}
/* Which bucket a notification belongs to, where tapping it goes, and its icon. Keep these
   patterns in step with linkFor() in supabase/functions/push-notifications (push alerts use
   the same buckets for ⚙️ alert settings). */
function notifKind(n){
  const t=(n.title||'')+' '+(n.body||'');
  if(/squad chat|friend request|now your friend/i.test(t))return {k:'social',ic:/squad chat/i.test(t)?'👥':'🤝',go:'chat',lbl:'💬 Open Messages'};
  if(/challenge/i.test(t))return {k:'challenge',ic:'⚔️',go:'/challenges/',lbl:'⚔️ Open challenges'};
  if(/wallet|points added|withdraw/i.test(t))return {k:'wallet',ic:'🪙',go:'/wallet/',lbl:'🪙 Open wallet'};
  if(n.tournament_slug||String(n.body||'').startsWith('TICKET::'))return {k:'tour',ic:n.room_id?'🎮':'🏆',go:'',lbl:''};
  return {k:'other',ic:'🔔',go:'',lbl:''};
}
function notifGo(where){notifHistClose();if(where==='chat'){if(window.jdChat)jdChat.open();return;}location.href=where;}
function notifSettings(){notifHistClose();if(window.jdChat&&jdChat.settings)jdChat.settings();}
let _notifRows=[],_notifFilter='all';
const NOTIF_TABS=[['all','All'],['tour','🏆 Tournaments'],['challenge','⚔️ Challenges'],['wallet','🪙 Wallet'],['social','🤝 Friends']];
function renderNotifList(){
  const list=document.getElementById('notif-list'),chips=document.getElementById('notif-chips');if(!list)return;
  const rows=_notifRows,kinds=rows.map(notifKind);
  const shown=NOTIF_TABS.filter(([k])=>k==='all'||kinds.some(x=>x.k===k));
  if(chips){chips.innerHTML=rows.length&&shown.length>2?shown.map(([k,l])=>{const un=rows.filter((r,i)=>!r.read_at&&(k==='all'||kinds[i].k===k)).length;return `<button type="button" role="tab" aria-selected="${_notifFilter===k}" onclick="_notifFilter='${k}';renderNotifList()">${l}${un?`<b>${un}</b>`:''}</button>`;}).join(''):'';}
  if(!shown.some(([k])=>k===_notifFilter))_notifFilter='all';
  const day=d=>{const x=new Date(d),n=new Date(),y=new Date();y.setDate(n.getDate()-1);return x.toDateString()===n.toDateString()?'Today':x.toDateString()===y.toDateString()?'Yesterday':(n-x<7*864e5?'This week':'Earlier');};
  let last='',h='';
  rows.forEach((r,i)=>{if(_notifFilter!=='all'&&kinds[i].k!==_notifFilter)return;const d=day(r.created_at);if(d!==last){h+=`<div class="notif-day">${d}</div>`;last=d;}h+=notifItemHtml(r);});
  list.innerHTML=h||(rows.length?'<div class="notif-empty"><span>🗂️</span><b>Nothing here</b><p>No notifications of this type yet.</p></div>':'<div class="notif-empty"><span>🔕</span><b>No notifications yet</b><p>Tickets, check-in reminders, room details, challenges and results will appear here.</p></div>');
  const g=document.getElementById('notif-gear');if(g)g.hidden=!(window.jdChat&&jdChat.settings);
}
function notifItemHtml(n){
  const unreadClass=n.read_at?'':' unread';
  if(n.body&&n.body.startsWith('TICKET::'))return notifTicketHtml(n,unreadClass);
  const kd=notifKind(n);
  const rc=n.room_id?`<div class="rc"><span>Room ID: <b>${esc(n.room_id)}</b>${n.room_pass?' · Pass: <b>'+esc(n.room_pass)+'</b>':''}</span><button type="button" class="rc-copy" data-id="${esc(n.room_id)}" data-pass="${esc(n.room_pass||'')}" onclick="copyRoom(this,this.dataset.id,this.dataset.pass)">Copy</button></div>`:'';
  // friend requests/accepts (schema.sql "friends + direct messages") open the 💬 Messages panel (chat.js)
  const fr=kd.go&&(kd.go!=='chat'||window.jdChat)?`<button type="button" class="ni-go" onclick="notifGo('${kd.go}')">${kd.lbl} →</button>`:'';
  return `<div class="notif-item k-${kd.k}${unreadClass}"><span class="ni-ic" aria-hidden="true">${kd.ic}</span><div class="t">${esc(n.title)}</div>${n.body?`<div class="b">${esc(n.body)}</div>`:''}${rc}${fr}${notifTimeHtml(n.created_at)}</div>`;
}
/* ── chime: 'notify' plays the real notify.mp3 file; 'install' (and 'notify' if the
   file ever fails to play — blocked autoplay, missing file, etc.) falls back to a
   synthesized tone so there's always some sound. Browsers suspend AudioContext AND
   block <audio>.play() until a real user gesture, so both are primed lazily on the
   first tap/click anywhere rather than requiring a gesture at the exact moment a
   notification arrives. ── */
let _chimeCtx=null;
let _notifSound=null;
document.addEventListener('pointerdown',function unlockChime(){
  if(!_chimeCtx){try{_chimeCtx=new (window.AudioContext||window.webkitAudioContext)();}catch(e){}}
  else if(_chimeCtx.state==='suspended'){_chimeCtx.resume().catch(()=>{});}
  if(!_notifSound){try{_notifSound=new Audio('notify.mp3');_notifSound.volume=0.55;_notifSound.load();}catch(e){}}
},{passive:true});
// phone vibration for new notifications (Android browsers; iPhone ignores it)
function buzz(kind){try{if(navigator.vibrate)navigator.vibrate(kind==='roomcode'?[600,200,600,200,600]:kind==='result'?[120,60,120,60,120,60,500]:[180,90,180]);}catch(e){}}
// Room ID/password and results get their own sound, buzz and banner (same split as /sw.js)
function alertKind(n){if(!n)return '';const t=n.title||'';return /^room code/i.test(t)||n.room_id?'roomcode':/^results are in/i.test(t)?'result':'';}
// app-style banner that slides in with the newest notification; tap to open it
function notifBanner(n){
  let b=document.getElementById('notif-banner');
  if(!b){b=document.createElement('button');b.id='notif-banner';b.type='button';b.className='notif-banner';document.body.appendChild(b);}
  const isFriend=/^(👋 Friend request from|🤝 )/.test(n.title||'')&&!!window.jdChat;
  const isChallenge=!isFriend&&/challenge/i.test(n.title||'');
  const ak=alertKind(n);b.classList.toggle('nb-room',ak==='roomcode');b.classList.toggle('nb-result',ak==='result');
  const body=String(n.body||'').startsWith('TICKET::')?'Your ticket is ready — tap to view.':String(n.body||'');
  b.innerHTML=`<span class="nb-ic">${ak==='roomcode'?'🔑':ak==='result'?'🏆':isChallenge?'⚔️':isFriend?'👋':'🔔'}</span><span class="nb-t"><b>${esc(n.title||'New notification')}</b><small>${esc(body.slice(0,110))}${body.length>110?'…':''}</small></span>`;
  b.onclick=()=>{b.classList.remove('show');if(isChallenge)location.href='/challenges/';else if(isFriend)window.jdChat.open();else notifHistOpen();};
  b.classList.remove('show');void b.offsetWidth;b.classList.add('show');
  clearTimeout(b._t);b._t=setTimeout(()=>b.classList.remove('show'),6500);
}
function playChime(kind){
  if(kind==='notify'&&_notifSound){
    try{
      _notifSound.currentTime=0;
      const p=_notifSound.play();
      if(p&&p.catch)p.catch(()=>playSynthChime(kind));
      return;
    }catch(e){}
  }
  playSynthChime(kind);
}
function playSynthChime(kind){
  try{
    if(!_chimeCtx)_chimeCtx=new (window.AudioContext||window.webkitAudioContext)();
    if(_chimeCtx.state==='suspended')_chimeCtx.resume().catch(()=>{});
    const ctx=_chimeCtx,now=ctx.currentTime;
    /* 'install': bright ascending major triad (a little celebratory).
       'notify': a softer two-note ping (short, won't feel spammy if it fires often). */
    /* 'roomcode': three urgent same-pitch beeps. 'result': a rising four-note fanfare. */
    const notes=kind==='notify'?[783.99,987.77]:kind==='roomcode'?[880,880,880]:kind==='result'?[523.25,659.25,783.99,1046.5]:[523.25,659.25,783.99];
    const gap=kind==='notify'?0.11:kind==='roomcode'?0.22:kind==='result'?0.12:0.09;
    notes.forEach((freq,i)=>{
      const t=now+i*gap;
      const osc=ctx.createOscillator(),gain=ctx.createGain();
      osc.type='sine';osc.frequency.value=freq;
      gain.gain.setValueAtTime(0,t);
      gain.gain.linearRampToValueAtTime(0.2,t+0.015);
      gain.gain.exponentialRampToValueAtTime(0.0001,t+0.45);
      osc.connect(gain).connect(ctx.destination);
      osc.start(t);osc.stop(t+0.5);
    });
  }catch(e){}
}
// poll=true (the 5 s timer): first a tiny check (newest alert + unread count); the full list (~70 KB for an
// active player) only downloads when that changed. The list keeps the newest 80.
let _notifStamp=null;
async function loadNotifications(markSeenOnOpen,poll){
  const list=document.getElementById('notif-list');if(!list)return;
  if(!sb||!_player){list.innerHTML='<p class="sub">Log in to see your notifications.</p>';_notifUnread=0;updateNotifHistBtn();return;}
  if(poll&&_notifHasLoadedOnce){
    const [top,un]=await Promise.all([sb.from('notifications').select('id,created_at').eq('player_id',_player.id).order('created_at',{ascending:false}).limit(1),
      sb.from('notifications').select('id',{count:'exact',head:true}).eq('player_id',_player.id).is('read_at',null)]);
    if(!top.error&&!un.error){
      const stamp=((top.data&&top.data[0]&&top.data[0].id)||'')+'|'+(un.count||0);
      if(stamp===_notifStamp)return;
      _notifStamp=stamp;
    }
  }
  const {data,error}=await sb.from('notifications').select('*').eq('player_id',_player.id).order('created_at',{ascending:false}).limit(80);
  if(error){list.innerHTML='<p class="sub">Couldn\'t load notifications.</p>';return;}
  const rows=data||[];
  const prevUnread=_notifUnread;
  _notifUnread=rows.filter(r=>!r.read_at).length;
  _notifStamp=((rows[0]&&rows[0].id)||'')+'|'+_notifUnread;
  if(_notifUnread>prevUnread&&_notifHasLoadedOnce){const fresh=rows.find(r=>!r.read_at),ak=alertKind(fresh);playChime(ak||'notify');ringBell();buzz(ak);if(fresh)notifBanner(fresh);}
  _notifHasLoadedOnce=true;
  updateNotifHistBtn();
  // Latest room code per tournament (rows are newest-first), surfaced on that event's
  // match ticket + the next-match bar so players never have to dig through the inbox
  // at the exact moment they're racing to join the lobby.
  const rc=new Map();
  for(const r of rows)if(r.room_id&&r.tournament_slug&&!rc.has(r.tournament_slug))rc.set(r.tournament_slug,{room_id:r.room_id,room_pass:r.room_pass||''});
  if(JSON.stringify([...rc])!==JSON.stringify([..._roomCodes])){_roomCodes=rc;renderCur();saveOfflineTickets();}
  _notifRows=rows;if(markSeenOnOpen)_notifFilter='all';renderNotifList();
  if(markSeenOnOpen&&rows.some(r=>!r.read_at)){
    const ids=rows.filter(r=>!r.read_at).map(r=>r.id);
    sb.from('notifications').update({read_at:new Date().toISOString()}).in('id',ids).then(()=>{_notifUnread=0;updateNotifHistBtn();});
  }
}

/* ── preloader: shown from first paint, hidden once the page has actually finished
   loading — with a small floor so it doesn't just flash on a fast connection.
   Only the first page view of a session pays that floor; a player bouncing between
   this page and /leaderboard.html etc. within the same tab shouldn't see a mandatory
   half-second gate on every single navigation. ── */
(function(){
  const SEEN_KEY='jd_preloader_seen';
  let seen=false;
  try{seen=sessionStorage.getItem(SEEN_KEY)==='1';}catch(e){}
  const MIN_MS=seen?0:550;
  const shownAt=Date.now();
  function hidePreloader(){
    const pl=document.getElementById('preloader');
    if(!pl)return;
    const wait=Math.max(0,MIN_MS-(Date.now()-shownAt));
    setTimeout(()=>{
      pl.classList.add('hide');
      try{sessionStorage.setItem(SEEN_KEY,'1');}catch(e){}
    },wait);
  }
  if(document.readyState==='complete')hidePreloader();
  else window.addEventListener('load',hidePreloader);
})();

/* ── install as an app (PWA): real one-tap install on Android, guided Add-to-Home-Screen on iOS ── */
if('serviceWorker' in navigator && /^https?:$/.test(location.protocol)){
  navigator.serviceWorker.register('/sw.js',{scope:'/',updateViaCache:'none'}).catch(()=>{});
}
/* the Download button is only useful before the app is installed — once it's actually on the
   device, hide it (and give a little audio confirmation) instead of leaving a dead button around */
function hideDlBtn(){const w=document.getElementById('dl-wrap');if(w)w.style.display='none';}
function markInstalled(){hideDlBtn();playChime('install');}
if(navigator.standalone||window.matchMedia('(display-mode: standalone)').matches){hideDlBtn();}
let _deferredInstall=null;
window.addEventListener('beforeinstallprompt',e=>{e.preventDefault();_deferredInstall=e;});
window.addEventListener('appinstalled',()=>{_deferredInstall=null;markInstalled();});
function toggleDlMenu(e){if(e)e.stopPropagation();document.getElementById('dl-menu').classList.toggle('open');}
function closeDlMenu(){const m=document.getElementById('dl-menu');if(m)m.classList.remove('open');}
document.addEventListener('click',e=>{const wrap=document.getElementById('dl-wrap');if(wrap&&!wrap.contains(e.target))closeDlMenu();});
/* mobile nav: the top bar's account/leaderboard/download links collapse into this
   slide-in panel under 640px instead of wrapping into rows of tiny pills */
function toggleMobileNav(){
  const nav=document.getElementById('acct-nav'),scrim=document.getElementById('nav-scrim'),btn=document.getElementById('nav-toggle-btn');
  const open=nav.classList.toggle('open');
  scrim.classList.toggle('open',open);
  document.body.classList.toggle('nav-locked',open);
  btn.setAttribute('aria-expanded',open?'true':'false');
}
function closeMobileNav(){
  document.getElementById('acct-nav').classList.remove('open');
  document.getElementById('nav-scrim').classList.remove('open');
  document.body.classList.remove('nav-locked');
  const btn=document.getElementById('nav-toggle-btn');
  btn.setAttribute('aria-expanded','false');
}
document.getElementById('acct-nav').addEventListener('click',e=>{
  if(e.target.closest('#dl-btn'))return; // opens the download submenu in place, shouldn't close the panel
  if(e.target.closest('a,.lang-btn,.icon-btn,.dl-menu button')&&!e.target.closest('#dl-btn'))closeMobileNav();
});
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeMobileNav();});
function isIOSDevice(){return /iPad|iPhone|iPod/.test(navigator.userAgent)||(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1);}
function isAndroidDevice(){return /Android/i.test(navigator.userAgent);}
/* one tap on mobile: skip the picker and go straight to the right install flow.
   Desktop/unknown devices still get the picker since auto-detect doesn't apply there. */
function handleDlClick(e){
  if(isAndroidDevice())return downloadAndroid();
  if(isIOSDevice())return downloadIOS();
  toggleDlMenu(e);
}
/* Inside the app (JD_TWA, see isStandaloneApp) the download button says "already using the app", and a newer
   /download/android.json offers a one-tap update (once a day). */
if(JD_TWA>0)window.addEventListener('load',()=>setTimeout(async()=>{
  try{
    const d=await (await fetch('/download/android.json',{cache:'no-store'})).json();
    const day=new Date().toISOString().slice(0,10);
    if(d.versionCode>JD_TWA&&localStorage.getItem('jd_apk_upd')!==day){
      localStorage.setItem('jd_apk_upd',day);
      if(await confirmBox('⬇ App update ready',`JD Arena ${d.versionName}: ${d.notes||'a better app.'}\n\nTap Update, open the downloaded file and tap Install (Update). Your account and settings stay.`,'Update now','Later'))location.href=d.url;
    }
  }catch(e){}
},4000));
/* Old home-screen web app on Android (not the APK): ask once a day to install the real app and delete
   the web version, so alerts come through the app and don't arrive twice. Shown only when Chrome can
   confirm the APK isn't installed (manifest related_applications) - inside the app itself that check
   always finds the app, so this can never pop up there. */
/* App 2.0 (2026-10-27): a strip under the top bar for every Android visitor who isn't in the 2.0 app - the old
   1.x app (runs inside Chrome/Brave) gets "Update", a phone browser gets "Get the app". × hides it for this visit. */
async function appUpdateStrip(){
  if(JD_APP||!isAndroidDevice())return;
  try{if(sessionStorage.getItem('jd_upd_strip'))return;}catch(e){}
  let d;try{d=await (await fetch('/download/android.json',{cache:'no-store'})).json();}catch(e){return;}
  if(!d||!d.url)return;
  const old=JD_TWA!==0,el=document.createElement('div');
  el.className='app-upd';el.setAttribute('role','region');el.setAttribute('aria-label','App update');
  el.innerHTML=`<span class="app-upd-ic" aria-hidden="true">${old?'⬇':'📲'}</span><span class="app-upd-txt"><b>${old?'Update to JD Arena '+esc(d.versionName):'Get the JD Arena app'}</b>${old?'A real app now - no browser, no ad blockers, faster alerts. Sign in once after updating.':'Room IDs and alerts arrive as app notifications, even when JD Arena is closed.'}</span><button type="button" class="app-upd-go">${old?'Update':'Get app'}</button><button type="button" class="app-upd-x" aria-label="Hide">×</button>`;
  el.querySelector('.app-upd-go').onclick=()=>{location.href=old?d.url:'/download/?get=1';};
  el.querySelector('.app-upd-x').onclick=()=>{el.remove();try{sessionStorage.setItem('jd_upd_strip','1');}catch(e){}};
  const h=document.querySelector('header');if(h)h.insertAdjacentElement('afterend',el);else document.body.prepend(el);
}
appUpdateStrip();
/* Required update: an app older than android.json minVersionCode (2.0.2 = the one whose notifications work) gets a
   full screen with one Update button instead of the site - the same look as ui.js's "Get the app" screen.
   JD_TWA -1 = the old 1.x app opened from a notification (version unknown), which is older than any minimum. */
async function appRequiredUpdate(){
  if(!JD_TWA)return;
  let d;try{d=await (await fetch('/download/android.json',{cache:'no-store'})).json();}catch(e){return;}
  if(!d||!d.url||!d.minVersionCode||(JD_TWA>0&&JD_TWA>=d.minVersionCode))return;
  const g=document.createElement('div');
  g.className='app-gate';g.setAttribute('role','dialog');g.setAttribute('aria-modal','true');g.setAttribute('aria-labelledby','ag-t');
  g.innerHTML=`<div class="ag-card"><img src="/logo.webp" alt="" width="64" height="64"><h1 id="ag-t">Update JD Arena</h1>
    <p class="ag-lead">This version of the app is too old - room IDs and alerts won't reach you. The new version takes a minute and your account stays the same.</p>
    <a class="ag-btn" href="${esc(d.url)}">⬇ Update to ${esc(d.versionName)}</a>
    <ol class="ag-steps"><li>Tap <b>Update</b> and wait for the download</li><li>Open the downloaded file and tap <b>Install</b> (or Update)</li><li>Open <b>JD Arena</b> and sign in once</li></ol>
    <p class="ag-foot">Need help? <a href="https://wa.me/${SUPPORT_PHONE}" target="_blank" rel="noopener">WhatsApp ${esc(SUPPORT_PHONE_TXT)}</a></p></div>`;
  document.documentElement.classList.add('app-gated');
  document.body.appendChild(g);
}
appRequiredUpdate();
if(!JD_TWA&&isAndroidDevice()&&isStandaloneApp()&&navigator.getInstalledRelatedApps)window.addEventListener('load',()=>setTimeout(async()=>{
  try{
    const day=new Date().toISOString().slice(0,10);
    if(localStorage.getItem('jd_webapp_nag')===day)return;
    const apps=await navigator.getInstalledRelatedApps();
    if(apps.some(a=>a.id==='uk.co.jdesport.arena'))return;
    localStorage.setItem('jd_webapp_nag',day);
    if(await confirmBox('📲 Get the real JD Arena app','This is the old web version. The new Android app gets room IDs, results and challenge alerts as real app notifications that never get blocked - and your account stays the same.\n\n1. Tap Download app and install it.\n2. Then delete this web version: long-press this JD Arena icon on your home screen → Uninstall (or Remove).','Download app','Later'))location.href='/download/';
  }catch(e){}
},3000));
function downloadAndroid(){
  if(JD_TWA){showMsg('Already installed',"You're using the JD Arena app. 🎮");return;}
  location.href='/download/?get=1'; // the download page starts the APK download and shows the install steps
}
function downloadIOS(){
  if(isStandaloneApp()){showMsg('Already installed',"You're using the JD Arena home-screen app. 🎮");return;}
  showMsg('Install on iPhone/iPad',"1. In Safari, tap the Share icon (square with an arrow ↑). On newer iPhones tap ••• first, then Share.\n2. Scroll down and tap 'Add to Home Screen', then Add.\n3. Open JD Arena from the new gold JD icon on your home screen and allow notifications.\n\nNo App Store needed - it opens full-screen like an app.");
}
if(DISCORD_INVITE){document.querySelectorAll('.discord-cta').forEach(a=>a.href=DISCORD_INVITE);}else{document.querySelectorAll('.discord-cta').forEach(a=>a.style.display='none');}
applyLang();refresh();loadPublicRoster();tick();updateAcctBtn();updateNotifHistBtn();updatePushBtn();
// Also re-checks the player's own registrations/notifications on the same tick — otherwise
// a waitlist auto-promotion (or a room code, or anything else) sits invisible until they
// happen to reload, which undercuts "you'll be confirmed automatically, nothing to do".
/* 5s so slot counts/roster changes show up close to instantly without a manual reload —
   safe now that render() no-ops when nothing actually changed (see _lastGridHTML above),
   so most of these ticks touch zero DOM. Still skipped entirely on a backgrounded tab. */
setInterval(()=>{if(!document.hidden){refresh();loadPublicRoster(true);if(_player){loadMyRegs();loadNotifications(false,true);}}},5000);
setInterval(()=>{if(!document.hidden)checkLock();},30000);checkLock();
// coming back to the tab/app catches up immediately instead of on the next 5s tick
document.addEventListener('visibilitychange',()=>{if(!document.hidden){refresh();loadPublicRoster(true);if(_player){loadMyRegs();loadNotifications(false,true);}}});
setInterval(tick,1000);

/* ── scroll-reveal: fade+lift `.reveal` sections into view once, skipped entirely under
   prefers-reduced-motion (handled purely in CSS there, so this observer just adds a class
   that a reduced-motion stylesheet rule already neutralizes) ── */
if('IntersectionObserver' in window){
  const io=new IntersectionObserver(entries=>{entries.forEach(en=>{if(en.isIntersecting){en.target.classList.add('in-view');io.unobserve(en.target);}});},{threshold:.15});
  document.querySelectorAll('.reveal').forEach(el=>io.observe(el));
}else{
  document.querySelectorAll('.reveal').forEach(el=>el.classList.add('in-view'));
}

/* ── About link + feedback chatbot ── */
(function(){var a=document.getElementById('about-link');if(a){if(MAIN_SITE_URL)a.href=MAIN_SITE_URL;else a.style.display='none';}})();
/* ── ZULU (public) — JD Arena assistant. Answers PUBLIC stuff only (tournaments, joining, rules, contact),
   learns by logging questions to Prabin, and NEVER has access to the private plan. The page holds no secret
   data at all, so nothing can leak; the guard below is just on-brand deflection. ── */
var ZMODE='chat',fbData={msg:'',contact:''};
function pget(){try{return localStorage.getItem('jd_player')||''}catch(e){return ''}}
function pset(n){try{localStorage.setItem('jd_player',n)}catch(e){}}
var Z={
 en:{fab:'\uD83D\uDCAC Ask ZULU',zsub:'JD Arena assistant',zph:'Ask about tournaments, joining, rules\u2026',send:'Send',
  greet:"Hey \uD83D\uDC4B I'm ZULU, the JD Arena assistant. Ask me about tournaments, how to join, the rules, or how to reach Prabin.",
  greetn:"Welcome back, {x}! \uD83D\uDC4B I'm ZULU. Ask me about tournaments, joining, rules, or contact.",
  nameset:"Nice to meet you, {x}! I'll remember that. Now \u2014 ask me anything about JD Arena.",
  secret:"That part's private to Prabin \u2014 I only handle JD Arena: tournaments, how to join, the rules, and contact. Ask me any of those! \uD83C\uDFAE",
  wpass:"🎟 Weekly Pass: free JD tournaments cost no money - watch 3 short ads in the app to join, or skip the ads with a pass. Prizes are always paid in full, pass or no pass. Weekly Pass = 50 points: no ads to join + a lite squad effect. Weekly Pro = 80: Pro effect, 24 h early registration, first on waitlists, PRO badge. Invite friends: you both get +40 when they win their first prize. jdesport.co.uk/pass",
  howjoin:"Easy \u2014 5 steps:\n1. Sign up (your squad name is saved for next time).\n2. Load points: in your wallet, pay the eSewa QR and upload the payment screenshot.\n3. Tap Join on a tournament. Free ones confirm instantly; paid ones are paid from your points.\n4. Tap \"Confirm you're playing\" on the event. The confirm window opens 48 hours before start and closes 24 hours before \u2014 squads not confirmed by then lose their seat (entry points refunded).\n5. The Room ID + password appear on your ticket about 5 minutes before the match.",
  wallet:"Your JD points wallet: 1 point = Rs 1. Points are the only way to pay for paid entries and squad effects.\nTo load: open the wallet (the coin at the top) \u2192 Load \u2192 pay the eSewa QR with your username in the remarks, then upload the payment screenshot. No screenshot, no points. Points arrive once it's verified.",
  withdrawpts:"To cash out: open your wallet (the coin at the top) \u2192 Withdraw \u2192 enter the points, your eSewa ID and account name. The points leave your wallet now and the money is sent to your eSewa by hand, usually within a day.",
  refund:"Withdrawing from a paid tournament: 24h+ before the start = full refund, last 24 hours = 10% back, nothing once room details are out. Points refunds go straight back to your wallet. Tap Withdraw squad on your ticket.",
  effects:"Squad effects make your squad stand out on the site (cosmetic only): Rs 2 for one match, Rs 5 lite week, Rs 10 pro week, Rs 30 pro month (every effect, incl. Bullet Storm, Blade, Legend and the design styles: Liquid Glass, Spatial 3D, Clay, Brutal, Bento and more). Tap Squad effects on your ticket and pay with points. \u2728",
  profile:"Your profile (tap your name at the top) shows your rank, stats, points, tournaments and saved squad. Change your squad name or logo there \u2014 the logo is uploaded once and used for every tournament.",
  challenge:"Want a match now? Open \u2694\uFE0F Challenges (top menu): create a 1v1, 2v2, 3v3 or 4v4 Clash Squad challenge with a points stake, or accept one from the lobby. Both sides put in the same points and the winner takes the pot, minus just a 1-point platform fee per player (50 each \u2192 winner gets 98). Chat and share the room inside the challenge. 18+ only.",
  howjoinwa:"Tap the green Register button on any tournament to start on WhatsApp.",
  rules:"The basics: withdraw 24h+ before the start for a full refund, 10% back on the last day, no refund once the Room ID is sent \u00B7 cheating or modded apps = instant ban \u00B7 the prize pool is fixed and posted before registration opens \u00B7 entry fees go to JD Arena to fund prizes and keep tournaments running. Free tournaments? The prize is on us. Fair and clean. \uD83D\uDEE1\uFE0F",
  scoring:"Simple \u2014 each match your squad gets placement points from the official room result plus 1 point for every kill. All matches are added up and the highest total wins \ud83c\udfc6\n\nPosition points per match: 1st 12, 2nd 9, 3rd 8, 4th 7, 5th 6, 6th 5, 7th 4, 8th 3, 9th 2, 10th 1, 11th\u201312th 0. Kills: +1 each. Example: 1st with 5 kills + 3rd with 2 kills = (12 + 5) + (8 + 2) = 27 points.",
  hacker:"Zero mercy for hackers \u2014 proven cheating, modded apps, aimbot or wallhacks means an instant ban and the win/prize is voided on the spot, no appeal. Suspicious matches get their replay checked. Play clean and you've got nothing to worry about. \uD83D\uDEE1\uFE0F",
  payout:"Win and your prize lands in your points wallet automatically as JD points (1 point = Rs 1) \u2014 the full posted prize, no deductions. Withdraw it to your eSewa any time from the wallet page. \uD83D\uDCB0",
  prizenone:"No prize pool is posted right now \u2014 check back soon or watch the Discord.",
  entrynone:"No entry fee is posted right now \u2014 the next tournament's details are coming soon.",
  about:"Prabin Ayer runs JD Arena and the AyerFire brand \u2014 a Computing Science student in London with roots in Nepal. Full intro: open \u201CAbout Prabin\u201D.",
  contact:"Customer support (call or WhatsApp): "+SUPPORT_PHONE_TXT+" \u2014 send your username and a screenshot.\n\u2022 WhatsApp: https://wa.me/"+SUPPORT_PHONE+"\n\u2022 Discord: "+DISCORD_INVITE+"\n\u2022 Email: "+FEEDBACK_EMAIL+((typeof WHATSAPP_NUMBER==='string'&&WHATSAPP_NUMBER)?"\n\u2022 WhatsApp: tap any Register button":""),
  hi:"Hey! \uD83D\uDC4B Ask me about tournaments, joining, rules, or contact.",
  hin:"Hey {x}! \uD83D\uDC4B What do you want to know \u2014 tournaments, joining, or rules?",
  thanks:"Anytime! \uD83D\uDE4C Good luck in the lobby.",
  squadsize:"It's Squad mode \u2014 4 players per team. Solo/Duo aren't running right now, just Squad tournaments.",
  platform:"Mobile only, Free Fire BR \u2014 squad mode. No PC/emulator unless a tournament specifically says otherwise.",
  ack:"\uD83D\uDC4D",
  fbprompt:"Go ahead \u2014 tell me the issue or your suggestion, and I'll pass it straight to Prabin.",
  unknown:"I don't have that one yet \u2014 logged as ticket {x} for Prabin, quote that if you follow up. Meanwhile, ask me about tournaments, how to join, the rules, or contact. \uD83C\uDFAE",
  askc:"Got it. How can Prabin reach you if needed \u2014 Discord tag or email? (or type 'skip')",
  sent:"\u2705 Sent to Prabin \u2014 your ticket is {x}, quote it if you check back in. Thank you \u2014 this genuinely helps make JD Arena better. \uD83D\uDE4F",
  mail:"I'll open your email so you can send it to Prabin directly \uD83D\uDC47",
  chiprules:'\uD83D\uDCDC Rules',chippoints:'\uD83C\uDFC6 Points system',chippay:'\uD83D\uDCB0 Payment',chipwallet:'\uD83E\uDE99 Points',chipjoin:'\uD83C\uDFAE How to join',chiphelp:'\uD83C\uDFA7 Support',
  nudge0:"\uD83D\uDC4B New here? I can help you find a tournament to join.",
  nudge1:"\u2753 Got questions about entry fees or how payouts work? Just ask.",
  nudge2:"\uD83C\uDFAE Not sure how registration works? I'll walk you through it."},
 ne:{fab:'\uD83D\uDCAC ZULU \u0938\u094B\u0927\u094D\u0928\u0941\u0939\u094B\u0938\u094D',zsub:'JD Arena \u0938\u0939\u093E\u092F\u0915',zph:'\u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E, \u0938\u0939\u092D\u093E\u0917\u093F\u0924\u093E, \u0928\u093F\u092F\u092E \u0938\u094B\u0927\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u2026',send:'\u092A\u0920\u093E\u0909\u0928\u0941\u0939\u094B\u0938\u094D',
  greet:"\u0928\u092E\u0938\u094D\u0924\u0947 \uD83D\uDC4B \u092E ZULU \u0939\u0941\u0901, JD Arena \u0915\u094B \u0938\u0939\u093E\u092F\u0915\u0964 \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E, \u0915\u0938\u0930\u0940 \u0938\u0939\u092D\u093E\u0917\u0940 \u0939\u0941\u0928\u0947, \u0928\u093F\u092F\u092E, \u0935\u093E \u092A\u094D\u0930\u092C\u093F\u0928\u0932\u093E\u0908 \u0938\u092E\u094D\u092A\u0930\u094D\u0915 \u2014 \u0938\u094B\u0927\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964",
  greetn:"\u092B\u0947\u0930\u093F \u0938\u094D\u0935\u093E\u0917\u0924 \u091B, {x}! \uD83D\uDC4B \u092E ZULU \u0939\u0941\u0901\u0964 \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E, \u0938\u0939\u092D\u093E\u0917\u093F\u0924\u093E, \u0928\u093F\u092F\u092E \u0935\u093E \u0938\u092E\u094D\u092A\u0930\u094D\u0915 \u092C\u093E\u0930\u0947 \u0938\u094B\u0927\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964",
  nameset:"\u092D\u0947\u091F\u0947\u0930 \u0916\u0941\u0938\u0940 \u0932\u093E\u0917\u094D\u092F\u094B, {x}! \u092E \u092F\u094B \u0938\u092E\u094D\u091D\u0928\u094D\u091B\u0941\u0964 \u0905\u092C JD Arena \u092C\u093E\u0930\u0947 \u091C\u0947 \u092A\u0928\u093F \u0938\u094B\u0927\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964",
  secret:"\u0924\u094D\u092F\u094B \u092A\u094D\u0930\u092C\u093F\u0928\u0915\u094B \u0928\u093F\u091C\u0940 \u0915\u0941\u0930\u093E \u0939\u094B \u2014 \u092E \u0924 JD Arena \u092E\u093E\u0924\u094D\u0930\u0948 \u0939\u0947\u0930\u094D\u091B\u0941: \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E, \u0915\u0938\u0930\u0940 \u0938\u0939\u092D\u093E\u0917\u0940 \u0939\u0941\u0928\u0947, \u0928\u093F\u092F\u092E \u0930 \u0938\u092E\u094D\u092A\u0930\u094D\u0915\u0964 \u0924\u0940 \u0938\u094B\u0927\u094D\u0928\u0941\u0939\u094B\u0938\u094D! \uD83C\uDFAE",
  wpass:"🎟 साप्ताहिक पास: फ्री टुर्नामेन्ट सित्तैमा खेल्न पाइन्छ। २७ अक्टोबरदेखि पास नभएको टिमले पुरस्कार जितेमा ५० पॉइन्ट पासको लागि कट्छ (७ दिनको पास पाइन्छ)। पास भए पूरै पुरस्कार। Weekly Pro = ८०: Pro effect, २४ घण्टा अगाडि दर्ता, PRO badge। साथीलाई invite गर्नुहोस्: पहिलो जितमा दुवैलाई +४०। jdesport.co.uk/pass",
  howjoin:"\u0938\u091c\u093f\u0932\u094b \u2014 \u096b \u091a\u0930\u0923:\n\u0967. \u0938\u093e\u0907\u0928 \u0905\u092a \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d (\u091f\u093f\u092e\u0915\u094b \u0928\u093e\u092e \u0905\u0930\u094d\u0915\u094b \u092a\u091f\u0915\u0915\u093e \u0932\u093e\u0917\u093f \u0938\u0947\u092d \u0939\u0941\u0928\u094d\u091b)\u0964\n\u0968. \u092a\u094b\u0907\u0928\u094d\u091f \u0932\u094b\u0921 \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d: \u0935\u093e\u0932\u0947\u091f\u092e\u093e eSewa QR \u092c\u093e\u091f \u0924\u093f\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d \u0930 \u092d\u0941\u0915\u094d\u0924\u093e\u0928\u0940\u0915\u094b \u0938\u094d\u0915\u094d\u0930\u093f\u0928\u0938\u091f \u0905\u092a\u0932\u094b\u0921 \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d\u0964\n\u0969. \u092a\u094d\u0930\u0924\u093f\u092f\u094b\u0917\u093f\u0924\u093e\u092e\u093e Join \u0925\u093f\u091a\u094d\u0928\u0941\u0939\u094b\u0938\u094d\u0964 \u092b\u094d\u0930\u0940 \u0924\u0941\u0930\u0941\u0928\u094d\u0924\u0948 \u092a\u0915\u094d\u0915\u093e \u0939\u0941\u0928\u094d\u091b; \u092a\u0947\u0921 \u092a\u094b\u0907\u0928\u094d\u091f\u092c\u093e\u091f \u0924\u093f\u0930\u093f\u0928\u094d\u091b\u0964\n\u096a. \u092c\u0938 \u2014 \u091a\u0947\u0915-\u0907\u0928 \u091a\u093e\u0939\u093f\u0901\u0926\u0948\u0928\u0964 \u092a\u0915\u094d\u0915\u093e \u092d\u090f\u092a\u091b\u093f \u0924\u092a\u093e\u0908\u0902\u0915\u094b \u0938\u094d\u0932\u091f \u0930\u0939\u0928\u094d\u091b\u0964\n\u096b. \u0916\u0947\u0932 \u0938\u0941\u0930\u0941 \u0939\u0941\u0928\u0941\u092d\u0928\u094d\u0926\u093e \u0915\u0930\u093f\u092c \u096b \u092e\u093f\u0928\u0947\u091f\u0905\u0918\u093f Room ID \u0930 \u092a\u093e\u0938\u0935\u0930\u094d\u0921 \u091f\u093f\u0915\u091f\u092e\u093e \u0926\u0947\u0916\u093f\u0928\u094d\u091b\u0964",
  wallet:"\u0924\u092a\u093e\u0908\u0902\u0915\u094b JD \u092a\u094b\u0907\u0928\u094d\u091f \u0935\u093e\u0932\u0947\u091f: \u0967 \u092a\u094b\u0907\u0928\u094d\u091f = \u0930\u0941 \u0967\u0964 \u092a\u0947\u0921 \u092a\u094d\u0930\u0924\u093f\u092f\u094b\u0917\u093f\u0924\u093e \u0930 squad effect \u092a\u094b\u0907\u0928\u094d\u091f\u092c\u093e\u091f \u092e\u093e\u0924\u094d\u0930 \u0924\u093f\u0930\u094d\u0928 \u0938\u0915\u093f\u0928\u094d\u091b\u0964\n\u0932\u094b\u0921 \u0917\u0930\u094d\u0928: \u0935\u093e\u0932\u0947\u091f \u0916\u094b\u0932\u094d\u0928\u0941\u0939\u094b\u0938\u094d (\u092e\u093e\u0925\u093f\u0915\u094b \u0915\u094b\u0907\u0928) \u2192 Load \u2192 remarks \u092e\u093e \u0906\u092b\u094d\u0928\u094b username \u0932\u0947\u0916\u0947\u0930 eSewa QR \u092c\u093e\u091f \u0924\u093f\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d, \u0905\u0928\u093f \u092d\u0941\u0915\u094d\u0924\u093e\u0928\u0940\u0915\u094b \u0938\u094d\u0915\u094d\u0930\u093f\u0928\u0938\u091f \u0905\u092a\u0932\u094b\u0921 \u0917\u0930\u094d\u0928\u0941\u0939\u094b\u0938\u094d\u0964 \u0938\u094d\u0915\u094d\u0930\u093f\u0928\u0938\u091f \u092c\u093f\u0928\u093e \u092a\u094b\u0907\u0928\u094d\u091f \u0925\u092a\u093f\u0901\u0926\u0948\u0928\u0964 \u091c\u093e\u0901\u091a\u092a\u091b\u093f \u092a\u094b\u0907\u0928\u094d\u091f \u0906\u0909\u0901\u091b\u0964",
  withdrawpts:"\u092A\u0948\u0938\u093E \u0928\u093F\u0915\u093E\u0932\u094D\u0928: \u0935\u093E\u0932\u0947\u091F \u0916\u094B\u0932\u094D\u0928\u0941\u0939\u094B\u0938\u094D (\u092E\u093E\u0925\u093F\u0915\u094B \u0915\u094B\u0907\u0928) \u2192 Withdraw \u2192 \u092A\u094B\u0907\u0928\u094D\u091F, eSewa ID \u0930 \u0916\u093E\u0924\u093E\u0915\u094B \u0928\u093E\u092E \u0932\u0947\u0916\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964 \u092A\u094B\u0907\u0928\u094D\u091F \u0924\u0941\u0930\u0941\u0928\u094D\u0924\u0948 \u0935\u093E\u0932\u0947\u091F\u092C\u093E\u091F \u0918\u091F\u094D\u091B \u0930 \u092A\u0948\u0938\u093E \u092A\u094D\u0930\u093E\u092F\u0903 \u090F\u0915 \u0926\u093F\u0928\u092D\u093F\u0924\u094D\u0930 eSewa \u092E\u093E \u092A\u0920\u093E\u0907\u0928\u094D\u091B\u0964",
  refund:"\u092A\u0947\u0921 \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E\u092C\u093E\u091F \u0939\u091F\u094D\u0926\u093E: \u0938\u0941\u0930\u0941 \u0939\u0941\u0928\u0941 \u0968\u096A \u0918\u0923\u094D\u091F\u093E\u0905\u0918\u093F = \u092A\u0942\u0930\u093E \u0930\u093F\u092B\u0928\u094D\u0921, \u0905\u0928\u094D\u0924\u093F\u092E \u0968\u096A \u0918\u0923\u094D\u091F\u093E = \u0967\u0966%, Room ID \u092A\u0920\u093E\u090F\u092A\u091B\u093F \u0915\u0947\u0939\u0940 \u092A\u0928\u093F \u091B\u0948\u0928\u0964 \u092A\u094B\u0907\u0928\u094D\u091F\u0915\u094B \u0930\u093F\u092B\u0928\u094D\u0921 \u0938\u093F\u0927\u0948 \u0935\u093E\u0932\u0947\u091F\u092E\u093E \u0906\u0909\u0901\u091B\u0964 \u091F\u093F\u0915\u091F\u092E\u093E Withdraw squad \u0925\u093F\u091A\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964",
  effects:"Squad effect \u0932\u0947 \u0938\u093E\u0907\u091F\u092E\u093E \u0924\u092A\u093E\u0908\u0902\u0915\u094B \u091F\u093F\u092E\u0932\u093E\u0908 \u092B\u0930\u0915 \u0926\u0947\u0916\u093E\u0909\u0901\u091B (\u0926\u0947\u0916\u093E\u0935\u091F\u0940 \u092E\u093E\u0924\u094D\u0930): \u090F\u0915 \u0916\u0947\u0932 \u0930\u0941 \u0968, \u0932\u093E\u0907\u091F \u0939\u092A\u094D\u0924\u093E \u0930\u0941 \u096B, \u092A\u094D\u0930\u094B \u0939\u092A\u094D\u0924\u093E \u0930\u0941 \u0967\u0966, \u092A\u094D\u0930\u094B \u092E\u0939\u093F\u0928\u093E \u0930\u0941 \u0969\u0966 (\u0938\u092C\u0948 effect)\u0964 \u091F\u093F\u0915\u091F\u092E\u093E Squad effects \u0925\u093F\u091A\u0947\u0930 \u092A\u094B\u0907\u0928\u094D\u091F\u092C\u093E\u091F \u0924\u093F\u0930\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964 \u2728",
  profile:"\u0924\u092A\u093E\u0908\u0902\u0915\u094B \u092A\u094D\u0930\u094B\u092B\u093E\u0907\u0932 (\u092E\u093E\u0925\u093F \u0906\u092B\u094D\u0928\u094B \u0928\u093E\u092E \u0925\u093F\u091A\u094D\u0928\u0941\u0939\u094B\u0938\u094D) \u092E\u093E \u0930\u094D\u200D\u092F\u093E\u0919\u094D\u0915, \u0924\u0925\u094D\u092F\u093E\u0919\u094D\u0915, \u092A\u094B\u0907\u0928\u094D\u091F, \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E \u0930 \u0938\u0947\u092D \u0917\u0930\u093F\u090F\u0915\u094B \u091F\u093F\u092E \u0926\u0947\u0916\u093F\u0928\u094D\u091B\u0964 \u0924\u094D\u092F\u0939\u0940\u0901\u092C\u093E\u091F \u091F\u093F\u092E\u0915\u094B \u0928\u093E\u092E \u0935\u093E \u0932\u094B\u0917\u094B \u092C\u0926\u0932\u094D\u0928\u0941\u0939\u094B\u0938\u094D \u2014 \u0932\u094B\u0917\u094B \u090F\u0915 \u092A\u091F\u0915 \u0905\u092A\u0932\u094B\u0921 \u0917\u0930\u0947\u092A\u091B\u093F \u0938\u092C\u0948 \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E\u092E\u093E \u092A\u094D\u0930\u092F\u094B\u0917 \u0939\u0941\u0928\u094D\u091B\u0964",
  challenge:"\u0905\u0939\u093F\u0932\u0947 \u0928\u0948 \u0916\u0947\u0932\u094D\u0928 \u091A\u093E\u0939\u0928\u0941\u0939\u0941\u0928\u094D\u091B? \u2694\uFE0F Challenges (\u092E\u093E\u0925\u093F\u0915\u094B \u092E\u0947\u0928\u0941) \u0916\u094B\u0932\u094D\u0928\u0941\u0939\u094B\u0938\u094D: \u092A\u094B\u0907\u0928\u094D\u091F \u0930\u093E\u0916\u0947\u0930 1v1, 2v2, 3v3 \u0935\u093E 4v4 Clash Squad \u091A\u094D\u092F\u093E\u0932\u0947\u0928\u094D\u091C \u092C\u0928\u093E\u0909\u0928\u0941\u0939\u094B\u0938\u094D, \u0935\u093E lobby \u092C\u093E\u091F \u0938\u094D\u0935\u0940\u0915\u093E\u0930 \u0917\u0930\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964 \u0926\u0941\u0935\u0948 \u092A\u0915\u094D\u0937\u0932\u0947 \u0909\u0924\u094D\u0924\u093F\u0915\u0948 \u092A\u094B\u0907\u0928\u094D\u091F \u0930\u093E\u0916\u094D\u091B\u0928\u094D \u0930 \u091C\u093F\u0924\u094D\u0928\u0947\u0932\u0947 \u092A\u094B\u091F \u092A\u093E\u0909\u0901\u091B \u2014 \u092A\u094D\u0930\u0924\u093F \u0916\u0947\u0932\u093E\u0921\u0940 \u0967 \u092A\u094B\u0907\u0928\u094D\u091F \u092E\u093E\u0924\u094D\u0930 platform fee (\u096B\u0966-\u096B\u0966 \u2192 \u091C\u093F\u0924\u094D\u0928\u0947\u0932\u0947 \u096F\u096E)\u0964 \u091A\u094D\u092F\u093E\u0932\u0947\u0928\u094D\u091C\u092D\u093F\u0924\u094D\u0930\u0948 \u091A\u094D\u092F\u093E\u091F \u0930 room \u0936\u0947\u092F\u0930 \u0917\u0930\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964 \u0967\u096E+ \u092E\u093E\u0924\u094D\u0930\u0964",
  howjoinwa:"\u0915\u0941\u0928\u0948 \u092A\u0928\u093F \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E\u092E\u093E \u0939\u0930\u093F\u092F\u094B Register \u092C\u091F\u0928 \u0925\u093F\u091A\u0940 WhatsApp \u092E\u093E \u0938\u0941\u0930\u0941 \u0917\u0930\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964",
  rules:"\u092E\u0941\u0916\u094D\u092F \u0915\u0941\u0930\u093E: \u0938\u0941\u0930\u0941 \u0939\u0941\u0928\u0941 \u0968\u096A \u0918\u0923\u094D\u091F\u093E\u0905\u0918\u093F \u091B\u094B\u0921\u0947 \u092A\u0942\u0930\u093E \u0930\u093F\u092B\u0928\u094D\u0921, \u0905\u0928\u094D\u0924\u093F\u092E \u0926\u093F\u0928 \u0967\u0966% \u092E\u093E\u0924\u094D\u0930, Room ID \u092A\u0920\u093E\u090F\u092A\u091B\u093F \u0930\u093F\u092B\u0928\u094D\u0921 \u0939\u0941\u0901\u0926\u0948\u0928 \u00B7 \u091A\u093F\u091F\u093F\u0919 \u0935\u093E \u092E\u094B\u0921 \u0917\u0930\u093F\u090F\u0915\u094B \u090F\u092A = \u0924\u0941\u0930\u0941\u0928\u094D\u0924\u0948 \u092C\u094D\u092F\u093E\u0928 \u00B7 \u0907\u0928\u093E\u092E \u0930\u0915\u092E \u0926\u0930\u094D\u0924\u093E \u0916\u0941\u0932\u094D\u0928\u0941\u0905\u0918\u093F \u0928\u0948 \u0924\u094B\u0915\u093F\u0928\u094D\u091B \u00B7 \u092A\u094D\u0930\u0935\u0947\u0936 \u0936\u0941\u0932\u094D\u0915 JD Arena \u0932\u0947 \u0907\u0928\u093E\u092E \u0930 \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E \u091A\u0932\u093E\u0909\u0928 \u0930\u093E\u0916\u094D\u091B\u0964 \u092B\u094D\u0930\u0940 \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E? \u0907\u0928\u093E\u092E \u0939\u093E\u092E\u094D\u0930\u094B \u0924\u0930\u094D\u092B\u092C\u093E\u091F\u0964 \u0928\u093F\u0937\u094D\u092A\u0915\u094D\u0937 \u0930 \u0938\u092B\u093E\u0964 \uD83D\uDEE1\uFE0F",
  scoring:"\u0938\u091c\u093f\u0932\u094b \u2014 \u0939\u0930\u0947\u0915 \u092e\u094d\u092f\u093e\u091a\u092e\u093e \u0924\u092a\u093e\u0908\u0902\u0915\u094b \u0938\u094d\u0915\u094d\u0935\u093e\u0921\u0932\u0947 \u0906\u0927\u093f\u0915\u093e\u0930\u093f\u0915 \u0930\u0941\u092e \u0928\u0924\u093f\u091c\u093e\u0905\u0928\u0941\u0938\u093e\u0930 \u0938\u094d\u0925\u093e\u0928 \u0905\u0919\u094d\u0915 \u092a\u093e\u0909\u0901\u091b, \u0938\u093e\u0925\u0948 \u0939\u0930\u0947\u0915 \u0915\u093f\u0932\u0915\u094b \u0967 \u0905\u0919\u094d\u0915\u0964 \u0938\u092c\u0948 \u092e\u094d\u092f\u093e\u091a\u0915\u093e \u0905\u0919\u094d\u0915 \u091c\u094b\u0921\u093f\u0928\u094d\u091b\u0928\u094d, \u0938\u092c\u0948\u092d\u0928\u094d\u0926\u093e \u0927\u0947\u0930\u0948 \u091c\u092e\u094d\u092e\u093e \u0905\u0919\u094d\u0915 \u0939\u0941\u0928\u0947 \u0938\u094d\u0915\u094d\u0935\u093e\u0921 \u091c\u093f\u0924\u094d\u091b \ud83c\udfc6\n\n\u0939\u0930\u0947\u0915 \u092e\u094d\u092f\u093e\u091a\u0915\u094b \u0938\u094d\u0925\u093e\u0928 \u0905\u0919\u094d\u0915: \u092a\u0939\u093f\u0932\u094b 12, \u0926\u094b\u0938\u094d\u0930\u094b 9, \u0924\u0947\u0938\u094d\u0930\u094b 8, \u091a\u094c\u0925\u094b 7, \u092a\u093e\u0901\u091a\u094c\u0902 6, \u091b\u0948\u091f\u094c\u0902 5, \u0938\u093e\u0924\u094c\u0902 4, \u0906\u0920\u094c\u0902 3, \u0928\u0935\u094c\u0902 2, \u0926\u0936\u094c\u0902 1, 11-12\u0914\u0902 0\u0964 \u0915\u093f\u0932: \u0939\u0930\u0947\u0915\u0915\u094b +1\u0964 \u0909\u0926\u093e\u0939\u0930\u0923: \u092a\u0939\u093f\u0932\u094b + 5 \u0915\u093f\u0932, \u0924\u0947\u0938\u094d\u0930\u094b + 2 \u0915\u093f\u0932 = (12 + 5) + (8 + 2) = 27 \u0905\u0919\u094d\u0915\u0964",
  hacker:"\u0939\u094D\u092F\u093E\u0915\u0930/\u091A\u093F\u091F\u0930\u0932\u093E\u0908 \u0915\u0941\u0928\u0948 \u091B\u0941\u091F \u091B\u0948\u0928 \u2014 \u092A\u094D\u0930\u092E\u093E\u0923\u093F\u0924 \u091A\u093F\u091F\u093F\u0919, \u092E\u094B\u0921 \u0917\u0930\u093F\u090F\u0915\u094B \u090F\u092A, \u0910\u092E\u092C\u091F \u0935\u093E \u0935\u093E\u0932\u0939\u094D\u092F\u093E\u0915 \u092D\u0947\u091F\u093F\u092F\u094B \u092D\u0928\u0947 \u0924\u0941\u0930\u0941\u0928\u094D\u0924\u0948 \u092C\u094D\u092F\u093E\u0928 \u0930 \u091C\u093F\u0924\u0947\u0915\u094B \u0907\u0928\u093E\u092E \u0924\u0941\u0930\u0941\u0928\u094D\u0924\u0948 \u0930\u0926\u094D\u0926, \u0915\u0941\u0928\u0948 \u0905\u092A\u093F\u0932 \u091B\u0948\u0928\u0964 \u0936\u0902\u0915\u093E\u0938\u094D\u092A\u0926 \u092E\u094D\u092F\u093E\u091A\u092E\u093E \u0930\u093F\u092A\u094D\u0932\u0947 \u091C\u093E\u0901\u091A \u0917\u0930\u093F\u0928\u094D\u091B\u0964 \u0938\u092B\u093E \u0916\u0947\u0932\u094D\u0928\u0941\u0939\u094B\u0938\u094D, \u091A\u093F\u0928\u094D\u0924\u093E \u0932\u093F\u0928\u0941 \u092A\u0930\u094D\u0926\u0948\u0928\u0964 \uD83D\uDEE1\uFE0F",
  payout:"\u091C\u093F\u0924\u094D\u0928\u0941\u092D\u092F\u094B \u092D\u0928\u0947 \u0907\u0928\u093E\u092E JD \u092A\u094B\u0907\u0928\u094D\u091F\u0915\u094B \u0930\u0942\u092A\u092E\u093E \u0924\u092A\u093E\u0908\u0902\u0915\u094B \u0935\u093E\u0932\u0947\u091F\u092E\u093E \u0906\u092B\u0948\u0902 \u0906\u0909\u0901\u091B (\u0967 \u092A\u094B\u0907\u0928\u094D\u091F = \u0930\u0941 \u0967) \u2014 \u092A\u0942\u0930\u093E \u0907\u0928\u093E\u092E, \u0915\u0941\u0928\u0948 \u0915\u091F\u094C\u0924\u0940 \u091B\u0948\u0928\u0964 \u0935\u093E\u0932\u0947\u091F \u092A\u0947\u091C\u092C\u093E\u091F \u091C\u0941\u0928\u0938\u0941\u0915\u0948 \u092C\u0947\u0932\u093E eSewa \u092E\u093E \u0928\u093F\u0915\u093E\u0932\u094D\u0928 \u0938\u0915\u094D\u0928\u0941\u0939\u0941\u0928\u094D\u091B\u0964 \uD83D\uDCB0",
  prizenone:"\u0905\u0939\u093F\u0932\u0947 \u0907\u0928\u093E\u092E \u0930\u093E\u0916\u093F\u090F\u0915\u094B \u091B\u0948\u0928 \u2014 \u091A\u093E\u0901\u0921\u0948 \u0939\u0947\u0930\u094D\u0928\u0941\u0939\u094B\u0938\u094D \u0935\u093E Discord \u0939\u0947\u0930\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964",
  entrynone:"\u0905\u0939\u093F\u0932\u0947 \u092A\u094D\u0930\u0935\u0947\u0936 \u0936\u0941\u0932\u094D\u0915 \u0930\u093E\u0916\u093F\u090F\u0915\u094B \u091B\u0948\u0928 \u2014 \u0905\u0930\u094D\u0915\u094B \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E\u0915\u094B \u0935\u093F\u0935\u0930\u0923 \u091A\u093E\u0901\u0921\u0948 \u0906\u0909\u0901\u0926\u0948\u0964",
  about:"\u092A\u094D\u0930\u092C\u093F\u0928 \u0906\u092F\u0930 JD Arena \u0930 AyerFire \u091A\u0932\u093E\u0909\u0901\u091B\u0928\u094D \u2014 \u0932\u0928\u094D\u0921\u0928\u092E\u093E \u0930\u0939\u0947\u0915\u093E, \u0928\u0947\u092A\u093E\u0932\u0940 \u091C\u0930\u093E \u092D\u090F\u0915\u093E Computing Science \u0935\u093F\u0926\u094D\u092F\u093E\u0930\u094D\u0925\u0940\u0964 \u092A\u0942\u0930\u093E \u092A\u0930\u093F\u091A\u092F: \u201CAbout Prabin\u201D \u0916\u094B\u0932\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964",
  contact:"\u0917\u094D\u0930\u093E\u0939\u0915 \u0938\u0939\u093E\u092F\u0924\u093E (\u092B\u094B\u0928 \u0935\u093E WhatsApp): "+SUPPORT_PHONE_TXT+" \u2014 \u0906\u092B\u094D\u0928\u094B username \u0930 screenshot \u092A\u0920\u093E\u0909\u0928\u0941\u0939\u094B\u0938\u094D\u0964\n\u2022 WhatsApp: https://wa.me/"+SUPPORT_PHONE+"\n\u2022 Discord: "+DISCORD_INVITE+"\n\u2022 \u0907\u092E\u0947\u0932: "+FEEDBACK_EMAIL+((typeof WHATSAPP_NUMBER==='string'&&WHATSAPP_NUMBER)?"\n\u2022 WhatsApp: \u0915\u0941\u0928\u0948 Register \u092C\u091F\u0928 \u0925\u093F\u091A\u094D\u0928\u0941\u0939\u094B\u0938\u094D":""),
  hi:"\u0928\u092E\u0938\u094D\u0924\u0947! \uD83D\uDC4B \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E, \u0938\u0939\u092D\u093E\u0917\u093F\u0924\u093E, \u0928\u093F\u092F\u092E \u0935\u093E \u0938\u092E\u094D\u092A\u0930\u094D\u0915 \u092C\u093E\u0930\u0947 \u0938\u094B\u0927\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964",
  hin:"\u0928\u092E\u0938\u094D\u0924\u0947 {x}! \uD83D\uDC4B \u0915\u0947 \u0925\u093E\u0939\u093E \u092A\u093E\u0909\u0928 \u091A\u093E\u0939\u0928\u0941\u0939\u0941\u0928\u094D\u091B \u2014 \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E, \u0938\u0939\u092D\u093E\u0917\u093F\u0924\u093E \u0935\u093E \u0928\u093F\u092F\u092E?",
  thanks:"\u091C\u0939\u093F\u0932\u0947 \u092A\u0928\u093F! \uD83D\uDE4C \u0932\u092C\u0940\u092E\u093E \u0936\u0941\u092D\u0915\u093E\u092E\u0928\u093E\u0964",
  squadsize:"\u092F\u094B Squad mode \u0939\u094B \u2014 \u091F\u093F\u092E\u092E\u093E \u096A \u091C\u0928\u093E\u0964 \u0905\u0939\u093F\u0932\u0947 Solo/Duo \u091B\u0948\u0928, Squad \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E \u092E\u093E\u0924\u094D\u0930 \u091B\u0964",
  platform:"\u092E\u094B\u092C\u093E\u0907\u0932 \u092E\u093E\u0924\u094D\u0930, Free Fire BR \u2014 squad mode\u0964 \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E\u0932\u0947 \u0928\u092D\u0928\u0947\u0938\u0940 PC/emulator \u091A\u0932\u094D\u0926\u0948\u0928\u0964",
  ack:"\uD83D\uDC4D",
  fbprompt:"\u092D\u0928\u094D\u0928\u0941\u0939\u094B\u0938\u094D \u2014 \u0938\u092E\u0938\u094D\u092F\u093E \u0935\u093E \u0938\u0941\u091D\u093E\u0935 \u0932\u0947\u0916\u094D\u0928\u0941\u0939\u094B\u0938\u094D, \u092E \u092A\u094D\u0930\u092C\u093F\u0928\u0932\u093E\u0908 \u0938\u093F\u0927\u0948 \u092A\u0920\u093E\u0909\u0901\u091B\u0941\u0964",
  unknown:"\u0924\u094D\u092F\u094B \u0905\u091D\u0948 \u092E\u0932\u093E\u0908 \u0925\u093E\u0939\u093E \u091B\u0948\u0928 \u2014 \u091F\u093F\u0915\u091F {x} \u092D\u0928\u0947\u0930 \u092A\u094D\u0930\u092C\u093F\u0928\u0932\u093E\u0908 \u0932\u0917 \u0917\u0930\u093F\u092F\u094B, \u092A\u091B\u093F \u0938\u094B\u0927\u094D\u0926\u093E \u092F\u094B \u0928\u092E\u094D\u092C\u0930 \u092D\u0928\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964 \u0905\u0939\u093F\u0932\u0947 \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E, \u0938\u0939\u092D\u093E\u0917\u093F\u0924\u093E, \u0928\u093F\u092F\u092E \u0935\u093E \u0938\u092E\u094D\u092A\u0930\u094D\u0915 \u0938\u094B\u0927\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964 \uD83C\uDFAE",
  askc:"\u092C\u0941\u091D\u0947\u0901\u0964 \u0906\u0935\u0936\u094D\u092F\u0915 \u092A\u0930\u0947 \u092A\u094D\u0930\u092C\u093F\u0928\u0932\u0947 \u0915\u0938\u0930\u0940 \u0938\u092E\u094D\u092A\u0930\u094D\u0915 \u0917\u0930\u094D\u0928\u0947 \u2014 Discord \u091F\u094D\u092F\u093E\u0917 \u0935\u093E \u0907\u092E\u0947\u0932? ('skip' \u0932\u0947\u0916\u094D\u0928 \u0938\u0915\u094D\u0928\u0941\u0939\u0941\u0928\u094D\u091B)",
  sent:"\u2705 \u092A\u094D\u0930\u092C\u093F\u0928\u0932\u093E\u0908 \u092A\u0920\u093E\u0907\u092F\u094B \u2014 \u0924\u092A\u093E\u0908\u0902\u0915\u094B \u091F\u093F\u0915\u091F {x} \u0939\u094B, \u092A\u091B\u093F \u0938\u094B\u0927\u094D\u0926\u093E \u092F\u0939\u0940 \u0928\u092E\u094D\u092C\u0930 \u092D\u0928\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964 \u0927\u0928\u094D\u092F\u0935\u093E\u0926 \u2014 \u092F\u0938\u0932\u0947 JD Arena \u0930\u093E\u092E\u094D\u0930\u094B \u092C\u0928\u093E\u0909\u0928 \u0938\u093E\u091A\u094D\u091A\u0948 \u092E\u0926\u094D\u0926\u0924 \u0917\u0930\u094D\u091B\u0964 \uD83D\uDE4F",
  mail:"\u0924\u092A\u093E\u0908\u0902\u0915\u094B \u0907\u092E\u0947\u0932 \u0916\u094B\u0932\u094D\u091B\u0941 \u0924\u093E\u0915\u093F \u0938\u093F\u0927\u0948 \u092A\u094D\u0930\u092C\u093F\u0928\u0932\u093E\u0908 \u092A\u0920\u093E\u0909\u0928 \u0938\u0915\u094D\u0928\u0941\u0939\u094B\u0938\u094D \uD83D\uDC47",
  chiprules:'\uD83D\uDCDC \u0928\u093F\u092F\u092E',chippoints:'\uD83C\uDFC6 \u0905\u0919\u094D\u0915 \u092A\u094D\u0930\u0923\u093E\u0932\u0940',chippay:'\uD83D\uDCB0 \u092D\u0941\u0915\u094D\u0924\u093E\u0928\u0940',chipjoin:'\uD83C\uDFAE \u0915\u0938\u0930\u0940 \u091C\u094B\u0921\u093F\u0928\u0947',chiphelp:'\uD83C\uDFA7 \u0938\u0939\u093E\u092F\u0924\u093E',
  nudge0:"\uD83D\uDC4B \u0928\u092F\u093E\u0901 \u0939\u0941\u0928\u0941\u0939\u0941\u0928\u094D\u091B? \u092E \u0924\u092A\u093E\u0908\u0902\u0932\u093E\u0908 \u0909\u092A\u092F\u0941\u0915\u094D\u0924 \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E \u092B\u0947\u0932\u093E \u092A\u093E\u0930\u094D\u0928 \u092E\u0926\u094D\u0926\u0924 \u0917\u0930\u094D\u0928 \u0938\u0915\u094D\u091B\u0941\u0964",
  nudge1:"\u2753 \u092A\u094D\u0930\u0935\u0947\u0936 \u0936\u0941\u0932\u094D\u0915 \u0935\u093E \u092D\u0941\u0915\u094D\u0924\u093E\u0928\u0940 \u092C\u093E\u0930\u0947 \u092A\u094D\u0930\u0936\u094D\u0928 \u091B? \u0938\u093F\u0927\u0948 \u0938\u094B\u0927\u094D\u0928\u0941\u0939\u094B\u0938\u094D\u0964",
  nudge2:"\uD83C\uDFAE \u0926\u0930\u094D\u0924\u093E \u0915\u0938\u0930\u0940 \u0917\u0930\u094D\u0928\u0947 \u0925\u093E\u0939\u093E \u091B\u0948\u0928? \u092E \u0924\u092A\u093E\u0908\u0902\u0932\u093E\u0908 \u091A\u0930\u0923\u092C\u0926\u094D\u0927 \u0930\u0942\u092A\u092E\u093E \u0926\u0947\u0916\u093E\u0909\u0901\u091B\u0941\u0964"}
};
function zL(k,a){var s=(Z[lang]&&Z[lang][k]!=null)?Z[lang][k]:Z.en[k];if(s==null)s='';return a?s.replace('{x}',a):s;}
function zChrome(){if(typeof Z==='undefined'||!Z)return;var f=document.getElementById('fab');if(f)f.textContent=zL('fab');var s=document.getElementById('z-sub');if(s)s.textContent=zL('zsub');var i=document.getElementById('fb-input');if(i)i.setAttribute('placeholder',zL('zph'));var b=document.getElementById('z-send');if(b)b.textContent=zL('send');}
function fbOpen(){dismissNudge();document.getElementById('fb-panel').classList.add('open');document.getElementById('fab').style.display='none';if(!document.getElementById('fb-msgs').children.length){var nm=pget();fbBot(nm?zL('greetn',nm):zL('greet'));fbChips();}setTimeout(function(){document.getElementById('fb-input').focus();},120);}
/* Proactive nudge bubble -- shows once per tab session (sessionStorage, not
   localStorage: a returning visitor next session gets one fresh chance, this
   isn't meant to become a permanently-dismissed thing) if the chat hasn't
   already been opened, picking a random hint so it's not the exact same line
   every time. Engaging with the chat at all (fbOpen) turns off the FAB's pulse
   too -- the "come talk to me" signal has done its job once someone has. */
function pickNudge(){var keys=['nudge0','nudge1','nudge2'];return zL(keys[Math.floor(Math.random()*keys.length)]);}
function showNudge(){
  var panel=document.getElementById('fb-panel');if(panel&&panel.classList.contains('open'))return;
  try{if(sessionStorage.getItem('zulu_nudge_seen'))return;}catch(e){}
  var n=document.getElementById('fab-nudge'),t=document.getElementById('fab-nudge-text');
  if(!n||!t)return;
  t.textContent=pickNudge();
  n.classList.add('show');
  try{sessionStorage.setItem('zulu_nudge_seen','1');}catch(e){}
}
function dismissNudge(){
  var n=document.getElementById('fab-nudge');if(n)n.classList.remove('show');
  var f=document.getElementById('fab');if(f)f.classList.add('fab-quiet');
}
/* One-tap presets for the questions new players ask most — skips typing and any
   chance of a regex miss, since these go straight to the same canned answers
   zuluPublic() would give, not through its keyword matching. */
function fbChips(){
  var defs=[['chipjoin','howjoin'],['chipwallet','wallet'],['chippay','payout'],['chiprules','rules'],['chippoints','scoring'],['chiphelp','contact']];
  var wrap=document.createElement('div');wrap.className='fb-chips';
  defs.forEach(function(d){
    var b=document.createElement('button');b.type='button';b.className='fb-chip';b.textContent=zL(d[0]);
    b.onclick=function(){
      fbMe(zL(d[0]));
      setTimeout(function(){
        var txt=d[1]==='howjoin'?(zL('howjoin')+((typeof WHATSAPP_NUMBER==='string'&&WHATSAPP_NUMBER)?('\n'+zL('howjoinwa')):'')):zL(d[1]);
        fbBot(txt);
      },220);
    };
    wrap.appendChild(b);
  });
  document.getElementById('fb-msgs').appendChild(wrap);
  fbScroll();
}
function fbClose(){document.getElementById('fb-panel').classList.remove('open');document.getElementById('fab').style.display='';}
function fbScroll(){var b=document.getElementById('fb-msgs');b.scrollTop=b.scrollHeight;}
function fbBot(t){var m=document.createElement('div');m.className='fb-msg bot';m.textContent=t;document.getElementById('fb-msgs').appendChild(m);fbScroll();}
// An AI reply: site paths become tap buttons, plus 🔊 read-aloud once it has finished (chat.js helpers).
function zuluShow(el,text,streaming){
  el.innerHTML='<span class="dm-zt">'+(typeof window.zuluRender==='function'?window.zuluRender(text):esc(text))+'</span>'+
    (!streaming&&typeof window.zuluSpeak==='function'?'<button type="button" class="dm-say" aria-label="Read aloud" title="Read aloud">🔊</button>':'');
  var b=el.querySelector('.dm-say');
  if(b)b.onclick=function(){var err=window.zuluSpeak(el.querySelector('.dm-zt').textContent,b);if(err&&!b.nextElementSibling){b.insertAdjacentHTML('afterend','<span class="dm-sayerr">'+esc(err)+'</span>');setTimeout(function(){var n=b.nextElementSibling;if(n)n.remove();},4000);}};
  fbScroll();
}
function fbMe(t){var m=document.createElement('div');m.className='fb-msg me';m.textContent=t;document.getElementById('fb-msgs').appendChild(m);fbScroll();}
function fbSend(){var inp=document.getElementById('fb-input');var t=inp.value.trim();if(!t)return;inp.value='';fbMe(t);
  if(ZMODE==='fb'){fbData.msg=t;ZMODE='fbc';setTimeout(function(){fbBot(zL('askc'));},300);return;}
  if(ZMODE==='fbc'){fbData.contact=/^(skip|no|nah)$/i.test(t)?'(not given)':t;ZMODE='chat';fbSubmit('feedback');return;}
  setTimeout(function(){zuluRespond(t);},220);}
function zuluRespond(q){
  if(typeof ZULU_PUBLIC_URL==='string'&&ZULU_PUBLIC_URL){zuluAsk(q);return;}
  var m=zuluPersonalMatch(q);
  if(m){
    if(m.async){
      var th=document.createElement('div');th.className='fb-msg bot';th.textContent='…';document.getElementById('fb-msgs').appendChild(th);fbScroll();
      m.fn().then(function(text){th.textContent=text;fbScroll();}).catch(function(){var a=zuluPublic(q);th.textContent=a.text;fbScroll();});
      return;
    }
    fbBot(m.fn());return;
  }
  var a=zuluPublic(q);
  // Short questions and the fixed flows (private-topic refusal, feedback, "my name is")
  // keep the instant built-in answer. Anything else goes to the online AI, which knows
  // the same facts plus the live schedule and this chat's history; the built-in answer
  // is the fallback if the AI is unavailable.
  var fixed=a.feedback||a.text===zL('secret')||/(my (name|squad|team) is|call me)/i.test(q);
  var shortQ=q.trim().split(/\s+/).length<=3&&!/(next|slot|seat|space|full|when|kahile|kati|tournament|match|winner|won|result)/i.test(q);
  if(!a.learn&&(fixed||shortQ)){fbBot(a.text);zuluRemember(q,a.text);if(a.feedback)ZMODE='fb';return;}
  // If the AI call fails (no key, quota, outage) the built-in answer is shown instead, and
  // an unanswerable question still gets logged as a ticket, so nothing just vanishes.
  var th=document.createElement('div');th.className='fb-msg bot';th.textContent='…';document.getElementById('fb-msgs').appendChild(th);fbScroll();
  zuluAiReply(q,function(t){zuluShow(th,t,true);}).then(function(reply){
    if(reply){zuluShow(th,reply,false);zuluRemember(q,reply);}
    else{th.textContent=a.text;if(a.learn)logLearn('question',q,a.ticket);zuluRemember(q,a.text);}
    fbScroll();
  });
}
// For the ZULU chat in 💬 Messages (chat.js), which replaces this panel for logged-in
// players: the same built-in answers as zuluRespond() — personal ones (your room ID, your
// match time) and instant short ones — without touching this panel's DOM. Resolves to
// { text } when a built-in answer should be used as is, or { fallback } when the online AI
// should answer and fallback is only for when the AI is unavailable.
window.zuluLocalAnswer=async function(q){
  try{
    var m=zuluPersonalMatch(q);
    if(m){var t=m.async?await m.fn():m.fn();if(t)return {text:String(t)};}
    // everything else goes to the AI so ZULU can actually chat ("hi", "how are you", jokes);
    // the built-in answer is only the fallback when the AI is busy. The private-topic refusal
    // stays instant.
    var a=zuluPublic(q);
    if(a.text===zL('secret'))return {text:a.text};
    return {fallback:a.text};
  }catch(e){return null;}
};
// Rolling memory of this chat (last 8 turns) so the AI can follow "and the entry fee?".
var zuluHist=[];
function zuluRemember(q,reply){zuluHist.push({role:'user',content:String(q).slice(0,500)},{role:'assistant',content:String(reply).slice(0,500)});if(zuluHist.length>8)zuluHist=zuluHist.slice(-8);}
// Last-resort reply via zulu-ai-reply (Gemini) — only reached when zuluPersonalMatch()
// and zuluPublic()'s keyword table both come up empty, so this never competes with the
// free, instant, deterministic answers for anything already known. Returns null (not a
// thrown error) on any failure so the caller can fall back to the ticket-log behavior.
async function zuluAiReply(q,onText){
  try{
    if(typeof window.zuluFetch==='function')return await window.zuluFetch({message:q,lang:lang,history:zuluHist},onText);   // word by word (chat.js)
    const res=await fetch(EDGE_FN_BASE+'/zulu-ai-reply',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({message:q,lang:lang,history:zuluHist})});
    if(!res.ok)return null;
    const d=await res.json();
    return d.reply||null;
  }catch(e){return null;}
}
function tourList(){var d=_lastData||{};return (d.tournaments||[]).filter(function(t){var s=t.status||'upcoming';return s!=='completed'&&s!=='cancelled';});}
function scheduleInfo(){var ts=tourList();var ne=(lang==='ne');if(!ts.length)return ne?'\u0905\u0939\u093F\u0932\u0947 \u0915\u0941\u0928\u0948 \u0924\u094B\u0915\u093F\u090F\u0915\u094B \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E \u091B\u0948\u0928 \u2014 Discord \u0939\u0947\u0930\u094D\u0926\u0948 \u0917\u0930\u094D\u0928\u0941\u0939\u094B\u0938\u094D!':"No tournaments scheduled right now \u2014 keep an eye on the Discord!";var head=ne?'\u0906\u0917\u093E\u092E\u0940 \u092A\u094D\u0930\u0924\u093F\u092F\u094B\u0917\u093F\u0924\u093E:':"Here's what's coming up:";var lines=ts.slice(0,4).map(function(t){var meta=[];if(t.date)meta.push(t.date);if(t.time)meta.push(t.time);if(t.prize)meta.push((ne?'\u0907\u0928\u093E\u092E ':'Prize ')+t.prize);if((t.status||'')==='live')meta.push(ne?'\u2022 \u0905\u0939\u093F\u0932\u0947 \u0932\u093E\u0907\u092D':'\u2022 LIVE now');return '\u2022 '+(t.name||'Tournament')+(meta.length?(' \u2014 '+meta.join(' \u00b7 ')):'');});return head+'\n'+lines.join('\n');}
function slotsInfo(){var ts=tourList();var ne=(lang==='ne');var t=ts[0];if(!t)return ne?'\u0905\u0939\u093F\u0932\u0947 \u0926\u0930\u094D\u0924\u093E \u0916\u0941\u0932\u093E \u091B\u0948\u0928\u0964':"No open registrations right now.";var reg=(t.registered!=null?t.registered:0),sl=(t.slots!=null?t.slots:'?');return (t.name||'The next tournament')+': '+reg+'/'+sl+(ne?' \u091F\u093F\u092E \u0926\u0930\u094D\u0924\u093E \u092D\u0907\u0938\u0915\u0947\u0964':' teams registered.');}
function leaderInfo(){var d=_lastData||{};var ne=(lang==='ne');var B=d.bo3;var rows=(B&&B.published&&B.teams&&B.teams.length)?bo3Standings(B):[];if(!rows.length)return ne?'\u0905\u0939\u093F\u0932\u0947\u0938\u092E\u094D\u092E \u0928\u0924\u093F\u091C\u093E \u092A\u094D\u0930\u0915\u093E\u0936\u093F\u0924 \u091B\u0948\u0928\u0964':"No results published yet.";var hint=ne?'\n\n(\u0915\u093F\u0932 \u0967 \u0905\u0919\u094D\u0915 + \u0938\u094D\u0925\u093E\u0928: \u0967\u0932\u094B 12 \u00B7 \u0968\u0932\u094B 9 \u00B7 \u0969\u0932\u094B 6 \u00B7 \u096A\u0925\u094D\u0925\u094B 5 \u00B7 \u096B\u0925\u094D\u0925\u094B 4 \u00B7 \u096C\u0925\u094D\u0925\u094B 3 \u00B7 \u096D\u0925\u094D\u0925\u094B 2 \u00B7 \u096E\u0925\u094D\u0925\u094B 1)':'\n\n(1 pt/kill + placement: 1st 12 \u00B7 2nd 9 \u00B7 3rd 6 \u00B7 4th 5 \u00B7 5th 4 \u00B7 6th 3 \u00B7 7th 2 \u00B7 8th 1)';return (ne?'\u092C\u0947\u0938\u094D\u091F-\u0905\u092B-\u0969 \u0928\u0924\u093F\u091C\u093E:':'Best-of-3 standings:')+'\n'+rows.map(function(x){return x.rank+'. '+(x.team||'')+' \u2014 '+(x.totalPts||0)+(ne?' \u0905\u0919\u094D\u0915':' pts');}).join('\n')+hint;}
function tourField(f,none){var t=tourList()[0];if(!t||!t[f])return none;return (t.name||'The next tournament')+': '+t[f];}

/* ── personalized answers: "when's my match", "what's my room ID", "how many points
   to reach top 3" — these read _player/_myRegs/_lastData/notifications that are
   already loaded client-side for a logged-in player, so no new backend is needed.
   zuluPersonalMatch() gates these behind clearly-possessive phrasing ("my"/"our")
   so a generic "when's the next tournament?" still falls through to scheduleInfo()
   unchanged. Kept separate from zuluPublic()'s keyword table since these need
   _player/live data instead of being pure static-text lookups. ── */
function myMatchInfo(){
  var ne=(lang==='ne');
  if(!sb||!_player)return ne?'पहिले लगइन गर्नुहोस्, अनि म तपाईंको दर्ता जाँच्न सक्छु।':'Log in first (top right) and I can check your registrations.';
  var entries=Array.from(_myRegs.entries()).map(function(e){var t=((_lastData||{}).tournaments||[]).find(function(x){return x.name===e[0]})||{name:e[0]};return {t:t,reg:e[1]};});
  var active=entries.filter(function(e){return e.reg.status==='confirmed'||e.reg.status==='approved';});
  if(!active.length){
    var pend=entries.find(function(e){return e.reg.status==='pending'||e.reg.status==='waitlisted';});
    if(pend)return ne?('"'+pend.t.name+'" को लागि तपाईं अहिले '+(pend.reg.status==='waitlisted'?'प्रतीक्षा सूचीमा':'भुक्तानी पुष्टिको पर्खाइमा')+' हुनुहुन्छ — अझै पुष्टि भएको छैन।'):('For "'+pend.t.name+'" you\'re currently '+(pend.reg.status==='waitlisted'?'on the waitlist':'awaiting payment approval')+' — not confirmed yet, so no match time locked in.');
    return ne?'तपाईं अहिलेसम्म कुनै प्रतियोगितामा दर्ता हुनुभएको छैन — कुनै कार्डको Register थिच्नुहोस्।':"You're not registered for anything yet — hit Register on a tournament card and I'll track it here.";
  }
  var lines=active.map(function(e){
    var t=e.t,when=[t.date,t.time].filter(Boolean).join(' · ')||(ne?'मिति मिति हुने बाँकी':'TBA');
    var ci=e.reg.checked_in_at?(ne?' ✔️ चेक-इन भइसक्यो':' ✔️ Checked in'):'';
    return '• '+t.name+' — '+when+ci;
  });
  return (ne?'तपाईंको म्याच:':"Your match(es):")+'\n'+lines.join('\n');
}
async function myRoomCodeInfo(){
  var ne=(lang==='ne');
  if(!sb||!_player)return ne?'पहिले लगइन गर्नुहोस्, अनि म रूम कोड जाँच्न सक्छु।':'Log in first and I can check for a room code.';
  try{
    var res=await sb.from('notifications').select('room_id,room_pass,tournament_slug,created_at').eq('player_id',_player.id).not('room_id','is',null).order('created_at',{ascending:false}).limit(1);
    var rows=res.data;
    if(res.error||!rows||!rows.length)return ne?'अझै रूम कोड पठाइएको छैन — पठाइएपछि यहीं देखाउँछु।':"No room code sent yet — I'll show it here the moment the host sends one, usually shortly before your match.";
    var n=rows[0];
    return (ne?('"'+(n.tournament_slug||'')+'" को रूम कोड:'):('Room code for "'+(n.tournament_slug||'your match')+'":'))+'\nRoom ID: '+n.room_id+(n.room_pass?' · Pass: '+n.room_pass:'');
  }catch(e){return ne?'अहिले जाँच्न सकिएन — फेरि प्रयास गर्नुहोस्।':"Couldn't check that right now — try again in a moment.";}
}
function myPointsGapInfo(){
  var ne=(lang==='ne');
  if(!sb||!_player)return ne?'पहिले लगइन गर्नुहोस्, अनि म तपाईंको टिमको स्थान जाँच्न सक्छु।':"Log in and I can check your squad's standing.";
  var B=(_lastData||{}).bo3;
  if(!B||!B.published||!B.teams||!B.teams.length)return ne?'अहिलेसम्म कुनै प्रत्यक्ष नतिजा प्रकाशित छैन।':'No live standings published yet.';
  var reg=_myRegs.get(B.tournament);
  var squad=reg&&reg.squad_name;
  if(!squad)return ne?('तपाईं "'+(B.tournament||'')+'" मा दर्ता हुनुभएको छैन, त्यसैले यी नतिजामा तपाईंको टिम भेटिएन।'):("You're not registered for \""+(B.tournament||'the current bracket')+"\", so I can't find your squad in these standings.");
  var rows=bo3Standings(B);
  var mine=rows.find(function(r){return r.team===squad;});
  if(!mine)return ne?('"'+squad+'" अहिलेको नतिजामा भेटिएन — राउन्ड १ सुरु भएपछि फेरि सोध्नुहोस्।'):('Couldn\'t find "'+squad+'" in the current standings yet — check back once round 1 is in.');
  if(mine.rank<=3)return ne?('तपाईं पहिले नै #'+mine.rank+' स्थानमा हुनुहुन्छ, '+mine.totalPts+' अंकका साथ — जारी राख्नुहोस्!'):("You're already #"+mine.rank+" with "+mine.totalPts+" pts — keep it up!");
  var third=rows.find(function(r){return r.rank===3;});
  var gap=third?Math.max(0,third.totalPts-mine.totalPts+1):null;
  return ne?('तपाईं #'+mine.rank+' स्थानमा हुनुहुन्छ, '+mine.totalPts+' अंक। तेस्रो स्थानमा '+(third?third.totalPts:'?')+' अंक छ — टप ३ मा पुग्न '+(gap!=null?gap+' थप':'केही थप')+' अंक चाहिन्छ।'):("You're #"+mine.rank+" with "+mine.totalPts+" pts. 3rd place has "+(third?third.totalPts:'?')+" pts — you need "+(gap!=null?gap+' more':'a few more')+" to break into the top 3.");
}
function zuluPersonalMatch(q){
  var s=q.toLowerCase();
  if(/\broom\b.*(id|code|pass)|\b(id|code|pass)\b.*\broom\b/.test(s))return {fn:myRoomCodeInfo,async:true};
  if(/\b(my|our)\b/.test(s)&&/(match|game|play|slot|when|kahile|कहिले)/.test(s))return {fn:myMatchInfo,async:false};
  if(/(kill leader|top killer|most kills|kill king|top frag|top scorer)/.test(s))return {fn:seasonKillLeaderInfo,async:true};
  var teamGap=extractTeamGapQuestion(s);
  if(teamGap)return {fn:function(){return pointsGapToTeamInfo(teamGap);},async:false};
  if(/\b(my|our|we|i)\b/.test(s)&&/(point|score|top\s*3|top\s*three|catch|behind|need)/.test(s))return {fn:myPointsGapInfo,async:false};
  return null;
}
// "how many points to beat/pass/catch team X" — X has to be a squad name that
// actually appears in the CURRENT live bracket, matched as a case-insensitive
// substring of the question (no NLP entity extraction, just string containment
// against a short, known list of team names).
function extractTeamGapQuestion(s){
  if(!/(beat|pass|overtake|catch|ahead of|above)/.test(s))return null;
  var B=(_lastData||{}).bo3;
  if(!B||!B.teams||!B.teams.length)return null;
  var found=null;
  for(var i=0;i<B.teams.length;i++){
    var name=B.teams[i]&&B.teams[i].team;
    if(name&&s.indexOf(String(name).toLowerCase())!==-1){found=name;break;}
  }
  return found;
}
function pointsGapToTeamInfo(teamName){
  var ne=(lang==='ne');
  if(!sb||!_player)return ne?'पहिले लगइन गर्नुहोस्।':'Log in first and I can check the gap.';
  var B=(_lastData||{}).bo3;
  if(!B||!B.published||!B.teams||!B.teams.length)return ne?'अहिलेसम्म कुनै प्रत्यक्ष नतिजा प्रकाशित छैन।':'No live standings published yet.';
  var reg=_myRegs.get(B.tournament);
  var squad=reg&&reg.squad_name;
  if(!squad)return ne?'तपाईं यो प्रतियोगितामा दर्ता हुनुभएको छैन।':"You're not registered for this tournament.";
  var rows=bo3Standings(B);
  var mine=rows.find(function(r){return r.team===squad;});
  var theirs=rows.find(function(r){return r.team===teamName;});
  if(!mine||!theirs)return ne?'त्यो टिम फेला परेन।':"Couldn't find that squad in the current standings.";
  var gap=theirs.totalPts-mine.totalPts;
  if(gap<=0)return ne?('तपाईं पहिले नै "'+teamName+'" भन्दा माथि हुनुहुन्छ ('+mine.totalPts+' बनाम '+theirs.totalPts+' अंक)।'):('You\'re already ahead of "'+teamName+'" — '+mine.totalPts+' vs their '+theirs.totalPts+' pts.');
  return ne?('"'+teamName+'" लाई उछिन्न तपाईंलाई '+(gap+1)+' थप अंक चाहिन्छ ('+mine.totalPts+' बनाम '+theirs.totalPts+')।'):('You need '+(gap+1)+' more points to pass "'+teamName+'" — you\'re at '+mine.totalPts+', they\'re at '+theirs.totalPts+'.');
}
async function seasonKillLeaderInfo(){
  var ne=(lang==='ne');
  if(!sb)return ne?'अहिले जाँच्न सकिएन।':"Can't check that on this deploy.";
  try{
    var res=await sb.rpc('get_season_kill_leaders',{p_limit:5});
    var rows=res.data;
    if(res.error||!rows||!rows.length)return ne?'अहिलेसम्म कुनै किल डाटा छैन।':'No kill data yet this season.';
    var lines=rows.map(function(r,i){return (i+1)+'. '+(r.username?'@'+r.username:r.player_tag)+' — '+r.total_kills+(ne?' किल':' kills');});
    return (ne?'यस सिजनको टप किलरहरू:':"This season's top killers:")+'\n'+lines.join('\n');
  }catch(e){return ne?'अहिले जाँच्न सकिएन।':"Couldn't check that right now.";}
}
function zuluPublic(q){var s=q.toLowerCase();
  var nm=q.match(/(?:my (?:name|squad|team) is|i am|i'?m|call me)\s+([\w][\w\- ]{1,22})/i);
  if(nm){var name=nm[1].trim();pset(name);return {text:zL('nameset',name)};}
  if(/(phase|factory|chemical|business plan|business model|strateg|future plan|road ?map|expansion|manufactur|\binvest|profit|revenue|estate|jhalari|empire|product line|\bcrore\b|\blakh\b|jd silk|jd fresh)/.test(s))return {text:zL('secret')};
  if(/(feedback|complain|complaint|\bbug\b|issue|problem|suggest|report|broke|not working|doesn'?t work)/.test(s))return {text:zL('fbprompt'),feedback:true};
  if(/(how.*(join|register|sign|enter|\bplay\b)|^join|register|sign ?up|kasari|\u0915\u0938\u0930\u0940)/.test(s))return {text:zL('howjoin')+((typeof WHATSAPP_NUMBER==='string'&&WHATSAPP_NUMBER)?('\n'+zL('howjoinwa')):'')};
  if(/(weekly pass|\bpass\b|subscription|subscribe|weekly pro|पास)/.test(s))return {text:zL('wpass')};
  if(/(hack|hacker|hacking|cheat|cheater|cheating|aimbot|aim bot|wallhack|mod menu|modded)/.test(s))return {text:zL('hacker')};
  if(/(challenge|1v1|2v2|3v3|4v4|clash squad|\bcs\b|wager|\bbet\b|versus|\bvs\b|play against|custom room)/.test(s))return {text:zL('challenge')};
  if(/(refund|cancel.*(entry|registration|squad)|withdraw (my )?(squad|team|registration)|leave (the )?(tournament|match)|late cancel)/.test(s))return {text:zL('refund')};
  if(/(withdraw|cash ?out|take out (money|points)|points? to esewa|get (my )?money out|nikal|\u0928\u093F\u0915\u093E\u0932)/.test(s))return {text:zL('withdrawpts')};
  if(/(effect|glow|animation|bullet storm|blade|legend|galaxy|thunder|liquid glass|spatial|bento|brutal|clay|neumorph|glassmorph|skeuomorph|pro pass|lite pass|\bpass\b)/.test(s))return {text:zL('effects')};
  if(/(wallet|load points|add points|buy points|top ?up|recharge|jd points?|my points|point balance|\bbalance\b|\bcoins?\b|how.*get points|qr|\u092A\u094B\u0907\u0928\u094D\u091F)/.test(s))return {text:zL('wallet')};
  if(/(profile|my account|squad logo|change logo|team logo|squad name|team name|avatar|profile pic)/.test(s))return {text:zL('profile')};
  if(/(winning money|win.*money|get.*(paid|money)|receive.*(money|prize|winnings)|withdraw|claim.*(prize|money|winnings)|\besewa\b|how.*paid|\bpayout\b)/.test(s))return {text:zL('payout')};
  if(/(rule|refund|fair|\bban\b|scam|is it safe|trust|legit)/.test(s))return {text:zL('rules')};
  if(/(squad size|team size|how many player|players per team|\bsolo\b|\bduo\b)/.test(s))return {text:zL('squadsize')};
  if(/(platform|device|which phone|emulator|\bpc\b|laptop|\btab(let)?\b|android|ios\b)/.test(s))return {text:zL('platform')};
  if(/^(ok|okay|k|kk|cool|nice|great|good|got it|alright|bye|goodbye|see ya|gg)\b/.test(s))return {text:zL('ack')};
  if(/(prize|pool|reward|inaam|\u0907\u0928\u093E\u092E)/.test(s))return {text:tourField('prize',zL('prizenone'))};
  if(/(entry|fee|cost|price|how much|kati|\u0915\u0924\u093F)/.test(s))return {text:tourField('entry',zL('entrynone'))};
  if(/(slot|spot|seat|how many team|space|is it full|\bfull\b)/.test(s))return {text:slotsInfo()};
  if(/(how.*(point|scor)|point(s)? system|scoring system|placement point|kill point|points? per kill|how.*calculat)/.test(s))return {text:zL('scoring')};
  if(/(leaderboard|standing|\brank|top team|who.*(win|lead)|\bpoints?\b|\bscore)/.test(s))return {text:leaderInfo()};
  if(/(when|schedule|next|\btime\b|\bmatch|tournament|today|tonight|upcoming|kahile|\u0915\u0939\u093F\u0932\u0947|playing)/.test(s))return {text:scheduleInfo()};
  if(/(who.*(prabin|you|run|made|own|behind)|about prabin|^about|owner|founder|ayerfire|developer|who built)/.test(s))return {text:zL('about')};
  if(/(contact|discord|whatsapp|reach|email|message prabin|support|\bhelp\b)/.test(s))return {text:zL('contact')};
  if(/^(hi|hey|hello|yo|sup|hii+|hlo|namaste|namaskar)\b/.test(s)||/^(\u0928\u092E\u0938\u094D\u0924\u0947|\u0928\u092E\u0938\u094D\u0915\u093E\u0930)/.test(q))return {text:pget()?zL('hin',pget()):zL('hi')};
  if(/(thank|thanks|thanx|thx|dhanyabad|\u0927\u0928\u094D\u092F\u0935\u093E\u0926|\bty\b)/.test(s))return {text:zL('thanks')};
  var ticket=genTicket();return {text:zL('unknown',ticket),learn:true,ticket:ticket};}
/* \u2500\u2500 ticket number so a visitor and Prabin can both reference the same escalation \u2500\u2500 */
function genTicket(){var d=new Date();var ymd=d.getFullYear().toString().slice(2)+String(d.getMonth()+1).padStart(2,'0')+String(d.getDate()).padStart(2,'0');var rnd=Math.random().toString(36).slice(2,6).toUpperCase();return 'JD-'+ymd+'-'+rnd;}
/* delivery order: an explicit Discord webhook (owner opt-in) > a same-origin /feedback server
   (if zulu_server.py is ever deployed there). GitHub Pages has no form-capture service of its
   own (unlike the old Netlify deploy), so if both of those are unavailable this just rejects \u2014
   the caller (fbFallback, see below) already degrades to a mailto: link in that case, so
   nothing is silently lost. */
function deliverFeedback(fields){
  if(typeof FEEDBACK_WEBHOOK==='string'&&FEEDBACK_WEBHOOK){
    var content='\uD83C\uDFAE JD Arena ['+fields.ticket+'] '+fields.kind+'\n'+fields.message+'\n\u2014 '+fields.contact;
    return fetch(FEEDBACK_WEBHOOK,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({content:content})});
  }
  var same=(/^https?:$/.test(location.protocol))?location.origin.replace(/\/$/,'')+'/feedback':null;
  return same?fetch(same,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(fields)}).then(function(r){if(!r.ok)throw 0;return r;}):Promise.reject();
}
function logLearn(kind,text,ticket){
  deliverFeedback({ticket:ticket||genTicket(),kind:kind,who:pget()||'visitor',contact:pget()||'(visitor)',message:'['+kind+'] '+text}).catch(function(){});
}
function zuluAsk(q){var th=document.createElement('div');th.className='fb-msg bot';th.textContent='\u2026';document.getElementById('fb-msgs').appendChild(th);fbScroll();
  fetch(ZULU_PUBLIC_URL.replace(/\/$/,'')+'/public',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({message:q,who:pget()||'visitor'})}).then(function(r){return r.ok?r.json():Promise.reject();}).then(function(d){th.textContent=(d&&d.reply)?d.reply:zuluPublic(q).text;fbScroll();}).catch(function(){var a=zuluPublic(q);th.textContent=a.text;if(a.learn)logLearn('question',q,a.ticket);if(a.feedback)ZMODE='fb';fbScroll();});}
function fbDone(ticket){fbBot(zL('sent',ticket));}
function fbSubmit(kind){var stamp=new Date().toLocaleString();var ticket=genTicket();var msg='Message: '+fbData.msg+'\nWhen: '+stamp;
  deliverFeedback({ticket:ticket,kind:kind||'feedback',who:pget()||'visitor',contact:fbData.contact,message:msg}).then(function(){fbDone(ticket);}).catch(function(){fbFallback(ticket);});}
function fbFallback(ticket){fbBot(zL('mail'));var body=encodeURIComponent("Ticket: "+ticket+"\nFeedback: "+fbData.msg+"\nContact: "+fbData.contact);setTimeout(function(){window.location.href="mailto:"+FEEDBACK_EMAIL+"?subject="+encodeURIComponent("JD Arena feedback ["+ticket+"]")+"&body="+body;},700);}
document.getElementById('fb-input').addEventListener('keydown',function(e){if(e.key==='Enter'){e.preventDefault();fbSend();}});
zChrome();
setTimeout(showNudge,13000);
