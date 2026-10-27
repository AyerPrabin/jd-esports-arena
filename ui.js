// JD Arena shared UI: injects the phone bottom tab bar (styled in /ui.css, shown only
// at <=640px) on every player-facing page, and marks the current tab. Icons are
// Phosphor "bold" (MIT, @phosphor-icons/core), inlined so there's no icon-font download.
if (window.JDApp || /JDArenaApp\//.test(navigator.userAgent)) document.documentElement.classList.add('jd-app'); // see html.jd-app in ui.css
(function () {
  if (document.querySelector('.tabbar')) return;
  var P = function (d) { return '<svg viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="' + d + '"/></svg>'; };
  var ICON = {
    home: P('M222.14,105.85l-80-80a20,20,0,0,0-28.28,0l-80,80A19.86,19.86,0,0,0,28,120v96a12,12,0,0,0,12,12H216a12,12,0,0,0,12-12V120A19.86,19.86,0,0,0,222.14,105.85ZM204,204H52V121.65l76-76,76,76Z'),
    events: P('M232,60H212V48a12,12,0,0,0-12-12H56A12,12,0,0,0,44,48V60H24A20,20,0,0,0,4,80V96a44.05,44.05,0,0,0,44,44h.77A84.18,84.18,0,0,0,116,195.15V212H96a12,12,0,0,0,0,24h64a12,12,0,0,0,0-24H140V195.11c30.94-4.51,56.53-26.2,67-55.11h1a44.05,44.05,0,0,0,44-44V80A20,20,0,0,0,232,60ZM28,96V84H44v28c0,1.21,0,2.41.09,3.61A20,20,0,0,1,28,96Zm160,15.1c0,33.33-26.71,60.65-59.54,60.9A60,60,0,0,1,68,112V60H188ZM228,96a20,20,0,0,1-16.12,19.62c.08-1.5.12-3,.12-4.52V84h16Z'),
    fight: P('M216,28H152a12,12,0,0,0-9.33,4.45L79.5,110.51l-4.66-4.65a20,20,0,0,0-28.29,0L29.86,122.55a20,20,0,0,0,0,28.29h0L45,166,23.86,187.17a20,20,0,0,0,0,28.28l16.69,16.69a20,20,0,0,0,28.28,0L90,211l15.17,15.16a20,20,0,0,0,28.29,0l16.69-16.69a20,20,0,0,0,0-28.3l-4.65-4.65,78.06-63.17A12,12,0,0,0,228,104V40A12,12,0,0,0,216,28ZM54.69,212.34l-11-11L62,183l11,11Zm64.61-6L49.65,136.7l11.05-11,69.65,69.65ZM204,98.27l-75.58,61.17L121,152l47.51-47.5a12,12,0,0,0-17-17L104,135l-7.45-7.44L157.73,52H204Z'),
    chat: P('M128,20A108,108,0,0,0,31.85,177.23L21,209.66A20,20,0,0,0,46.34,235l32.43-10.81A108,108,0,1,0,128,20Zm0,192a84,84,0,0,1-42.06-11.27,12,12,0,0,0-6-1.62,12.1,12.1,0,0,0-3.8.62l-29.79,9.93,9.93-29.79a12,12,0,0,0-1-9.81A84,84,0,1,1,128,212Z'),
    ranks: P('M108.62,103.79a12,12,0,0,1,7.59-15.17l12-4A12,12,0,0,1,144,96v40a12,12,0,0,1-24,0V112h0A12,12,0,0,1,108.62,103.79ZM252,208a12,12,0,0,1-12,12H16a12,12,0,0,1,0-24h4V104A20,20,0,0,1,40,84H76V56A20,20,0,0,1,96,36h64a20,20,0,0,1,20,20v68h36a20,20,0,0,1,20,20v52h4A12,12,0,0,1,252,208Zm-72-60v48h32V148Zm-80,48h56V60H100Zm-56,0H76V108H44Z'),
    me: P('M128,20A108,108,0,1,0,236,128,108.12,108.12,0,0,0,128,20ZM79.57,196.57a60,60,0,0,1,96.86,0,83.72,83.72,0,0,1-96.86,0ZM100,120a28,28,0,1,1,28,28A28,28,0,0,1,100,120ZM194,179.94a83.48,83.48,0,0,0-29-23.42,52,52,0,1,0-74,0,83.48,83.48,0,0,0-29,23.42,84,84,0,1,1,131.9,0Z')
  };
  var ne = false;
  try { ne = localStorage.getItem('jd_lang') === 'ne'; } catch (e) {}
  var tabs = [
    { k: 'home', href: '/', en: 'Home', np: 'होम' },
    { k: 'events', href: '/#tournaments', en: 'Events', np: 'प्रतियोगिता' },
    { k: 'fight', href: '/challenges/', en: 'Challenges', np: 'च्यालेन्ज' },
    { k: 'chat', href: '/chat/', en: 'Chat', np: 'च्याट' },
    { k: 'ranks', href: '/leaderboard.html', en: 'Ranks', np: 'र्याङ्क' },
    { k: 'me', href: '/profile/', en: 'Profile', np: 'प्रोफाइल' }
  ];
  var path = location.pathname;
  var current =
    /^\/challenges/.test(path) ? 'fight' :
    /^\/chat/.test(path) ? 'chat' :
    /^\/events/.test(path) ? 'events' :
    /^\/leaderboard/.test(path) ? 'ranks' :
    /^\/(profile|wallet)/.test(path) ? 'me' :
    (path === '/' || /^\/index\.html$/.test(path)) ? (location.hash === '#tournaments' ? 'events' : 'home') : '';

  var nav = document.createElement('nav');
  nav.className = 'tabbar';
  nav.setAttribute('aria-label', 'Main');
  nav.innerHTML = tabs.map(function (t) {
    return '<a href="' + t.href + '" data-tab="' + t.k + '"' + (t.k === current ? ' aria-current="page"' : '') + '>' +
      ICON[t.k] + (t.k === 'chat' ? '<b class="tb-count" hidden>0</b>' : '') + '<span data-en="' + t.en + '" data-np="' + t.np + '">' + (ne ? t.np : t.en) + '</span></a>';
  }).join('');
  document.body.appendChild(nav);
  // The homepage switches language in place (applyLang() in index.html calls this), so the
  // labels follow without a reload.
  window.jdTabbarLang = function (code) {
    var np = code === 'ne';
    nav.querySelectorAll('span[data-en]').forEach(function (s) { s.textContent = np ? s.getAttribute('data-np') : s.getAttribute('data-en'); });
  };
  document.body.classList.add('has-tabbar');
  // The other tabs' pages are fetched into the browser cache once this page is idle (and again on the
  // first touch of a tab), so switching tabs opens at once - like a native app - instead of waiting on
  // the network. Skipped on Data Saver / 2G.
  var pre = {};
  function prefetch(href) {
    href = href.split('#')[0] || '/';
    if (pre[href] || href === location.pathname) return;
    pre[href] = 1;
    var l = document.createElement('link'); l.rel = 'prefetch'; l.href = href; document.head.appendChild(l);
  }
  var cn = navigator.connection;
  if (!(cn && (cn.saveData || /2g/.test(cn.effectiveType || '')))) {
    var idle = window.requestIdleCallback || function (f) { setTimeout(f, 1500); };
    window.addEventListener('load', function () { idle(function () { tabs.forEach(function (t) { prefetch(t.href); }); }); });
    nav.addEventListener('touchstart', function (e) { var a = e.target.closest && e.target.closest('a'); if (a) prefetch(a.getAttribute('href')); }, { passive: true });
  }

  // Profile tab shows the signed-in player's own picture (or initial), like Instagram/Facebook. home.js calls
  // jdTabbarMe after sign-in; other pages reuse the copy it keeps (signed avatar URLs last a day).
  window.jdTabbarMe = function (me) {
    var a = nav.querySelector('[data-tab="me"]'); if (!a) return;
    var old = a.querySelector('.tb-me'); if (old) old.remove();
    var svg = a.querySelector('svg'); if (svg) svg.style.display = '';
    try { if (me) localStorage.setItem('jd_tb_me', JSON.stringify(me)); else localStorage.removeItem('jd_tb_me'); } catch (e) {}
    if (!me || !(me.avatar || me.name)) return;
    var el = document.createElement('span'); el.className = 'tb-me'; el.setAttribute('aria-hidden', 'true');
    if (me.avatar) {
      var img = new Image(); img.alt = ''; img.src = me.avatar;
      img.onerror = function () { el.textContent = (me.name || '?').charAt(0).toUpperCase(); };
      el.appendChild(img);
    } else el.textContent = me.name.charAt(0).toUpperCase();
    if (svg) svg.style.display = 'none';
    a.insertBefore(el, a.firstChild);
  };
  try { var me0 = JSON.parse(localStorage.getItem('jd_tb_me') || 'null'); if (me0 && Date.now() - (me0.at || 0) < 20 * 3600000) window.jdTabbarMe(me0); } catch (e) {}

  // On the homepage, Home/Events are in-page: keep the highlight in sync with what's on screen.
  if (current === 'home' || current === 'events') {
    var sec = document.getElementById('tournaments');
    var home = nav.querySelector('[data-tab="home"]'), ev = nav.querySelector('[data-tab="events"]');
    var set = function (onEvents) {
      if (onEvents) { ev.setAttribute('aria-current', 'page'); home.removeAttribute('aria-current'); }
      else { home.setAttribute('aria-current', 'page'); ev.removeAttribute('aria-current'); }
    };
    home.addEventListener('click', function (e) {
      if (location.pathname === '/' || /index\.html$/.test(location.pathname)) {
        e.preventDefault(); window.scrollTo({ top: 0, behavior: 'smooth' });
        if (location.hash) history.replaceState(null, '', location.pathname);
      }
    });
    if (sec && 'IntersectionObserver' in window) {
      new IntersectionObserver(function (en) {
        en.forEach(function (x) { set(x.isIntersecting); });
      }, { rootMargin: '-40% 0px -55% 0px' }).observe(sec);
    }
  }
})();

// Legal links on every page (Privacy · Terms · Refunds · Contact) and a one-time note
// that the site only stores what it needs. There is nothing to opt in or out of (no
// analytics or tracking), so this is a notice, not an accept/reject banner.
// Pages without a footer of their own get one (not the full-screen chat or the admin tools),
// and every footer gets the same site links, so no page is a dead end on a phone. The
// copyright year comes from the clock, so it never goes stale.
(function () {
  var f = document.querySelector('footer');
  if (!f && !/^\/(chat|admin)/.test(location.pathname) && !/^\/zulu-/.test(location.pathname)) {
    f = document.createElement('footer');
    f.className = 'site-foot';
    var tb = document.querySelector('.tabbar');
    document.body.insertBefore(f, tb || null);
  }
  if (f && !f.querySelector('.site-links')) {
    var links = [['/', 'Tournaments'], ['/challenges/', 'Challenges'], ['/leaderboard.html', 'Leaderboard'], ['/events/', 'Past events'], ['/about/', 'About'], ['/ban-list.html', 'Ban list']];
    var here = location.pathname.replace(/index\.html$/, '');
    var s = document.createElement('nav');
    s.className = 'site-links';
    s.setAttribute('aria-label', 'Site');
    s.innerHTML = links.filter(function (l) { return l[0] !== here && !f.querySelector('a[href="' + l[0] + '"]'); })
      .map(function (l) { return '<a href="' + l[0] + '">' + l[1] + '</a>'; }).join('');
    f.appendChild(s);
  }
  if (f && !f.querySelector('.legal-links')) {
    var d = document.createElement('nav');
    d.className = 'legal-links';
    d.setAttribute('aria-label', 'Legal');
    d.innerHTML = '<a href="/privacy/">Privacy</a><a href="/terms.html">Terms</a><a href="/terms.html#s8">Refunds</a><a href="mailto:prabinayer7@gmail.com">Contact</a>' +
      '<span>© ' + new Date().getFullYear() + ' JD Esports Arena · Run by Prabin Ayer (AyerFire), UK · Not affiliated with Garena</span>';
    f.appendChild(d);
  }
  var seen = false;
  try { seen = !!localStorage.getItem('jd_storage_note'); } catch (e) { seen = true; }
  if (seen || /^\/privacy/.test(location.pathname)) return;
  var n = document.createElement('div');
  n.className = 'storage-note';
  n.setAttribute('role', 'region');
  n.setAttribute('aria-label', 'Storage notice');
  n.innerHTML = '<p>We only store what the site needs to work, like your login and language. No tracking or ad cookies. <a href="/privacy/#cookies">Privacy policy</a></p><button type="button">OK</button>';
  n.querySelector('button').onclick = function () {
    try { localStorage.setItem('jd_storage_note', '1'); } catch (e) {}
    n.remove();
  };
  document.body.appendChild(n);
})();

// ── App required on phones ──
// Phone visitors in a normal browser see an install screen instead of the site, so every
// player has the installed app (push alerts, perks, early access). Not gated: desktop,
// the installed app itself, search bots, the legal pages, password reset, and the
// account-deletion confirmation link (it must work from the email in any browser).
(function () {
  var ua = navigator.userAgent || '';
  var ios = /iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  var android = /Android/i.test(ua);
  var mm = function (q) { return window.matchMedia && window.matchMedia(q).matches; };
  var standalone = mm('(display-mode: standalone)') || mm('(display-mode: fullscreen)') || mm('(display-mode: minimal-ui)') || navigator.standalone === true;
  var path = location.pathname;
  // JD Arena app 2.0+ is a real app (its own WebView, window.JDApp) - never gate it (its UA looks like an in-app browser)
  if (window.JDApp || /JDArenaApp\//.test(ua)) return;
  var exempt = /^\/(privacy|terms|reset-password|admin|about|download|app-auth)/.test(path) ||
    /confirm_delete=1|type=recovery/.test(location.search + location.hash) ||
    /bot|crawl|spider|slurp|lighthouse|inspectiontool|headless/i.test(ua);
  if (!(ios || android) || standalone || exempt) return;

  // installing needs the manifest + service worker on this page too
  if (!document.querySelector('link[rel="manifest"]')) {
    var l = document.createElement('link'); l.rel = 'manifest'; l.href = '/manifest.json'; document.head.appendChild(l);
  }
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js', { scope: '/', updateViaCache: 'none' }).catch(function () {});

  var inApp = /FBAN|FBAV|FB_IAB|Instagram|musical_ly|BytedanceWebview|TikTok|Snapchat|Line\/|MicroMessenger|; wv\)|GSA\//i.test(ua);
  var iosNonSafari = ios && /CriOS|FxiOS|EdgiOS|OPiOS/.test(ua);
  var samsung = /SamsungBrowser/i.test(ua);
  var url = 'https://jdesport.co.uk' + path;

  var steps;
  if (inApp) {
    steps = '<p class="ag-lead">This page is open inside another app. Open it in ' + (ios ? 'Safari' : 'Chrome') + ' to install JD Arena.</p>' +
      (android
        ? '<a class="ag-btn" href="intent://' + url.replace(/^https:\/\//, '') + '#Intent;scheme=https;package=com.android.chrome;end">Open in Chrome</a>'
        : '<ol class="ag-steps"><li>Tap <b>•••</b> or the share icon</li><li>Choose <b>Open in Safari</b> (or Open in browser)</li></ol>') +
      '<button type="button" class="ag-ghost" id="ag-copy">Copy link</button>';
  } else if (ios) {
    steps = '<ol class="ag-steps"><li>Tap the <b>Share</b> button ' + (iosNonSafari ? 'in the address bar' : 'at the bottom of Safari') + '</li>' +
      '<li>Scroll down and tap <b>Add to Home Screen</b></li><li>Tap <b>Add</b>, then open <b>JD Arena</b> from your home screen</li></ol>';
  } else {
    // Android: the real app (APK from /download/), not the old home-screen web app
    steps = '<a class="ag-btn" href="/download/?get=1">Download the JD Arena app</a>' +
      '<ol class="ag-steps"><li>Tap <b>Download</b>, then open the downloaded file</li>' +
      '<li>Tap <b>Install</b> (allow installs from ' + (samsung ? 'Samsung Internet' : 'your browser') + ' if your phone asks)</li>' +
      '<li>Open <b>JD Arena</b> and sign in</li></ol>';
  }
  // signup confirmation links open in the phone browser, even for people who signed up in the app
  if (/type=signup/.test(location.search + location.hash)) {
    steps = '<p class="ag-ok">✅ Email confirmed! Open <b>JD Arena</b> from your home screen and log in.</p><p class="ag-lead">Not installed yet?</p>' + steps;
  }
  var g = document.createElement('div');
  g.className = 'app-gate';
  g.setAttribute('role', 'dialog');
  g.setAttribute('aria-modal', 'true');
  g.setAttribute('aria-labelledby', 'ag-t');
  g.innerHTML = '<div class="ag-card"><img src="/logo.webp" alt="" width="64" height="64"><h1 id="ag-t">Get the JD Arena app</h1>' +
    '<p class="ag-lead">' + (android && !inApp ? 'On Android, JD Arena is a free app - it takes a minute to install.' : 'On phones, JD Arena runs as an app. It takes 10 seconds, it is free, and there is no app store.') + '</p>' + steps +
    '<ul class="ag-perks"><li>🔔 Room IDs and check-in alerts straight to your phone</li><li>✨ A free 7-day squad effect</li>' +
    '<li>📱 App badge on your username</li><li>⚡ Join selected events 24 hours early</li></ul>' +
    '<p class="ag-installed" id="ag-installed" hidden>✅ Already installed? Open <b>JD Arena</b> from your home screen.</p>' +
    '<p class="ag-foot"><a href="/privacy/">Privacy</a> · <a href="/terms.html">Terms</a></p></div>';
  document.documentElement.classList.add('app-gated');
  var mount = function () { document.body.appendChild(g); var b = g.querySelector('a.ag-btn,button:not([hidden])'); if (b) b.focus(); };
  if (document.body) mount(); else document.addEventListener('DOMContentLoaded', mount);

  var installed = function () { var b = g.querySelector('#ag-install'); if (b) b.hidden = true; g.querySelector('#ag-installed').hidden = false; };
  var copy = g.querySelector('#ag-copy');
  if (copy) copy.onclick = function () {
    (navigator.clipboard ? navigator.clipboard.writeText(url) : Promise.reject()).then(
      function () { copy.textContent = 'Link copied — paste it in your browser'; },
      function () { copy.textContent = url; });
  };
  var btn = g.querySelector('#ag-install'), manual = g.querySelector('#ag-manual'), deferred = null;
  window.addEventListener('beforeinstallprompt', function (e) {
    e.preventDefault(); deferred = e;
    if (btn) { btn.hidden = false; if (manual) manual.hidden = true; }
  });
  if (btn) btn.onclick = function () {
    if (!deferred) return;
    deferred.prompt();
    deferred.userChoice.then(function (c) { if (c && c.outcome === 'accepted') installed(); deferred = null; });
  };
  window.addEventListener('appinstalled', installed);
  if (navigator.getInstalledRelatedApps) navigator.getInstalledRelatedApps().then(function (apps) { if (apps && apps.length) installed(); }).catch(function () {});
})();

// Pull to refresh (phones, also inside the Android app). Pull down at the top of the page - or of a list marked
// data-ptr="<kind>" - and release: pages listening for 'jd-refresh' reload their data in place (they call
// e.preventDefault() and hand their work to e.detail.wait(promise)); any other page simply reloads.
// Chrome's own pull-to-refresh is turned off (overscroll-behavior) so the two never fire together.
(function () {
  if (!('ontouchstart' in window) || window.__jdPtr) return;
  window.__jdPtr = true;
  var st = document.createElement('style');
  st.textContent = 'html{overscroll-behavior-y:contain}' +
    '.jd-ptr{position:fixed;left:50%;top:calc(env(safe-area-inset-top,0px) + 6px);z-index:2147483000;width:40px;height:40px;margin-left:-20px;border-radius:50%;' +
    'background:#111827;border:1px solid rgba(255,255,255,.16);box-shadow:0 8px 22px rgba(0,0,0,.45);display:grid;place-items:center;pointer-events:none;opacity:0;transform:translateY(-60px)}' +
    '.jd-ptr svg{width:20px;height:20px;color:#ffc83d;transition:transform .1s}.jd-ptr.go svg{animation:jdPtr .8s linear infinite}' +
    '.jd-ptr.back{transition:transform .25s,opacity .25s}@keyframes jdPtr{to{transform:rotate(360deg)}}';
  document.head.appendChild(st);
  var el = document.createElement('div');
  el.className = 'jd-ptr'; el.setAttribute('aria-hidden', 'true');
  el.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><path d="M20 12a8 8 0 1 1-2.3-5.6"/><path d="M20 4v5h-5"/></svg>';
  var y0 = null, x0 = 0, dy = 0, busy = false, kind = null, box = null, T = 72;
  function pullable(t) {
    for (var n = t; n && n !== document.body && n.nodeType === 1; n = n.parentElement) {
      if (n.hasAttribute('data-ptr')) return n.scrollTop <= 0 ? n : null;
      var cs = getComputedStyle(n);
      if (cs.position === 'fixed') return null;   // sheets, popups, the chat overlay
      if (/(auto|scroll)/.test(cs.overflowY) && n.scrollHeight > n.clientHeight + 1) return null;
    }
    return (window.scrollY || document.documentElement.scrollTop) <= 0 ? document.documentElement : null;
  }
  function show(d) {
    if (!el.parentNode) document.body.appendChild(el);
    var p = Math.min(d, T * 1.6);
    el.classList.remove('back');
    el.style.opacity = Math.min(1, p / T);
    el.style.transform = 'translateY(' + (p * 0.75 - 50) + 'px)';
    el.firstChild.style.transform = 'rotate(' + (p * 4) + 'deg)';
  }
  function hide() { el.classList.add('back'); el.classList.remove('go'); el.style.opacity = 0; el.style.transform = 'translateY(-60px)'; }
  document.addEventListener('touchstart', function (e) {
    if (busy || e.touches.length !== 1) { y0 = null; return; }
    box = pullable(e.target);
    if (!box) { y0 = null; return; }
    kind = box === document.documentElement ? 'page' : box.getAttribute('data-ptr');
    y0 = e.touches[0].clientY; x0 = e.touches[0].clientX; dy = 0;
  }, { passive: true });
  document.addEventListener('touchmove', function (e) {
    if (y0 === null) return;
    var t = e.touches[0];
    dy = t.clientY - y0;
    if (dy < 0 || Math.abs(t.clientX - x0) > dy || (box.scrollTop || (kind === 'page' ? window.scrollY : 0)) > 0) { if (dy < 0) { y0 = null; hide(); } return; }
    if (dy > 12) show(dy - 12);
  }, { passive: true });
  document.addEventListener('touchend', function () {
    if (y0 === null) return;
    y0 = null;
    if (dy - 12 < T) { hide(); return; }
    busy = true; show(T); el.classList.add('go');
    try { if (navigator.vibrate) navigator.vibrate(12); } catch (x) {}
    var work = null;
    var ev = new CustomEvent('jd-refresh', { cancelable: true, detail: { kind: kind, wait: function (p) { work = p; } } });
    window.dispatchEvent(ev);
    if (!ev.defaultPrevented) { location.reload(); return; }
    var t0 = Date.now();
    Promise.race([Promise.resolve(work), new Promise(function (r) { setTimeout(r, 8000); })]).then(function () {
      setTimeout(function () { hide(); busy = false; }, Math.max(0, 450 - (Date.now() - t0)));
    });
  }, { passive: true });
  document.addEventListener('touchcancel', function () { y0 = null; hide(); }, { passive: true });
})();
