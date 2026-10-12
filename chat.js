// JD Arena Messages: friends + 1:1 direct messages, Messenger style. Loaded (deferred) on
// every page that creates a Supabase client named `sb`; styles in /chat.css. Everything
// goes through the SECURITY DEFINER RPCs in schema.sql ("friends + direct messages"):
// send_friend_request / respond_friend_request / remove_friend / block_player /
// unblock_player / chat_overview / chat_player / dm_thread / send_dm / dm_mark_read / dm_poll.
// No realtime: dm_poll every 5s on a visible tab (unread badge, new-message banner +
// sound), and the open conversation refreshes every 2.5s. New DMs also arrive as Web
// Push (dm-push Edge Function) that opens /?dm=<player tag>.
(function () {
  if (window.jdChat) return;
  var SB = (typeof sb !== 'undefined' && sb) ? sb : null;
  if (!SB || !document.body) return;

  var css = document.createElement('link');
  css.rel = 'stylesheet'; css.href = '/chat.css?v=2';
  document.head.appendChild(css);

  var NE = false;
  try { NE = localStorage.getItem('jd_lang') === 'ne'; } catch (e) {}
  var L = {
    messages: ['Messages', 'सन्देश'], chats: ['Chats', 'च्याट'], requests: ['Requests', 'अनुरोध'],
    add: ['Add', 'थप्नुहोस्'], addPh: ['Add a friend: username or JD tag', 'साथी थप्नुहोस्: युजरनेम वा JD ट्याग'],
    typePh: ['Message…', 'सन्देश लेख्नुहोस्…'], you: ['You', 'तपाईं'], now: ['Active now', 'अहिले सक्रिय'],
    accept: ['Accept', 'स्वीकार'], decline: ['Decline', 'अस्वीकार'], cancel: ['Cancel', 'रद्द']
  };
  var T = function (k) { return L[k][NE ? 1 : 0]; };

  var ICON = {
    chat: '<svg viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="M128,20A108,108,0,0,0,31.85,177.23L21,209.66A20,20,0,0,0,46.34,235l32.43-10.81A108,108,0,1,0,128,20Zm0,192a84,84,0,0,1-42.06-11.27,12,12,0,0,0-6-1.62,12.1,12.1,0,0,0-3.8.62l-29.79,9.93,9.93-29.79a12,12,0,0,0-1-9.81A84,84,0,1,1,128,212Zm-44-84a16,16,0,1,1-16-16A16,16,0,0,1,84,128Zm60,0a16,16,0,1,1-16-16A16,16,0,0,1,144,128Zm60,0a16,16,0,1,1-16-16A16,16,0,0,1,204,128Z" transform="translate(4 0)"/></svg>',
    x: '<svg viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="M208.49,191.51a12,12,0,0,1-17,17L128,145,64.49,208.49a12,12,0,0,1-17-17L111,128,47.51,64.49a12,12,0,0,1,17-17L128,111l63.51-63.52a12,12,0,0,1,17,17L145,128Z"/></svg>',
    back: '<svg viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="M168.49,199.51a12,12,0,0,1-17,17l-80-80a12,12,0,0,1,0-17l80-80a12,12,0,0,1,17,17L97,128Z"/></svg>',
    dots: '<svg viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="M144,128a16,16,0,1,1-16-16A16,16,0,0,1,144,128ZM60,112a16,16,0,1,0,16,16A16,16,0,0,0,60,112Zm136,0a16,16,0,1,0,16,16A16,16,0,0,0,196,112Z"/></svg>',
    send: '<svg viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="M231.4,44.34s0,.1,0,.15l-58.2,191.94a15.88,15.88,0,0,1-14,11.51q-.69.06-1.38.06a15.86,15.86,0,0,1-14.42-9.15L107,164.15a4,4,0,0,1,.77-4.58l57.92-57.92a8,8,0,0,0-11.31-11.31L96.43,148.26a4,4,0,0,1-4.58.77L17.08,112.64a16,16,0,0,1,2.49-29.8l191.94-58.2.15,0A16,16,0,0,1,231.4,44.34Z"/></svg>',
    users: '<svg viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="M125.18,156.94a64,64,0,1,0-82.36,0,100.23,100.23,0,0,0-39.49,32,12,12,0,0,0,19.35,14.2,76,76,0,0,1,122.64,0,12,12,0,0,0,19.36-14.2A100.33,100.33,0,0,0,125.18,156.94ZM44,108a40,40,0,1,1,40,40A40,40,0,0,1,44,108Zm206.1,97.67a12,12,0,0,1-16.78-2.57A76.31,76.31,0,0,0,172,172a12,12,0,0,1,0-24,40,40,0,1,0-14.85-77.16,12,12,0,1,1-8.92-22.28,64,64,0,0,1,65,108.38,100.23,100.23,0,0,1,39.49,32A12,12,0,0,1,250.1,205.67Z"/></svg>'
  };

  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var $ = function (id) { return document.getElementById(id); };
  var phone = function () { return window.matchMedia && window.matchMedia('(max-width:640px)').matches; };
  var reduced = function () { return window.matchMedia && window.matchMedia('(prefers-reduced-motion:reduce)').matches; };

  function short(iso) {
    if (!iso) return '';
    var s = (Date.now() - new Date(iso).getTime()) / 1000;
    if (s < 60) return 'now';
    if (s < 3600) return Math.floor(s / 60) + 'm';
    if (s < 86400) return Math.floor(s / 3600) + 'h';
    if (s < 604800) return Math.floor(s / 86400) + 'd';
    return new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
  }
  function status(p) {
    if (!p) return '';
    if (p.online) return T('now');
    if (p.seen) { var a = short(p.seen); return a === 'now' ? T('now') : 'Active ' + a + ' ago'; }
    return p.tag || '';
  }
  function stamp(iso) {
    var d = new Date(iso), now = new Date();
    var t = d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' });
    if (d.toDateString() === now.toDateString()) return t;
    var y = new Date(now); y.setDate(now.getDate() - 1);
    if (d.toDateString() === y.toDateString()) return 'Yesterday ' + t;
    return d.toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' }) + ', ' + t;
  }
  function avatar(p, size) {
    p = p || {};
    var name = p.username || p.tag || '?';
    var h = 0; for (var i = 0; i < String(p.id || name).length; i++) h = (h * 31 + String(p.id || name).charCodeAt(i)) % 360;
    var bg = 'linear-gradient(145deg,hsl(' + h + ' 70% 52%),hsl(' + ((h + 40) % 360) + ' 75% 38%))';
    var logo = p.logo && /^(https:|data:image\/)/.test(p.logo) ? '<img src="' + esc(p.logo) + '" alt="" loading="lazy">' : esc(name.charAt(0));
    return '<span class="dm-av' + (size ? ' ' + size : '') + (p.online ? ' on' : '') + '" style="background:' + bg + '" aria-hidden="true">' + logo + '</span>';
  }
  var nameOf = function (p) { return p ? (p.username ? '@' + p.username : p.tag) : ''; };
  var emojiOnly = function (s) { return s.length <= 12 && /^(\p{Extended_Pictographic}|\p{Emoji_Component}|‍|️|\s)+$/u.test(s) && !/^[\d#*\s]+$/.test(s); };

  // ── sound + vibration for a new message (soft rising "pop", Web Audio; unlocked on first tap) ──
  var actx = null;
  document.addEventListener('pointerdown', function () {
    if (actx) return;
    try { actx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) {}
  }, { once: true, capture: true });
  function pop() {
    if (!actx) return;
    try {
      if (actx.state === 'suspended') actx.resume();
      var t = actx.currentTime;
      [[880, 0], [1318.5, 0.09]].forEach(function (n) {
        var o = actx.createOscillator(), g = actx.createGain();
        o.type = 'sine'; o.frequency.setValueAtTime(n[0], t + n[1]);
        g.gain.setValueAtTime(0, t + n[1]);
        g.gain.linearRampToValueAtTime(0.16, t + n[1] + 0.012);
        g.gain.exponentialRampToValueAtTime(0.0001, t + n[1] + 0.22);
        o.connect(g).connect(actx.destination); o.start(t + n[1]); o.stop(t + n[1] + 0.25);
      });
    } catch (e) {}
  }
  function buzz() { try { if (navigator.vibrate) navigator.vibrate([90, 60, 90]); } catch (e) {} }

  // ── markup ──
  var fab = document.createElement('button');
  fab.type = 'button'; fab.className = 'dm-fab'; fab.hidden = true;
  fab.setAttribute('aria-label', T('messages'));
  fab.innerHTML = ICON.chat + '<span class="dm-count" hidden>0</span>';
  document.body.appendChild(fab);
  if ($('fab')) document.body.classList.add('has-zulu-fab'); // homepage "Ask ZULU" pill

  var panel = document.createElement('section');
  panel.className = 'dm-panel'; panel.setAttribute('role', 'dialog'); panel.setAttribute('aria-label', T('messages'));
  panel.innerHTML =
    '<div class="dm-view on" id="dm-home">' +
      '<div class="dm-head"><h2>' + T('messages') + '</h2><button type="button" class="dm-ib" id="dm-close" aria-label="Close">' + ICON.x + '</button></div>' +
      '<form class="dm-add" id="dm-add" autocomplete="off"><input id="dm-add-in" maxlength="40" placeholder="' + esc(T('addPh')) + '" aria-label="' + esc(T('addPh')) + '" enterkeyhint="send"><button type="submit">' + T('add') + '</button></form>' +
      '<div class="dm-note" id="dm-note" role="status"></div>' +
      '<div class="dm-mytag" id="dm-mytag" hidden></div>' +
      '<div class="dm-tabs" role="tablist"><button type="button" role="tab" data-t="chats" aria-selected="true">' + T('chats') + '<b id="dm-tb-chats" hidden></b></button><button type="button" role="tab" data-t="requests" aria-selected="false">' + T('requests') + '<b id="dm-tb-req" hidden></b></button></div>' +
      '<div class="dm-list" id="dm-list"></div>' +
    '</div>' +
    '<div class="dm-view" id="dm-thread">' +
      '<div class="dm-thead"><button type="button" class="dm-ib" id="dm-back" aria-label="Back">' + ICON.back + '</button><span id="dm-th-av"></span><div class="dm-who"><b id="dm-th-name"></b><small id="dm-th-st"></small></div><button type="button" class="dm-ib" id="dm-menu" aria-label="Options">' + ICON.dots + '</button><button type="button" class="dm-ib" id="dm-close2" aria-label="Close">' + ICON.x + '</button></div>' +
      '<div class="dm-msgs" id="dm-msgs" aria-live="polite"></div>' +
      '<div id="dm-foot"></div>' +
      '<div class="dm-sheet" id="dm-sheet"><div class="dm-sheet-in" id="dm-sheet-in"></div></div>' +
    '</div>';
  document.body.appendChild(panel);

  var banner = document.createElement('button');
  banner.type = 'button'; banner.className = 'dm-banner'; banner.setAttribute('aria-live', 'polite');
  document.body.appendChild(banner);

  // homepage drawer: a "💬 Messages" row next to Notifications
  var navRow = null;
  var notifRow = $('nav-notif');
  if (notifRow) {
    navRow = document.createElement('button');
    navRow.type = 'button'; navRow.className = 'lang-btn nav-m'; navRow.id = 'nav-dm'; navRow.hidden = true;
    navRow.innerHTML = '<span>💬 ' + T('messages') + '</span><b id="nav-dm-count" hidden>0</b>';
    navRow.onclick = function () { open(); };
    notifRow.insertAdjacentElement('afterend', navRow);
  }

  // ── state ──
  var me = null, isOpen = false, tab = 'chats', ov = null, peer = null;
  var msgs = [], hasOlder = false, threadTimer = null, pollTimer = null, polled = false, lastNotified = 0;
  var badge = { unread: 0, requests: 0 }, sending = false, tmp = 0, bannerTimer = null, pendingDeepLink = null;

  function setBadges() {
    var n = badge.unread + badge.requests;
    var c = fab.querySelector('.dm-count');
    c.textContent = n > 99 ? '99+' : n; c.hidden = !n;
    fab.classList.toggle('has-unread', n > 0);
    fab.setAttribute('aria-label', T('messages') + (n ? ', ' + n + ' new' : ''));
    var nc = $('nav-dm-count'); if (nc) { nc.textContent = c.textContent; nc.hidden = !n; }
    var base = document.title.replace(/^\(\d+\+?\) /, '');
    document.title = (badge.unread ? '(' + (badge.unread > 99 ? '99+' : badge.unread) + ') ' : '') + base;
    var tc = $('dm-tb-chats'), tr = $('dm-tb-req');
    tc.textContent = badge.unread; tc.hidden = !badge.unread;
    tr.textContent = badge.requests; tr.hidden = !badge.requests;
  }

  function setUser(u) {
    var id = u ? u.id : null;
    if (id === me) return;
    me = id; polled = false; lastNotified = 0; ov = null; peer = null; msgs = [];
    badge = { unread: 0, requests: 0 }; setBadges();
    fab.hidden = !me; if (navRow) navRow.hidden = !me;
    document.body.classList.toggle('has-dm', !!me);
    if (!me) { close(true); return; }
    poll(); loadMyTag();
    if (pendingDeepLink) { var w = pendingDeepLink; pendingDeepLink = null; openWith(w); }
  }

  // your own JD tag, so friends can add you
  async function loadMyTag() {
    var id = me, r = await SB.from('players').select('username, player_tag').eq('id', id).maybeSingle();
    var box = $('dm-mytag'); if (!r.data || id !== me) return;
    box.innerHTML = '<span>Your tag <b>' + esc(r.data.player_tag) + '</b>' + (r.data.username ? ' · @' + esc(r.data.username) : '') + '</span><button type="button">Copy</button>';
    box.hidden = false;
    box.querySelector('button').onclick = function () {
      var b = this, t = 'Add me on JD Arena: ' + (r.data.username ? '@' + r.data.username + ' · ' : '') + r.data.player_tag + ' https://jdesport.co.uk/';
      (navigator.clipboard ? navigator.clipboard.writeText(t) : Promise.reject()).then(function () { b.textContent = 'Copied ✓'; setTimeout(function () { b.textContent = 'Copy'; }, 1800); }, function () { b.textContent = r.data.player_tag; });
    };
  }

  // ── polling ──
  async function poll() {
    if (!me || document.hidden) return;
    var r = await SB.rpc('dm_poll');
    if (r.error || !r.data) return;
    var d = r.data, changed = d.unread !== badge.unread || d.requests !== badge.requests;
    var grewReq = polled && d.requests > badge.requests;
    badge = { unread: d.unread || 0, requests: d.requests || 0 };
    setBadges();
    var last = d.last;
    if (last && last.id > lastNotified) {
      var watching = isOpen && peer && peer.id === last.from && $('dm-thread').classList.contains('on');
      if (polled && !watching) notify(last);
      lastNotified = last.id;
    }
    if (grewReq) { pop(); bump(); }
    polled = true;
    if (isOpen && !peer && changed) loadOverview();
  }
  function bump() { if (reduced()) return; fab.classList.remove('bump'); void fab.offsetWidth; fab.classList.add('bump'); }
  function notify(m) {
    pop(); buzz(); bump();
    var who = { id: m.from, username: (m.name || '').replace(/^@/, '') };
    banner.innerHTML = avatar(who, 'sm') + '<span class="dm-bt"><b>' + esc(m.name || 'New message') + '</b><small>' + esc(m.body) + '</small></span><span class="dm-bk">Reply</span>';
    banner.onclick = function () { banner.classList.remove('show'); openWith(m.from); };
    banner.classList.add('show');
    clearTimeout(bannerTimer);
    bannerTimer = setTimeout(function () { banner.classList.remove('show'); }, 5500);
  }
  pollTimer = setInterval(poll, 5000);
  document.addEventListener('visibilitychange', function () { if (!document.hidden) { poll(); if (peer) refreshThread(); } });

  // ── panel ──
  function open() {
    if (!me) return;
    if (!isOpen) {
      isOpen = true; panel.classList.add('open');
      if (phone()) { document.body.classList.add('dm-locked'); try { history.pushState({ jdDm: 1 }, ''); } catch (e) {} }
    }
    showHome();
  }
  function close(silent) {
    if (!isOpen) return;
    isOpen = false; peer = null; stopThread();
    panel.classList.remove('open'); document.body.classList.remove('dm-locked');
    closeSheet();
    if (!silent && history.state && history.state.jdDm) { try { history.back(); } catch (e) {} }
    try { fab.focus({ preventScroll: true }); } catch (e) {}
  }
  window.addEventListener('popstate', function () { if (isOpen) close(true); });
  fab.onclick = function () { isOpen ? close() : open(); };
  $('dm-close').onclick = function () { close(); };
  $('dm-close2').onclick = function () { close(); };
  $('dm-back').onclick = showHome;
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape' || !isOpen) return;
    if ($('dm-sheet').classList.contains('open')) closeSheet();
    else if (peer) showHome(); else close();
  });
  panel.querySelectorAll('.dm-tabs button').forEach(function (b) {
    b.onclick = function () { tab = b.dataset.t; renderOverview(); };
  });

  function showHome() {
    peer = null; stopThread(); closeSheet();
    $('dm-thread').classList.remove('on'); $('dm-home').classList.add('on');
    renderOverview(); loadOverview();
  }

  async function loadOverview() {
    var r = await SB.rpc('chat_overview');
    if (r.error) { if (!ov) $('dm-list').innerHTML = '<div class="dm-empty">Couldn\'t load your chats. Check your connection.</div>'; return; }
    ov = r.data || { friends: [], incoming: [], outgoing: [], blocked: [] };
    if (!peer) renderOverview();
  }

  function renderOverview() {
    panel.querySelectorAll('.dm-tabs button').forEach(function (b) { b.setAttribute('aria-selected', b.dataset.t === tab ? 'true' : 'false'); });
    var list = $('dm-list');
    if (!ov) { list.innerHTML = '<div class="dm-empty">Loading…</div>'; return; }
    var h = '';
    if (tab === 'chats') {
      var online = ov.friends.filter(function (f) { return f.online; });
      if (!ov.friends.length) {
        h = '<div class="dm-empty"><span class="dm-empty-ic">' + ICON.users + '</span><b>No friends yet</b>Add your squadmates by their username or JD tag (like JD-7F3K2) above. Once they accept, you can chat here.</div>';
      } else {
        if (online.length > 1) h += '<div class="dm-sec">Active now · ' + online.length + '</div>';
        h += ov.friends.map(function (f) {
          var prev = f.last_body ? (f.last_mine ? T('you') + ': ' : '') + f.last_body : 'Say hi 👋';
          var right = f.unread ? '<span class="dm-dot">' + (f.unread > 9 ? '9+' : f.unread) + '</span>' : '';
          return '<button type="button" class="dm-row' + (f.unread ? ' unread' : '') + '" data-open="' + esc(f.id) + '">' + avatar(f) +
            '<span class="dm-mid"><span class="dm-name">' + esc(nameOf(f)) + (f.app ? ' <span class="dm-badge" title="Uses the app">📱</span>' : '') + '</span>' +
            '<span class="dm-prev"><span>' + esc(prev) + '</span>' + (f.last_at ? '<span>· ' + short(f.last_at) + '</span>' : '') + '</span></span>' + right + '</button>';
        }).join('');
      }
    } else {
      if (ov.incoming.length) h += '<div class="dm-sec">Friend requests</div>' + ov.incoming.map(function (p) {
        return '<div class="dm-row">' + avatar(p) + '<span class="dm-mid"><span class="dm-name">' + esc(nameOf(p)) + '</span><span class="dm-prev"><span>' + esc(p.tag || '') + ' · ' + short(p.at) + '</span></span></span>' +
          '<span class="dm-acts"><button type="button" class="dm-btn" data-accept="' + esc(p.id) + '">' + T('accept') + '</button><button type="button" class="dm-btn ghost" data-decline="' + esc(p.id) + '" aria-label="' + T('decline') + ' ' + esc(nameOf(p)) + '">✕</button></span></div>';
      }).join('');
      if (ov.outgoing.length) h += '<div class="dm-sec">Sent · waiting</div>' + ov.outgoing.map(function (p) {
        return '<div class="dm-row">' + avatar(p) + '<span class="dm-mid"><span class="dm-name">' + esc(nameOf(p)) + '</span><span class="dm-prev"><span>Request sent ' + short(p.at) + '</span></span></span>' +
          '<span class="dm-acts"><button type="button" class="dm-btn ghost" data-remove="' + esc(p.id) + '">' + T('cancel') + '</button></span></div>';
      }).join('');
      if (ov.blocked.length) h += '<div class="dm-sec">Blocked</div>' + ov.blocked.map(function (p) {
        return '<div class="dm-row">' + avatar(p) + '<span class="dm-mid"><span class="dm-name">' + esc(nameOf(p)) + '</span></span>' +
          '<span class="dm-acts"><button type="button" class="dm-btn ghost" data-unblock="' + esc(p.id) + '">Unblock</button></span></div>';
      }).join('');
      if (!h) h = '<div class="dm-empty"><span class="dm-empty-ic">' + ICON.users + '</span><b>No requests</b>When someone adds you, it shows up here and in your notifications.</div>';
    }
    list.innerHTML = h;
  }

  $('dm-list').addEventListener('click', async function (e) {
    var b = e.target.closest('button'); if (!b) return;
    var id;
    if ((id = b.dataset.open)) { var f = ov.friends.find(function (x) { return x.id === id; }); if (f) openThread(Object.assign({ friend: true }, f)); return; }
    b.disabled = true;
    var r;
    if ((id = b.dataset.accept)) r = await SB.rpc('respond_friend_request', { p_from: id, p_accept: true });
    else if ((id = b.dataset.decline)) r = await SB.rpc('respond_friend_request', { p_from: id, p_accept: false });
    else if ((id = b.dataset.remove)) r = await SB.rpc('remove_friend', { p_who: id });
    else if ((id = b.dataset.unblock)) r = await SB.rpc('unblock_player', { p_who: id });
    if (r && r.error) { note(r.error.message, 'err'); b.disabled = false; return; }
    if (b.dataset.accept) { note('You\'re friends now — say hi! 👋', 'ok'); tab = 'chats'; }
    await loadOverview(); poll();
  });

  function note(t, cls) { var n = $('dm-note'); n.className = 'dm-note' + (cls ? ' ' + cls : ''); n.textContent = t || ''; }
  $('dm-add').onsubmit = async function (e) {
    e.preventDefault();
    var inp = $('dm-add-in'), v = inp.value.trim(), btn = this.querySelector('button');
    if (!v) { inp.focus(); return; }
    btn.disabled = true; note('');
    var r = await SB.rpc('send_friend_request', { p_who: v });
    btn.disabled = false;
    if (r.error) { note(r.error.message, 'err'); return; }
    inp.value = '';
    var who = v.replace(/^@/, '');
    note({ sent: 'Request sent to ' + who + '. You can chat once they accept.', pending: 'Already sent — waiting for ' + who + ' to accept.',
      already: 'You and ' + who + ' are already friends.', accepted: 'They had already added you — you\'re friends now! 🎉' }[r.data] || 'Done.', 'ok');
    if (r.data === 'sent' || r.data === 'pending') tab = 'requests';
    else tab = 'chats';
    loadOverview(); poll();
  };

  // ── conversation ──
  function stopThread() { clearInterval(threadTimer); threadTimer = null; }
  async function openWith(who) {
    if (!me) { pendingDeepLink = who; return; }
    var card = null;
    if (ov) card = ov.friends.find(function (f) { return f.id === who || f.tag === who || ('@' + f.username).toLowerCase() === String(who).toLowerCase(); });
    if (card) card = Object.assign({ friend: true }, card);
    else {
      var r = await SB.rpc('chat_player', { p_who: String(who) });
      if (r.error || !r.data) { open(); note('That player isn\'t available to chat.', 'err'); return; }
      card = r.data;
      if (!card.friend) { open(); $('dm-add-in').value = card.username || card.tag; note('Add ' + nameOf(card) + ' as a friend to start chatting.', ''); return; }
    }
    if (!isOpen) open();
    openThread(card);
  }

  function openThread(p) {
    peer = p; msgs = []; hasOlder = false;
    closeSheet();
    $('dm-home').classList.remove('on'); $('dm-thread').classList.add('on');
    renderPeer();
    $('dm-msgs').innerHTML = '<div class="dm-empty">Loading…</div>';
    $('dm-foot').innerHTML = p.friend === false
      ? '<div class="dm-locked">You\'re no longer friends, so you can\'t send messages.</div>'
      : '<form class="dm-compose" id="dm-form"><textarea id="dm-in" rows="1" maxlength="500" placeholder="' + esc(T('typePh')) + '" aria-label="' + esc(T('typePh')) + '" enterkeyhint="send"></textarea>' +
        '<button type="button" class="dm-quick" id="dm-like" aria-label="Send a thumbs up">👍</button><button type="submit" class="dm-send" id="dm-send" aria-label="Send" hidden>' + ICON.send + '</button></form>';
    var inp = $('dm-in');
    if (inp) {
      var sync = function () {
        inp.style.height = 'auto'; inp.style.height = Math.min(inp.scrollHeight, 120) + 'px';
        var has = !!inp.value.trim(); $('dm-send').hidden = !has; $('dm-like').hidden = has;
      };
      inp.addEventListener('input', sync);
      inp.addEventListener('keydown', function (e) { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && !phone()) { e.preventDefault(); send(); } });
      $('dm-form').onsubmit = function (e) { e.preventDefault(); send(); };
      $('dm-like').onclick = function () { send('👍'); };
      if (!phone()) setTimeout(function () { try { inp.focus(); } catch (e) {} }, 60);
    }
    refreshThread(true);
    stopThread();
    threadTimer = setInterval(function () { if (!document.hidden) refreshThread(); }, 2500);
  }
  function renderPeer() {
    $('dm-th-av').innerHTML = avatar(peer, 'sm');
    $('dm-th-name').textContent = nameOf(peer);
    var st = $('dm-th-st'); st.textContent = status(peer); st.className = peer.online ? 'on' : '';
  }

  var sig = '';
  async function refreshThread(first) {
    var p = peer; if (!p) return;
    if (sending && !first) return;
    var r = await SB.rpc('dm_thread', { p_with: p.id });
    if (peer !== p || r.error || (sending && !first)) return;
    var rows = (r.data || []).slice().reverse();
    if (first) {
      hasOlder = rows.length >= 60;
      msgs = rows;
    } else {
      var byId = {}; rows.forEach(function (m) { byId[m.id] = m; });
      var newest = 0;
      msgs.forEach(function (m) { if (typeof m.id === 'number') { if (byId[m.id]) m.read_at = byId[m.id].read_at; newest = Math.max(newest, m.id); } });
      var fresh = rows.filter(function (m) { return m.id > newest && !msgs.some(function (x) { return x.id === m.id; }); });
      fresh.forEach(function (m) { m.fresh = true; });
      // keep unsent/failed bubbles at the bottom
      var local = msgs.filter(function (m) { return typeof m.id !== 'number'; });
      msgs = msgs.filter(function (m) { return typeof m.id === 'number'; }).concat(fresh, local);
    }
    var s = msgs.map(function (m) { return m.id + (m.read_at ? 'r' : '') + (m.failed ? 'f' : ''); }).join(',');
    if (first || s !== sig) { sig = s; renderMsgs(first); }
    if (rows.some(function (m) { return !m.mine && !m.read_at; })) {
      await SB.rpc('dm_mark_read', { p_with: p.id });
      poll();
    }
    // keep the "Active now" line fresh every so often
    if (first || Math.random() < 0.08) {
      var c = await SB.rpc('chat_player', { p_who: p.tag });
      if (c.data && peer === p) { peer = Object.assign(p, { online: c.data.online, seen: c.data.seen, logo: c.data.logo }); renderPeer(); }
    }
  }

  function renderMsgs(jump) {
    var box = $('dm-msgs');
    var nearBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 80;
    var h = '';
    if (hasOlder) h += '<button type="button" class="dm-more" id="dm-older">Load earlier messages</button>';
    else h += '<div class="dm-hello">' + avatar(peer) + '<b>' + esc(nameOf(peer)) + '</b>' + esc(peer.tag || '') + (peer.squad ? ' · ' + esc(peer.squad) : '') + '<br>You\'re friends on JD Arena</div>';
    var lastMine = -1;
    msgs.forEach(function (m, i) { if (m.mine) lastMine = i; });
    for (var i = 0; i < msgs.length; i++) {
      var m = msgs[i], prev = msgs[i - 1], next = msgs[i + 1];
      var t = new Date(m.created_at).getTime();
      var gapBefore = !prev || t - new Date(prev.created_at).getTime() > 15 * 60000;
      if (gapBefore) h += '<div class="dm-time">' + esc(stamp(m.created_at)) + '</div>';
      var head = gapBefore || prev.mine !== m.mine || t - new Date(prev.created_at).getTime() > 5 * 60000;
      var tail = !next || next.mine !== m.mine || new Date(next.created_at).getTime() - t > 5 * 60000;
      var cls = 'dm-line ' + (m.mine ? 'me' : 'them') + (head ? ' head' : '') + (tail ? ' tail' : '') + (emojiOnly(m.body) ? ' emoji' : '') +
        (m.pending ? ' pending' : '') + (m.failed ? ' failed' : '') + (m.fresh && !reduced() ? ' new' : '');
      h += '<div class="' + cls + '" title="' + esc(stamp(m.created_at)) + '">' + (m.mine ? '' : avatar(peer, 'xs')) + '<div class="dm-b">' + esc(m.body) + '</div></div>';
      if (m.failed) h += '<div class="dm-err">' + esc(m.failed) + ' · <button type="button" class="dm-more" style="margin:0;padding:2px 8px" data-retry="' + esc(m.id) + '">Retry</button></div>';
      else if (i === lastMine && i === msgs.length - 1) h += '<div class="dm-seen">' + (m.pending ? 'Sending…' : m.read_at ? 'Seen ' + short(m.read_at).replace('now', 'just now') : 'Sent') + '</div>';
      m.fresh = false;
    }
    box.innerHTML = h;
    if (jump || nearBottom) box.scrollTop = box.scrollHeight;
    var older = $('dm-older'); if (older) older.onclick = loadOlder;
  }
  $('dm-msgs').addEventListener('click', function (e) {
    var b = e.target.closest('[data-retry]'); if (!b) return;
    var m = msgs.find(function (x) { return String(x.id) === b.dataset.retry; });
    if (m) { msgs.splice(msgs.indexOf(m), 1); send(m.body); }
  });

  async function loadOlder() {
    var p = peer, first = msgs.find(function (m) { return typeof m.id === 'number'; });
    if (!p || !first) return;
    var box = $('dm-msgs'), h0 = box.scrollHeight;
    var r = await SB.rpc('dm_thread', { p_with: p.id, p_before: first.id });
    if (peer !== p || r.error) return;
    var rows = (r.data || []).slice().reverse();
    hasOlder = rows.length >= 60;
    msgs = rows.concat(msgs);
    renderMsgs(false);
    box.scrollTop = box.scrollHeight - h0;
  }

  async function send(text) {
    var inp = $('dm-in'), p = peer;
    var body = (text != null ? text : (inp ? inp.value : '')).trim();
    if (!body || !p || sending) return;
    if (text == null && inp) { inp.value = ''; inp.dispatchEvent(new Event('input')); }
    var m = { id: 't' + (++tmp), mine: true, body: body, created_at: new Date().toISOString(), pending: true, fresh: true };
    msgs.push(m); renderMsgs(true);
    sending = true;
    var r = await SB.rpc('send_dm', { p_to: p.id, p_body: body });
    sending = false;
    if (peer !== p) return;
    m.pending = false;
    if (r.error) {
      m.failed = r.error.message || 'Not sent';
      if (/only message your friends/i.test(m.failed)) { p.friend = false; }
    } else {
      m.id = Number(r.data);
      msgs = msgs.filter(function (x) { return x === m || x.id !== m.id; });
    }
    renderMsgs(true);
  }

  // ── options sheet: unfriend / block / report ──
  function closeSheet() { var s = $('dm-sheet'); if (s) s.classList.remove('open'); }
  function sheet(html) { $('dm-sheet-in').innerHTML = html; $('dm-sheet').classList.add('open'); }
  $('dm-sheet').addEventListener('click', function (e) { if (e.target === this) closeSheet(); });
  $('dm-menu').onclick = function () {
    if (!peer) return;
    var n = esc(nameOf(peer));
    sheet('<h3>' + n + '</h3>' +
      (peer.username ? '<button type="button" class="dm-opt" data-a="challenge">⚔️ Challenge ' + n + ' to a match</button>' : '') +
      '<button type="button" class="dm-opt" data-a="remove">👋 Remove friend</button>' +
      '<button type="button" class="dm-opt red" data-a="block">⛔ Block ' + n + '</button>' +
      '<button type="button" class="dm-opt red" data-a="report">🚩 Report ' + n + '</button>' +
      '<button type="button" class="dm-opt" data-a="close">' + T('cancel') + '</button>');
  };
  $('dm-sheet-in').addEventListener('click', async function (e) {
    var b = e.target.closest('[data-a]'); if (!b || !peer) return;
    var a = b.dataset.a, p = peer, n = esc(nameOf(p)), r;
    if (a === 'close') return closeSheet();
    if (a === 'challenge') { location.href = '/challenges/?invite=' + encodeURIComponent(p.username); return; }
    if (a === 'remove') return sheet('<h3>Remove ' + n + '?</h3><p>You won\'t be able to message each other until one of you adds the other again. Your chat history stays.</p><div class="dm-row2"><button type="button" class="dm-btn ghost" data-a="close">' + T('cancel') + '</button><button type="button" class="dm-btn danger" data-a="remove-yes">Remove</button></div>');
    if (a === 'block') return sheet('<h3>Block ' + n + '?</h3><p>They won\'t be able to message you or send you friend requests, and they disappear from your chats. You can unblock them under Requests.</p><div class="dm-row2"><button type="button" class="dm-btn ghost" data-a="close">' + T('cancel') + '</button><button type="button" class="dm-btn danger" data-a="block-yes">Block</button></div>');
    if (a === 'report') return sheet('<h3>Report ' + n + '</h3><p>Tell the admin what happened (abuse, scams, cheating). Your report is private.</p><textarea id="dm-rep" maxlength="600" placeholder="What happened?"></textarea><div class="dm-row2"><button type="button" class="dm-btn ghost" data-a="close">' + T('cancel') + '</button><button type="button" class="dm-btn danger" data-a="report-yes">Send report</button></div>');
    b.disabled = true;
    if (a === 'remove-yes') r = await SB.rpc('remove_friend', { p_who: p.id });
    else if (a === 'block-yes') r = await SB.rpc('block_player', { p_who: p.id });
    else if (a === 'report-yes') {
      var txt = ($('dm-rep').value || '').trim();
      if (!txt) { b.disabled = false; $('dm-rep').focus(); return; }
      r = await SB.rpc('submit_report', { p_tournament_slug: null, p_reported: nameOf(p) + ' (' + (p.tag || '') + ')', p_evidence_url: null, p_description: 'From Messages: ' + txt });
      if (!r.error) { sheet('<h3>Report sent</h3><p>Thanks — the admin will look into it. Block them too if you don\'t want more messages.</p><div class="dm-row2"><button type="button" class="dm-btn" data-a="close">OK</button></div>'); return; }
    }
    if (r && r.error) { b.disabled = false; sheet('<h3>Something went wrong</h3><p>' + esc(r.error.message) + '</p><div class="dm-row2"><button type="button" class="dm-btn" data-a="close">OK</button></div>'); return; }
    closeSheet();
    note(a === 'block-yes' ? nameOf(p) + ' is blocked.' : nameOf(p) + ' was removed from your friends.', 'ok');
    showHome(); poll();
  });

  // ── login state (the homepage logs in/out in place) ──
  SB.auth.getSession().then(function (r) { setUser(r && r.data && r.data.session ? r.data.session.user : null); });
  SB.auth.onAuthStateChange(function (_ev, session) { setUser(session ? session.user : null); });

  // deep links: /?dm=<JD tag> (from a message push) and /?chat=1 (friend-request push)
  try {
    var q = new URLSearchParams(location.search), dm = q.get('dm'), ch = q.get('chat');
    if (dm || ch) {
      q.delete('dm'); q.delete('chat');
      history.replaceState(history.state, '', location.pathname + (q.toString() ? '?' + q : '') + location.hash);
      if (dm) pendingDeepLink = dm;
      else setTimeout(function () { if (me) open(); }, 800);
    }
  } catch (e) {}

  // "Message / add friend" buttons elsewhere (challenge room): chat if already friends, else send the request
  async function connect(who) {
    if (!me) return;
    who = String(who || '').replace(/[^A-Za-z0-9_-]/g, '');
    if (!who) return;
    var r = await SB.rpc('chat_player', { p_who: who });
    if (r.data && r.data.friend) { if (!isOpen) open(); openThread(r.data); return; }
    var q = await SB.rpc('send_friend_request', { p_who: who });
    open();
    if (q.error) { note(q.error.message, 'err'); return; }
    if (q.data === 'accepted') { note('You\'re friends now — say hi! 👋', 'ok'); if (r.data) { r.data.friend = true; openThread(r.data); } return; }
    note(q.data === 'pending' ? 'Request already sent — waiting for @' + who + '.' : 'Friend request sent to @' + who + '. You can chat once they accept.', 'ok');
    tab = 'requests'; loadOverview();
  }

  window.jdChat = { open: open, close: close, openWith: openWith, connect: connect };
})();
