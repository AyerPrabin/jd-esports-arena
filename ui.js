// JD Arena shared UI: injects the phone bottom tab bar (styled in /ui.css, shown only
// at <=640px) on every player-facing page, and marks the current tab. Icons are
// Phosphor "bold" (MIT, @phosphor-icons/core), inlined so there's no icon-font download.
(function () {
  if (document.querySelector('.tabbar')) return;
  var P = function (d) { return '<svg viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="' + d + '"/></svg>'; };
  var ICON = {
    home: P('M222.14,105.85l-80-80a20,20,0,0,0-28.28,0l-80,80A19.86,19.86,0,0,0,28,120v96a12,12,0,0,0,12,12H216a12,12,0,0,0,12-12V120A19.86,19.86,0,0,0,222.14,105.85ZM204,204H52V121.65l76-76,76,76Z'),
    events: P('M232,60H212V48a12,12,0,0,0-12-12H56A12,12,0,0,0,44,48V60H24A20,20,0,0,0,4,80V96a44.05,44.05,0,0,0,44,44h.77A84.18,84.18,0,0,0,116,195.15V212H96a12,12,0,0,0,0,24h64a12,12,0,0,0,0-24H140V195.11c30.94-4.51,56.53-26.2,67-55.11h1a44.05,44.05,0,0,0,44-44V80A20,20,0,0,0,232,60ZM28,96V84H44v28c0,1.21,0,2.41.09,3.61A20,20,0,0,1,28,96Zm160,15.1c0,33.33-26.71,60.65-59.54,60.9A60,60,0,0,1,68,112V60H188ZM228,96a20,20,0,0,1-16.12,19.62c.08-1.5.12-3,.12-4.52V84h16Z'),
    fight: P('M216,28H152a12,12,0,0,0-9.33,4.45L79.5,110.51l-4.66-4.65a20,20,0,0,0-28.29,0L29.86,122.55a20,20,0,0,0,0,28.29h0L45,166,23.86,187.17a20,20,0,0,0,0,28.28l16.69,16.69a20,20,0,0,0,28.28,0L90,211l15.17,15.16a20,20,0,0,0,28.29,0l16.69-16.69a20,20,0,0,0,0-28.3l-4.65-4.65,78.06-63.17A12,12,0,0,0,228,104V40A12,12,0,0,0,216,28ZM54.69,212.34l-11-11L62,183l11,11Zm64.61-6L49.65,136.7l11.05-11,69.65,69.65ZM204,98.27l-75.58,61.17L121,152l47.51-47.5a12,12,0,0,0-17-17L104,135l-7.45-7.44L157.73,52H204Z'),
    ranks: P('M108.62,103.79a12,12,0,0,1,7.59-15.17l12-4A12,12,0,0,1,144,96v40a12,12,0,0,1-24,0V112h0A12,12,0,0,1,108.62,103.79ZM252,208a12,12,0,0,1-12,12H16a12,12,0,0,1,0-24h4V104A20,20,0,0,1,40,84H76V56A20,20,0,0,1,96,36h64a20,20,0,0,1,20,20v68h36a20,20,0,0,1,20,20v52h4A12,12,0,0,1,252,208Zm-72-60v48h32V148Zm-80,48h56V60H100Zm-56,0H76V108H44Z'),
    me: P('M128,20A108,108,0,1,0,236,128,108.12,108.12,0,0,0,128,20ZM79.57,196.57a60,60,0,0,1,96.86,0,83.72,83.72,0,0,1-96.86,0ZM100,120a28,28,0,1,1,28,28A28,28,0,0,1,100,120ZM194,179.94a83.48,83.48,0,0,0-29-23.42,52,52,0,1,0-74,0,83.48,83.48,0,0,0-29,23.42,84,84,0,1,1,131.9,0Z')
  };
  var ne = false;
  try { ne = localStorage.getItem('jd_lang') === 'ne'; } catch (e) {}
  var tabs = [
    { k: 'home', href: '/', en: 'Home', np: 'होम' },
    { k: 'events', href: '/#tournaments', en: 'Events', np: 'प्रतियोगिता' },
    { k: 'fight', href: '/challenges/', en: 'Challenges', np: 'च्यालेन्ज' },
    { k: 'ranks', href: '/leaderboard.html', en: 'Ranks', np: 'र्याङ्क' },
    { k: 'me', href: '/profile/', en: 'Profile', np: 'प्रोफाइल' }
  ];
  var path = location.pathname;
  var current =
    /^\/challenges/.test(path) ? 'fight' :
    /^\/leaderboard/.test(path) ? 'ranks' :
    /^\/(profile|wallet)/.test(path) ? 'me' :
    (path === '/' || /^\/index\.html$/.test(path)) ? (location.hash === '#tournaments' ? 'events' : 'home') : '';

  var nav = document.createElement('nav');
  nav.className = 'tabbar';
  nav.setAttribute('aria-label', 'Main');
  nav.innerHTML = tabs.map(function (t) {
    return '<a href="' + t.href + '" data-tab="' + t.k + '"' + (t.k === current ? ' aria-current="page"' : '') + '>' +
      ICON[t.k] + '<span data-en="' + t.en + '" data-np="' + t.np + '">' + (ne ? t.np : t.en) + '</span></a>';
  }).join('');
  document.body.appendChild(nav);
  // The homepage switches language in place (applyLang() in index.html calls this), so the
  // labels follow without a reload.
  window.jdTabbarLang = function (code) {
    var np = code === 'ne';
    nav.querySelectorAll('span[data-en]').forEach(function (s) { s.textContent = np ? s.getAttribute('data-np') : s.getAttribute('data-en'); });
  };
  document.body.classList.add('has-tabbar');

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
