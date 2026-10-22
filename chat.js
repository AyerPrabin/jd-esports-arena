// JD Arena Messages: one inbox for friends (1:1), squad chats (groups of up to 8 friends —
// your Clash Squad team), match chats (the captain-vs-captain chat of an accepted challenge)
// ZULU, the AI assistant, and the official JD Esports chat (jd_chat.sql: the JD team writes as
// "JD Esports" with a verified tick from /mod/; the player can reply). JD Esports is people only:
// ZULU's automatic messages (zulu_auto.sql: welcome, tickets, reminders, points, results) come
// through zulu_feed() and show in the ZULU chat (zulu_channel.sql). Loaded (deferred) on every page that creates a Supabase client
// named `sb`; styles in /chat.css. Everything goes through the SECURITY DEFINER RPCs in
// schema.sql ("friends + direct messages" and "Messages v2"):
//   friends:  send_friend_request / respond_friend_request / remove_friend / block_player /
//             unblock_player / chat_overview / chat_player / dm_thread / send_dm / dm_mark_read
//   squads:   chat_threads / create_group_chat / add_group_members / leave_group_chat /
//             rename_group_chat / mute_group_chat / send_group_message / group_thread /
//             group_info / group_mark_read
//   matches:  challenge_messages (RLS: the two captains) / send_challenge_message / challenge_mark_read
//   badge:    dm_poll (every 5s on a visible tab: unread counts, newest unread for the banner)
// No realtime: the open conversation refreshes every 2.5s. New messages also arrive as Web
// Push (dm-push / chat-push Edge Functions) that open /?dm=<tag>, /?g=<group> or the challenge.
// ZULU talks to the zulu-ai-reply Edge Function; its chat is kept on this device only. The
// ZULU thread also shows your alerts (the notifications table: room ID + password, event
// reminders, results) as ZULU messages with copy buttons, and counts unread ones.
// Profile pictures come from the private avatars bucket as signed URLs (schema.sql
// "Messages v4": readable by the people you chat with). Non-friends: a friend request plus up
// to 3 messages (message request) until they accept.
// Phones: full screen, follows the on-screen keyboard. Laptops (≥1024px): two panes.
// Page mode (/chat/, an element #chat-page on the page): the same Messages built into the
// page instead of the floating bubble — always open, two panes from 760px, the phone tab
// bar hides while a conversation is open, and Back goes from a conversation to the list.
(function () {
  if (window.jdChat) return;
  var SB = (typeof sb !== 'undefined' && sb) ? sb : null;
  if (!SB || !document.body) return;
  var PAGE = document.getElementById('chat-page');

  var css = document.createElement('link');
  css.rel = 'stylesheet'; css.href = '/chat.css?v=10';
  document.head.appendChild(css);

  var NE = false;
  try { NE = localStorage.getItem('jd_lang') === 'ne'; } catch (e) {}
  var L = {
    messages: ['Messages', 'सन्देश'], all: ['All', 'सबै'], friends: ['Friends', 'साथी'], squads: ['Squads', 'स्क्वाड'],
    matches: ['Matches', 'म्याच'], requests: ['Requests', 'अनुरोध'],
    add: ['Add', 'थप्नुहोस्'], addPh: ['Search, or message @username / JD tag', 'खोज्नुहोस् वा @युजरनेम / JD ट्यागलाई सन्देश'],
    typePh: ['Message…', 'सन्देश लेख्नुहोस्…'], you: ['You', 'तपाईं'], now: ['Active now', 'अहिले सक्रिय'],
    accept: ['Accept', 'स्वीकार'], decline: ['Decline', 'अस्वीकार'], cancel: ['Cancel', 'रद्द'],
    newSquad: ['New squad chat', 'नयाँ स्क्वाड च्याट'], create: ['Create', 'बनाउनुहोस्'], members: ['members', 'सदस्य'],
    zulu: ['ZULU · AI assistant', 'ZULU · AI सहायक'], zuluSub: ['Chat, or ask about tournaments, tips, points…', 'प्रतियोगिता, नियम, अंक बारे सोध्नुहोस्…'],
    askZulu: ['Ask ZULU…', 'ZULU लाई सोध्नुहोस्…'], pick: ['Pick a chat to start messaging', 'सन्देश पठाउन च्याट छान्नुहोस्'],
    shareRoom: ['Share room to squad', 'स्क्वाडलाई रुम पठाउनुहोस्'], copy: ['Copy', 'कपी'], copied: ['Copied ✓', 'कपी भयो ✓'],
    seenBy: ['Seen by', 'हेर्नुभयो:'], openMatch: ['Open challenge', 'च्यालेन्ज खोल्नुहोस्']
  };
  var T = function (k) { return L[k][NE ? 1 : 0]; };

  var P = function (d) { return '<svg viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="' + d + '"/></svg>'; };
  var ICON = {
    chat: '<svg viewBox="0 0 256 256" fill="currentColor" aria-hidden="true"><path d="M128,20A108,108,0,0,0,31.85,177.23L21,209.66A20,20,0,0,0,46.34,235l32.43-10.81A108,108,0,1,0,128,20Zm0,192a84,84,0,0,1-42.06-11.27,12,12,0,0,0-6-1.62,12.1,12.1,0,0,0-3.8.62l-29.79,9.93,9.93-29.79a12,12,0,0,0-1-9.81A84,84,0,1,1,128,212Zm-44-84a16,16,0,1,1-16-16A16,16,0,0,1,84,128Zm60,0a16,16,0,1,1-16-16A16,16,0,0,1,144,128Zm60,0a16,16,0,1,1-16-16A16,16,0,0,1,204,128Z" transform="translate(4 0)"/></svg>',
    x: P('M208.49,191.51a12,12,0,0,1-17,17L128,145,64.49,208.49a12,12,0,0,1-17-17L111,128,47.51,64.49a12,12,0,0,1,17-17L128,111l63.51-63.52a12,12,0,0,1,17,17L145,128Z'),
    back: P('M168.49,199.51a12,12,0,0,1-17,17l-80-80a12,12,0,0,1,0-17l80-80a12,12,0,0,1,17,17L97,128Z'),
    dots: P('M144,128a16,16,0,1,1-16-16A16,16,0,0,1,144,128ZM60,112a16,16,0,1,0,16,16A16,16,0,0,0,60,112Zm136,0a16,16,0,1,0,16,16A16,16,0,0,0,196,112Z'),
    send: P('M231.4,44.34s0,.1,0,.15l-58.2,191.94a15.88,15.88,0,0,1-14,11.51q-.69.06-1.38.06a15.86,15.86,0,0,1-14.42-9.15L107,164.15a4,4,0,0,1,.77-4.58l57.92-57.92a8,8,0,0,0-11.31-11.31L96.43,148.26a4,4,0,0,1-4.58.77L17.08,112.64a16,16,0,0,1,2.49-29.8l191.94-58.2.15,0A16,16,0,0,1,231.4,44.34Z'),
    users: P('M125.18,156.94a64,64,0,1,0-82.36,0,100.23,100.23,0,0,0-39.49,32,12,12,0,0,0,19.35,14.2,76,76,0,0,1,122.64,0,12,12,0,0,0,19.36-14.2A100.33,100.33,0,0,0,125.18,156.94ZM44,108a40,40,0,1,1,40,40A40,40,0,0,1,44,108Zm206.1,97.67a12,12,0,0,1-16.78-2.57A76.31,76.31,0,0,0,172,172a12,12,0,0,1,0-24,40,40,0,1,0-14.85-77.16,12,12,0,1,1-8.92-22.28,64,64,0,0,1,65,108.38,100.23,100.23,0,0,1,39.49,32A12,12,0,0,1,250.1,205.67Z'),
    plus: P('M228,128a12,12,0,0,1-12,12H140v76a12,12,0,0,1-24,0V140H40a12,12,0,0,1,0-24h76V40a12,12,0,0,1,24,0v76h76A12,12,0,0,1,228,128Z'),
    swords: P('M221.66,133.66l-24,24a8,8,0,0,1-11.32-11.32L196.69,136,152,91.31,133.66,109.66a8,8,0,0,1-11.32-11.32L140.69,80l-26-26L56,54.06V112l26,26,18.34-18.35a8,8,0,0,1,11.32,11.32L93.31,149.31,136,192l10.34-10.35a8,8,0,0,1,11.32,11.32l-24,24a8,8,0,0,1-11.32,0L104,198.63,69.66,233A8,8,0,0,1,58.34,221.66L92.69,187.31,68.69,163.31,34.34,197.66a8,8,0,0,1-11.32-11.32L57.37,152,40,134.63V48a8,8,0,0,1,8-8h86.63l17.37,17.37,34.34-34.35a8,8,0,0,1,11.32,11.32L163.31,68.69l24,24,34.35-34.35a8,8,0,0,1,11.32,11.32L198.63,104l23,23A8,8,0,0,1,221.66,133.66Z'),
    gear: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M4 7h9M19 7h1M4 17h3M13 17h7"/><circle cx="16" cy="7" r="2.6"/><circle cx="10" cy="17" r="2.6"/></svg>',
    spark: P('M208,144a15.78,15.78,0,0,1-10.42,14.94L146,178l-19,51.62a15.92,15.92,0,0,1-29.88,0L78,178l-51.62-19a15.92,15.92,0,0,1,0-29.88L78,110l19-51.62a15.92,15.92,0,0,1,29.88,0L146,110l51.62,19A15.78,15.78,0,0,1,208,144ZM152,48h16V64a8,8,0,0,0,16,0V48h16a8,8,0,0,0,0-16H184V16a8,8,0,0,0-16,0V32H152a8,8,0,0,0,0,16Zm88,32h-8V72a8,8,0,0,0-16,0v8h-8a8,8,0,0,0,0,16h8v8a8,8,0,0,0,16,0V96h8a8,8,0,0,0,0-16Z')
  };

  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var $ = function (id) { return document.getElementById(id); };
  var mq = function (q) { return window.matchMedia && window.matchMedia(q).matches; };
  var phone = function () { return mq('(max-width:640px)'); };
  var wide = function () { return mq(PAGE ? '(min-width:760px)' : '(min-width:1024px)'); };
  var reduced = function () { return mq('(prefers-reduced-motion:reduce)'); };
  var store = {
    get: function (k) { try { return JSON.parse(localStorage.getItem(k) || 'null'); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }
  };

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
  function hue(s) { var h = 0; s = String(s || '?'); for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 360; return h; }
  // profile pictures: signed in batches (one request for everyone on screen), cached ~50 min
  var AV = {}, avWant = {}, avTimer = null;
  function wantAv(id) { if (AV[id] === undefined && !avWant[id]) { avWant[id] = 1; clearTimeout(avTimer); avTimer = setTimeout(signAvs, 80); } }
  async function signAvs() {
    var ids = Object.keys(avWant); avWant = {};
    if (!ids.length || !me) return;
    ids.forEach(function (i) { AV[i] = null; });
    try {
      var r = await SB.storage.from('avatars').createSignedUrls(ids.map(function (i) { return i + '/avatar.jpg'; }), 3600);
      (r.data || []).forEach(function (x, k) { var id = String(x.path || ids[k]).split('/')[0]; AV[id] = !x.error && x.signedUrl ? x.signedUrl : false; });
    } catch (e) {}
    var got = false;
    ids.forEach(function (i) { if (!AV[i]) AV[i] = false; else got = true; });
    if (got && isOpen) { if (!cur || wide()) renderOverview(); if (cur) { renderPeer(); if (cur.kind !== 'zulu') renderMsgs(false); } }
  }
  setInterval(function () { AV = {}; }, 50 * 60000);
  function avatar(p, size) {
    p = p || {};
    var name = p.username || p.tag || '?', h = hue(p.id || name);
    var bg = 'linear-gradient(145deg,hsl(' + h + ' 70% 52%),hsl(' + ((h + 40) % 360) + ' 75% 38%))';
    var pic = p.id && /^[0-9a-f-]{36}$/i.test(p.id) ? AV[p.id] : false;
    if (pic === undefined) wantAv(p.id);
    var logo = pic ? '<img src="' + esc(pic) + '" alt="" loading="lazy" onerror="this.remove()">'
      : p.logo && /^(https:|data:image\/)/.test(p.logo) ? '<img src="' + esc(p.logo) + '" alt="" loading="lazy">' : esc(name.charAt(0));
    return '<span class="dm-av' + (size ? ' ' + size : '') + (p.online ? ' on' : '') + '" style="background:' + bg + '" aria-hidden="true">' + logo + '</span>';
  }
  // squad chat avatar: two stacked faces (or the first letter of the chat name)
  function groupAv(g, size) {
    var f = (g && g.faces) || [];
    if (f.length >= 2) return '<span class="dm-gav' + (size ? ' ' + size : '') + '" aria-hidden="true">' + avatar(f[0], 'xs') + avatar(f[1], 'xs') + '</span>';
    var h = hue(g && g.id);
    return '<span class="dm-av' + (size ? ' ' + size : '') + ' sq" style="background:linear-gradient(145deg,hsl(' + h + ' 60% 46%),hsl(' + ((h + 50) % 360) + ' 70% 30%))" aria-hidden="true">' + ICON.users + '</span>';
  }
  function matchAv(size) { return '<span class="dm-av' + (size ? ' ' + size : '') + ' mt" aria-hidden="true">' + ICON.swords + '</span>'; }
  function jdAv(size) { return '<span class="dm-av' + (size ? ' ' + size : '') + ' jd" aria-hidden="true"><img src="/logo.png" alt=""></span>'; }
  var VERIFIED = '<svg class="dm-ver" viewBox="0 0 24 24" role="img" aria-label="Verified"><path fill="currentColor" d="M12 1.6l2.6 1.9 3.2-.1 1 3 2.6 1.9-1 3.1 1 3.1-2.6 1.9-1 3-3.2-.1L12 22.4l-2.6-1.9-3.2.1-1-3L2.6 15.7l1-3.1-1-3.1 2.6-1.9 1-3 3.2.1z"/><path fill="none" stroke="#0B1020" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" d="M7.6 12.3l3 3 5.8-6"/></svg>';
  function zuluAv(size) { return '<span class="dm-av' + (size ? ' ' + size : '') + ' zu" aria-hidden="true">' + ICON.spark + '</span>'; }
  var nameOf = function (p) { return p ? (p.username ? '@' + p.username : p.tag) : ''; };
  var emojiOnly = function (s) { return s.length <= 12 && /^(\p{Extended_Pictographic}|\p{Emoji_Component}|‍|️|\s)+$/u.test(s) && !/^[\d#*\s]+$/.test(s); };
  var roomOf = function (body) { var p = String(body || '').split('|'); return p[0] === 'ROOM' ? { id: p[1] || '', pass: p[2] || '', label: p.slice(3).join('|') } : null; };
  function copyText(t, btn) {
    (navigator.clipboard ? navigator.clipboard.writeText(t) : Promise.reject()).then(function () {
      if (!btn) return; var o = btn.dataset.lbl || btn.textContent; btn.dataset.lbl = o; btn.textContent = T('copied');
      setTimeout(function () { btn.textContent = o; }, 1600);
    }, function () { if (btn) btn.textContent = t; });
  }

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
  // homepage "Ask ZULU" pill: shown for visitors; once logged in, ZULU lives in Messages and
  // the pill, its nudge and anything calling fbOpen() open the ZULU chat here instead
  function syncZuluFab() {
    var pill = !!$('fab');
    document.body.classList.toggle('has-zulu-fab', pill && !me);
    document.body.classList.toggle('zulu-merged', pill && !!me);
  }
  syncZuluFab();
  if (typeof window.fbOpen === 'function') {
    var fbOpen0 = window.fbOpen;
    window.fbOpen = function () { if (me) { openZulu(); return; } return fbOpen0.apply(this, arguments); };
  }

  var panel = document.createElement('section');
  panel.className = 'dm-panel'; panel.setAttribute('role', 'dialog'); panel.setAttribute('aria-label', T('messages'));
  panel.innerHTML =
    '<div class="dm-view on" id="dm-home">' +
      '<div class="dm-head"><h2>' + T('messages') + '</h2>' +
        '<button type="button" class="dm-ib" id="dm-new" aria-label="' + esc(T('newSquad')) + '" title="' + esc(T('newSquad')) + '">' + ICON.users + '<i class="dm-ib-plus">+</i></button>' +
        '<button type="button" class="dm-ib" id="dm-gear" aria-label="Alert settings" title="Alert settings">' + ICON.gear + '</button>' +
        '<button type="button" class="dm-ib" id="dm-close" aria-label="Close">' + ICON.x + '</button></div>' +
      '<form class="dm-add" id="dm-add" autocomplete="off"><input id="dm-add-in" maxlength="40" placeholder="' + esc(T('addPh')) + '" aria-label="' + esc(T('addPh')) + '" enterkeyhint="send"><button type="submit">' + T('add') + '</button></form>' +
      '<div class="dm-note" id="dm-note" role="status"></div>' +
      '<div class="dm-tabs" role="tablist">' +
        ['all', 'friends', 'squads', 'matches', 'requests'].map(function (k, i) {
          return '<button type="button" role="tab" data-t="' + k + '" aria-selected="' + (i ? 'false' : 'true') + '">' + T(k) + '<b id="dm-tb-' + k + '" hidden></b></button>';
        }).join('') + '</div>' +
      '<div class="dm-list" id="dm-list"></div>' +
      '<div class="dm-mytag" id="dm-mytag" hidden></div>' +
    '</div>' +
    '<div class="dm-view" id="dm-thread">' +
      '<div class="dm-thead"><button type="button" class="dm-ib" id="dm-back" aria-label="Back">' + ICON.back + '</button><span id="dm-th-av"></span><button type="button" class="dm-who" id="dm-who"><b id="dm-th-name"></b><small id="dm-th-st"></small></button><button type="button" class="dm-ib" id="dm-menu" aria-label="Options">' + ICON.dots + '</button><button type="button" class="dm-ib" id="dm-close2" aria-label="Close">' + ICON.x + '</button></div>' +
      '<div id="dm-pin"></div>' +
      '<div class="dm-msgs" id="dm-msgs" aria-live="polite"></div>' +
      '<div id="dm-chips"></div>' +
      '<div id="dm-foot"></div>' +
    '</div>' +
    '<div class="dm-pick" id="dm-pick">' + ICON.chat + '<b>' + T('messages') + '</b><span>' + T('pick') + '</span></div>' +
    '<div class="dm-sheet" id="dm-sheet"><div class="dm-sheet-in" id="dm-sheet-in" role="dialog" aria-modal="true"></div></div>';
  if (PAGE) { panel.classList.add('page'); PAGE.appendChild(panel); fab.classList.add('page-hide'); }
  else document.body.appendChild(panel);

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
  // cur = the open conversation: { kind: 'dm'|'group'|'match'|'zulu', id, ... }
  var me = null, myCard = null, isOpen = false, tab = 'all', ov = null, th = null, cur = null, filter = '';
  var msgs = [], hasOlder = false, threadTimer = null, polled = false, lastAt = 0;
  var badge = { dm: 0, g: 0, m: 0, requests: 0, z: 0, jd: 0 }, jdLast = null, sending = false, tmp = 0, bannerTimer = null, pendingDeepLink = null;
  var ginfo = null, readMark = 0;
  var recs = null, recAt = 0, tourCache = null, zuluWait = null, chipFor = null;
  var MENTION = /(^|[^a-z0-9_])@zulu\b/i;

  function setBadges() {
    var chats = badge.dm + badge.g + badge.m + badge.z + badge.jd, n = chats + badge.requests;
    var c = fab.querySelector('.dm-count');
    c.textContent = n > 99 ? '99+' : n; c.hidden = !n;
    fab.classList.toggle('has-unread', n > 0);
    fab.setAttribute('aria-label', T('messages') + (n ? ', ' + n + ' new' : ''));
    var nc = $('nav-dm-count'); if (nc) { nc.textContent = c.textContent; nc.hidden = !n; }
    var base = document.title.replace(/^\(\d+\+?\) /, '');
    document.title = (chats ? '(' + (chats > 99 ? '99+' : chats) + ') ' : '') + base;
    var set = function (k, v) { var b = $('dm-tb-' + k); b.textContent = v > 99 ? '99+' : v; b.hidden = !v; };
    set('all', chats); set('friends', badge.dm); set('squads', badge.g); set('matches', badge.m); set('requests', badge.requests);
    // the installed app's icon shows the same count (sw.js sets a dot when a push arrives)
    try { if (navigator.setAppBadge) { if (n) navigator.setAppBadge(n); else navigator.clearAppBadge(); } } catch (e) {}
    var tb = document.querySelector('.tabbar [data-tab="chat"] .tb-count');
    if (tb) { tb.textContent = n > 99 ? '99+' : n; tb.hidden = !n; }
  }

  function setUser(u) {
    var id = u ? u.id : null;
    if (id === me) return;
    me = id; polled = false; lastAt = 0; ov = null; th = null; cur = null; msgs = []; myCard = null;
    badge = { dm: 0, g: 0, m: 0, requests: 0, z: 0, jd: 0 }; jdLast = null; zn = []; znTop = null; zf = []; zfTop = null; setBadges();
    fab.hidden = !me || !!PAGE; if (navRow) navRow.hidden = !me;
    if (PAGE) { var si = $('cp-signin'); if (si) si.hidden = !!me; panel.hidden = !me; }
    document.body.classList.toggle('has-dm', !!me);
    syncZuluFab(); recs = null; recAt = 0;
    if (!me) { close(true); return; }
    poll(); loadMyTag();
    if (PAGE && !pendingDeepLink) open();
    if (pendingDeepLink) { var w = pendingDeepLink; pendingDeepLink = null; w(); }
  }

  // your own JD tag, so friends can add you (and your squad name, the default squad chat name)
  async function loadMyTag() {
    var id = me, r = await SB.from('players').select('username, player_tag, squad_name').eq('id', id).maybeSingle();
    var box = $('dm-mytag'); if (!r.data || id !== me) return;
    myCard = r.data;
    box.innerHTML = '<span>Your tag <b>' + esc(r.data.player_tag) + '</b>' + (r.data.username ? ' · @' + esc(r.data.username) : '') + '</span><button type="button">Share</button>';
    box.hidden = false;
    box.querySelector('button').onclick = function () {
      var t = 'Add me on JD Arena: ' + (r.data.username ? '@' + r.data.username + ' · ' : '') + r.data.player_tag + ' https://jdesport.co.uk/';
      if (navigator.share && phone()) { navigator.share({ text: t }).catch(function () {}); return; }
      copyText(t, this);
    };
  }

  // ── polling ──
  function watching(k) {
    return isOpen && cur && $('dm-thread').classList.contains('on') && (
      (k.kind === 'dm' && cur.kind === 'dm' && cur.id === k.key) ||
      (k.kind === 'group' && cur.kind === 'group' && cur.id === k.key) ||
      (k.kind === 'match' && cur.kind === 'match' && cur.id === k.key));
  }
  async function poll() {
    if (!me || document.hidden) return;
    var r = await SB.rpc('dm_poll');
    if (r.error || !r.data) return;
    var d = r.data;
    if (pollN++ % 3 === 0) await loadZn(true);
    var jr = await SB.rpc('jd_poll'), jd = (jr && jr.data) || {};
    jdLast = jd.last || null;
    var next = { dm: d.unread || 0, g: d.g_unread || 0, m: d.m_unread || 0, requests: d.requests || 0, z: badge.z, jd: jd.unread || 0 };
    var changed = JSON.stringify(next) !== JSON.stringify(badge);
    var grewReq = polled && next.requests > badge.requests;
    badge = next; setBadges();
    var last = d.last_any || d.last;
    if (last) {
      var at = new Date(last.at || 0).getTime() || last.id;
      if (at > lastAt) {
        if (polled && !watching(last)) notify(last);
        lastAt = at;
      }
    }
    if (grewReq) { pop(); bump(); }
    polled = true;
    if (isOpen && changed && (!cur || wide())) loadOverview();
  }
  // ── ZULU alerts: your notifications (room ID + password, reminders, results) as ZULU messages ──
  var zn = [], znTop = null, pollN = 0, zf = [], zfTop = null;
  async function loadZn(fromPoll) {
    if (!me) return zn;
    var id = me, r = await SB.from('notifications').select('id, title, body, room_id, room_pass, tournament_slug, created_at, read_at')
      .eq('player_id', me).order('created_at', { ascending: false }).limit(40);
    var f = await SB.rpc('zulu_feed');
    if (r.error || id !== me) return zn;
    zn = r.data || [];
    if (!f.error && Array.isArray(f.data)) zf = f.data;
    var newest = zn[0] ? zn[0].id : null, isNew = znTop !== null && newest && newest !== znTop && !zn[0].read_at;
    znTop = newest || znTop || '';
    var fTop = zf[0] ? zf[0].id : null, fNew = zfTop !== null && fTop && fTop !== zfTop && !zf[0].read_at;
    zfTop = fTop || zfTop || '';
    var watchingZ = isOpen && cur && cur.kind === 'zulu' && $('dm-thread').classList.contains('on') && !document.hidden;
    if (watchingZ) {
      if (zn.some(function (n) { return !n.read_at; }) || zf.some(function (m) { return !m.read_at; })) markZnRead();
      if (isNew || fNew) { msgs = zuluLoad(); msgs[msgs.length - 1].fresh = true; renderMsgs(true); }
    } else {
      badge.z = zn.filter(function (n) { return !n.read_at; }).length + zf.filter(function (m) { return !m.read_at; }).length;
      // the homepage shows its own alert banner for these, so only other pages get one here
      if (isNew && fromPoll && typeof window.notifBanner !== 'function') notifyZulu(zn[0]);
      else if (fNew && fromPoll) notifyZulu({ title: String(zf[0].body).split('\n')[0].slice(0, 90) });
    }
    if (!fromPoll) setBadges();
    return zn;
  }
  async function markZnRead() {
    var ids = zn.filter(function (n) { return !n.read_at; }).map(function (n) { return n.id; });
    badge.z = 0; setBadges();
    var at = new Date().toISOString();
    if (zf.some(function (m) { return !m.read_at; })) { zf.forEach(function (m) { if (!m.read_at) m.read_at = at; }); SB.rpc('zulu_feed_read'); }
    if (!ids.length) return;
    zn.forEach(function (n) { if (!n.read_at) n.read_at = at; });
    await SB.from('notifications').update({ read_at: at }).in('id', ids);
  }
  function notifyZulu(n) {
    pop(); buzz(); bump();
    banner.innerHTML = zuluAv('sm') + '<span class="dm-bt"><b>ZULU</b><small>' + esc(n.title + (n.room_id ? ' · Room ' + n.room_id : '')) + '</small></span><span class="dm-bk">Open</span>';
    banner.onclick = function () { banner.classList.remove('show'); openZulu(); };
    banner.classList.add('show');
    clearTimeout(bannerTimer);
    bannerTimer = setTimeout(function () { banner.classList.remove('show'); }, 5500);
  }
  function bump() { if (reduced()) return; fab.classList.remove('bump'); void fab.offsetWidth; fab.classList.add('bump'); }
  function notify(m) {
    pop(); buzz(); bump();
    var who = { id: m.from, username: (m.name || '').replace(/^@/, '') };
    var av = m.kind === 'group' ? groupAv({ id: m.key }, 'sm') : m.kind === 'match' ? matchAv('sm') : avatar(who, 'sm');
    var title = m.kind === 'group' ? '👥 ' + (m.title || 'Squad chat') : m.kind === 'match' ? '⚔️ ' + (m.title || 'Challenge') : (m.name || 'New message');
    var body = (m.kind === 'dm' || !m.kind ? '' : (m.name || '') + ': ') + (m.body || '');
    banner.innerHTML = av + '<span class="dm-bt"><b>' + esc(title) + '</b><small>' + esc(body) + '</small></span><span class="dm-bk">Reply</span>';
    banner.onclick = function () {
      banner.classList.remove('show');
      if (m.kind === 'group') openGroup(m.key); else if (m.kind === 'match') openMatch(m.key); else openWith(m.from);
    };
    banner.classList.add('show');
    clearTimeout(bannerTimer);
    bannerTimer = setTimeout(function () { banner.classList.remove('show'); }, 5500);
  }
  setInterval(poll, 5000);
  document.addEventListener('visibilitychange', function () { if (!document.hidden) { poll(); if (cur) refreshThread(); } });

  // ── panel ──
  function layout() {
    panel.classList.toggle('wide', wide()); panel.classList.toggle('has-cur', !!cur);
    panel.scrollTop = 0; // the panel never scrolls itself; only its lists do
    document.body.classList.toggle('dm-in-thread', !!cur && !wide());
  }
  function open() {
    if (!me) return;
    if (!isOpen) {
      isOpen = true; panel.classList.add('open');
      if (phone() && !PAGE) { document.body.classList.add('dm-locked'); try { history.pushState({ jdDm: 1 }, ''); } catch (e) {} }
    }
    layout();
    if (!cur) showHome(); else loadOverview();
  }
  function close(silent) {
    if (!isOpen) return;
    if (PAGE) { if (me) { if (cur) showHome(); return; } }
    isOpen = false; cur = null; stopThread();
    panel.classList.remove('open'); document.body.classList.remove('dm-locked');
    closeSheet(); fitKeyboard(true);
    if (!silent && history.state && history.state.jdDm) { try { history.back(); } catch (e) {} }
    try { fab.focus({ preventScroll: true }); } catch (e) {}
  }
  window.addEventListener('popstate', function () {
    if (PAGE) { if (cur && !wide()) showHome(true); return; }
    if (isOpen) close(true);
  });
  window.addEventListener('resize', function () { if (isOpen) layout(); });
  fab.onclick = function () { isOpen ? close() : open(); };
  $('dm-close').onclick = function () { close(); };
  $('dm-close2').onclick = function () { close(); };
  $('dm-back').onclick = showHome;
  $('dm-new').onclick = function () { newSquadSheet(); };
  $('dm-gear').onclick = function () { settingsSheet(); };
  document.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape' || !isOpen) return;
    if ($('dm-sheet').classList.contains('open')) closeSheet();
    else if (cur && !wide()) showHome(); else if (!PAGE) close();
  });
  panel.querySelectorAll('.dm-tabs button').forEach(function (b) {
    b.onclick = function () { tab = b.dataset.t; renderOverview(); };
  });

  // phones: keep the composer above the on-screen keyboard
  function fitKeyboard(reset) {
    var vv = window.visualViewport;
    if (reset || !vv || !isOpen || !phone() || (PAGE && !cur)) { panel.style.height = ''; panel.style.top = ''; return; }
    panel.style.top = vv.offsetTop + 'px';
    panel.style.height = vv.height + 'px';
    var box = $('dm-msgs');
    if (box && document.activeElement && document.activeElement.id === 'dm-in') box.scrollTop = box.scrollHeight;
  }
  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', function () { fitKeyboard(); });
    window.visualViewport.addEventListener('scroll', function () { fitKeyboard(); });
  }

  function showHome(fromPop) {
    // page mode: a conversation opened on a phone added a history entry; leave it the same way
    if (PAGE && cur && !wide() && fromPop !== true && history.state && history.state.jdThread) { try { history.back(); } catch (e) {} return; }
    cur = null; stopThread(); closeSheet(); layout(); fitKeyboard(true);
    $('dm-thread').classList.remove('on'); $('dm-home').classList.add('on');
    renderOverview(); loadOverview();
  }

  async function loadOverview() {
    var r = await Promise.all([SB.rpc('chat_overview'), SB.rpc('chat_threads')]);
    if (r[0].error) { if (!ov) $('dm-list').innerHTML = '<div class="dm-empty">Couldn\'t load your chats. Check your connection.</div>'; return; }
    ov = r[0].data || { friends: [], incoming: [], outgoing: [], blocked: [] };
    th = (r[1] && r[1].data) || { groups: [], matches: [] };
    renderOverview();
    loadRecs();
  }

  // ── "ZULU suggests": next steps picked from your own data (no AI quota used) ──
  async function loadRecs() {
    if (!ov || !th) return;
    if (recs && Date.now() - recAt < 60000) return;
    recAt = Date.now();
    var out = [], online = ov.friends.filter(function (f) { return f.online; });
    th.matches.filter(function (m) { return m.status === 'accepted' && !m.room_id; }).slice(0, 1).forEach(function (m) {
      out.push({ ic: '⚔️', t: 'Post the room for ' + m.mode + ' vs ' + nameOf(m.other), s: 'Your match is on — share the room ID', go: function () { openMatch(m.id); } });
    });
    th.matches.filter(function (m) { return m.unread; }).slice(0, 1).forEach(function (m) {
      out.push({ ic: '💬', t: nameOf(m.other) + ' wrote in your match chat', s: m.last_body || '', go: function () { openMatch(m.id); } });
    });
    try {
      if (!tourCache) { var r = await fetch('/tournaments.json', { cache: 'no-store' }); tourCache = r.ok ? await r.json() : { tournaments: [] }; }
      var next = (tourCache.tournaments || []).filter(function (t) {
        var st = String(t.status || 'upcoming').toLowerCase(), ms = Date.parse(t.start);
        return (st === 'upcoming' || st === 'live') && !String(t.winner || '').trim() && (!isFinite(ms) || ms > Date.now() - 3 * 3600e3);
      }).sort(function (a, b) { return (Date.parse(a.start) || 9e15) - (Date.parse(b.start) || 9e15); })[0];
      if (next) out.push({ ic: '🏆', t: next.name, s: [next.date, next.time, next.prize ? 'Prize ' + next.prize : '', next.entry].filter(Boolean).join(' · '), href: '/events/' });
    } catch (e) {}
    try {
      var oc = await SB.rpc('get_open_challenges');
      var open = (oc.data || []).filter(function (c) { return !c.mine; });
      var forMe = open.filter(function (c) { return c.for_me; });
      if (forMe.length) out.unshift({ ic: '🎯', t: forMe[0].creator_name + ' challenged you', s: forMe[0].mode + ' · ' + forMe[0].stake + ' pts each', href: '/challenges/' });
      else if (open.length) out.push({ ic: '🔥', t: open.length + ' open challenge' + (open.length > 1 ? 's' : '') + ' in the lobby', s: 'Accept one and win JD points', href: '/challenges/' });
    } catch (e) {}
    if (online.length) { var f = online[0]; out.push({ ic: '🟢', t: nameOf(f) + ' is online', s: 'Challenge them to a 1v1', href: '/challenges/?invite=' + encodeURIComponent(f.username || '') }); }
    if (!ov.friends.length) out.push({ ic: '🤝', t: 'Add your teammates', s: 'Search their username or JD tag above', go: function () { $('dm-add-in').focus(); } });
    else if (!th.groups.length) out.push({ ic: '👥', t: 'Make a squad chat', s: 'Plan matches with your Clash Squad team', go: function () { newSquadSheet(); } });
    out.push({ ic: '✨', t: 'Ask ZULU anything', s: 'Tournaments, rules, points, tips', go: openZulu });
    recs = out.slice(0, 5);
    if (isOpen && (!cur || wide())) renderOverview();
  }
  function recsHtml() {
    if (!recs || !recs.length) return '';
    return '<div class="dm-sec dm-sec-ai">' + ICON.spark + ' ZULU suggests</div><div class="dm-recs">' + recs.map(function (r, i) {
      return (r.href ? '<a class="dm-rec" href="' + esc(r.href) + '"' : '<button type="button" class="dm-rec" data-rec="' + i + '"') +
        '><span class="dm-rec-ic" aria-hidden="true">' + r.ic + '</span><b>' + esc(r.t) + '</b><small>' + esc(r.s) + '</small>' + (r.href ? '</a>' : '</button>');
    }).join('') + '</div>';
  }

  // one inbox row per conversation
  function rowFor(it) {
    var active = cur && cur.kind === it.kind && cur.id === it.id ? ' active' : '';
    var right = it.unread ? '<span class="dm-dot' + (it.muted ? ' mute' : '') + '">' + (it.unread > 9 ? '9+' : it.unread) + '</span>' : (it.muted ? '<span class="dm-mute" title="Muted">🔕</span>' : '');
    return '<button type="button" class="dm-row' + (it.unread && !it.muted ? ' unread' : '') + active + '" data-k="' + it.kind + '" data-open="' + esc(it.id) + '">' + it.av +
      '<span class="dm-mid"><span class="dm-name">' + it.title + '</span>' +
      '<span class="dm-prev"><span>' + esc(it.prev) + '</span>' + (it.at ? '<span>· ' + short(it.at) + '</span>' : '') + '</span></span>' + right + '</button>';
  }
  function items() {
    var out = [];
    (ov ? ov.friends : []).forEach(function (f) {
      out.push({ kind: 'dm', id: f.id, at: f.last_at, unread: f.unread, av: avatar(f), search: (f.username || '') + ' ' + (f.tag || '') + ' ' + (f.squad || ''),
        title: esc(nameOf(f)) + (f.app ? ' <span class="dm-badge" title="Uses the app">📱</span>' : ''),
        prev: f.last_body ? (f.last_mine ? T('you') + ': ' : '') + f.last_body : 'Say hi 👋' });
    });
    (th ? th.groups : []).forEach(function (g) {
      out.push({ kind: 'group', id: g.id, at: g.last_at, unread: g.unread, muted: g.muted, av: groupAv(g), search: g.name,
        title: '<span class="dm-tag sq">Squad</span>' + esc(g.name),
        prev: g.last_body ? (g.last_name ? (g.last_mine ? T('you') : g.last_name) + ': ' : '') + g.last_body : g.count + ' ' + T('members') });
    });
    (th ? th.matches : []).forEach(function (m) {
      var st = m.status === 'completed' ? 'Finished' : m.status === 'disputed' ? 'Disputed' : 'Live';
      out.push({ kind: 'match', id: m.id, at: m.last_at, unread: m.unread, av: matchAv(), search: m.mode + ' ' + nameOf(m.other),
        title: '<span class="dm-tag mt ' + m.status + '">' + st + '</span>' + esc(m.mode) + ' vs ' + esc(nameOf(m.other)),
        prev: m.last_body ? (m.last_mine ? T('you') + ': ' : '') + m.last_body : (m.room_id ? '🎮 Room ' + m.room_id : 'Share the room details here') });
    });
    return out;
  }
  function jdRow() {
    var l = jdLast, active = cur && cur.kind === 'jd' ? ' active' : '';
    var prev = l ? (l.mine ? T('you') + ': ' : '') + l.body : 'Official JD Esports team · ask us anything';
    var dot = badge.jd ? '<span class="dm-dot">' + (badge.jd > 9 ? '9+' : badge.jd) + '</span>' : '';
    return '<button type="button" class="dm-row jd' + (badge.jd ? ' unread' : '') + active + '" data-k="jd" data-open="jd">' + jdAv() +
      '<span class="dm-mid"><span class="dm-name">JD Esports ' + VERIFIED + '</span>' +
      '<span class="dm-prev"><span>' + esc(prev) + '</span>' + (l && l.at ? '<span>· ' + short(l.at) + '</span>' : '') + '</span></span>' + dot + '</button>';
  }
  function zuluRow() {
    var z = store.get('jd_zulu_dm') || [], last = z[z.length - 1], n = zn[0];
    if (zf[0] && (!n || new Date(zf[0].created_at) > new Date(n.created_at))) n = { title: String(zf[0].body).split('\n')[0], created_at: zf[0].created_at };
    var active = cur && cur.kind === 'zulu' ? ' active' : '';
    var useN = n && (!last || new Date(n.created_at) > new Date(last.at || 0));
    var prev = useN ? '🔔 ' + n.title + (n.room_id ? ' · Room ' + n.room_id : '') : last ? (last.role === 'user' ? T('you') + ': ' : '') + last.content : T('zuluSub');
    var at = useN ? n.created_at : last && last.at;
    var dot = badge.z ? '<span class="dm-dot">' + (badge.z > 9 ? '9+' : badge.z) + '</span>' : '';
    return '<button type="button" class="dm-row zulu' + (badge.z ? ' unread' : '') + active + '" data-k="zulu" data-open="zulu">' + zuluAv() +
      '<span class="dm-mid"><span class="dm-name">' + T('zulu') + ' <span class="dm-tag ai">AI</span></span>' +
      '<span class="dm-prev"><span>' + esc(prev) + '</span>' + (at ? '<span>· ' + short(at) + '</span>' : '') + '</span></span>' + dot + '</button>';
  }

  function renderOverview() {
    panel.querySelectorAll('.dm-tabs button').forEach(function (b) { b.setAttribute('aria-selected', b.dataset.t === tab ? 'true' : 'false'); });
    var list = $('dm-list');
    if (!ov) { list.innerHTML = '<div class="dm-skel"><i></i><i></i><i></i><i></i></div>'; return; }
    var h = '', q = filter.toLowerCase().replace(/^@/, '');
    var match = function (it) { return !q || String(it.search).toLowerCase().indexOf(q) >= 0; };
    if (tab === 'requests') {
      if (ov.incoming.length) h += '<div class="dm-sec">Friend requests</div>' + ov.incoming.map(function (p) {
        return '<div class="dm-row">' + avatar(p) + '<span class="dm-mid"><span class="dm-name">' + esc(nameOf(p)) + '</span><span class="dm-prev"><span>' + esc(p.tag || '') + ' · ' + short(p.at) + '</span></span></span>' +
          '<span class="dm-acts"><button type="button" class="dm-btn ghost" data-chat="' + esc(p.id) + '" aria-label="Open chat with ' + esc(nameOf(p)) + '">💬</button><button type="button" class="dm-btn" data-accept="' + esc(p.id) + '">' + T('accept') + '</button><button type="button" class="dm-btn ghost" data-decline="' + esc(p.id) + '" aria-label="' + T('decline') + ' ' + esc(nameOf(p)) + '">✕</button></span></div>';
      }).join('');
      if (ov.outgoing.length) h += '<div class="dm-sec">Sent · waiting</div>' + ov.outgoing.map(function (p) {
        return '<div class="dm-row">' + avatar(p) + '<span class="dm-mid"><span class="dm-name">' + esc(nameOf(p)) + '</span><span class="dm-prev"><span>Request sent ' + short(p.at) + '</span></span></span>' +
          '<span class="dm-acts"><button type="button" class="dm-btn ghost" data-chat="' + esc(p.id) + '">💬 Message</button><button type="button" class="dm-btn ghost" data-remove="' + esc(p.id) + '">' + T('cancel') + '</button></span></div>';
      }).join('');
      if (ov.blocked.length) h += '<div class="dm-sec">Blocked</div>' + ov.blocked.map(function (p) {
        return '<div class="dm-row">' + avatar(p) + '<span class="dm-mid"><span class="dm-name">' + esc(nameOf(p)) + '</span></span>' +
          '<span class="dm-acts"><button type="button" class="dm-btn ghost" data-unblock="' + esc(p.id) + '">Unblock</button></span></div>';
      }).join('');
      if (!h) h = '<div class="dm-empty"><span class="dm-empty-ic">' + ICON.users + '</span><b>No requests</b>When someone adds you, it shows up here and in your notifications.</div>';
      list.innerHTML = h; return;
    }
    var all = items();
    var kind = { friends: 'dm', squads: 'group', matches: 'match' }[tab];
    var rows = all.filter(function (it) { return (!kind || it.kind === kind) && match(it); })
      .sort(function (a, b) { return new Date(b.at || 0) - new Date(a.at || 0); });
    // online friends strip (Messenger style)
    var online = ov.friends.filter(function (f) { return f.online; });
    if ((tab === 'all' || tab === 'friends') && online.length && !q) {
      h += '<div class="dm-strip" aria-label="Active now">' + online.map(function (f) {
        return '<button type="button" data-k="dm" data-open="' + esc(f.id) + '">' + avatar(f) + '<span>' + esc(f.username || f.tag) + '</span></button>';
      }).join('') + '</div>';
    }
    if (tab === 'all' && !q) h += recsHtml();
    if (tab === 'all' && (!q || 'jd esports team'.indexOf(q) >= 0)) h += jdRow();
    if (tab === 'all' && (!q || 'zulu ai'.indexOf(q) >= 0)) h += zuluRow();
    if (tab === 'squads' || (tab === 'all' && !th.groups.length && ov.friends.length && !q)) {
      h += '<button type="button" class="dm-row dm-cta" data-new="1"><span class="dm-av sq plus">' + ICON.plus + '</span><span class="dm-mid"><span class="dm-name">' + T('newSquad') + '</span><span class="dm-prev"><span>Group chat with your Clash Squad team</span></span></span></button>';
    }
    h += rows.map(rowFor).join('');
    if (!rows.length) {
      if (q) h += '<div class="dm-empty">No chats match “' + esc(filter) + '”. Press <b style="display:inline">' + T('add') + '</b> to send a friend request.</div>';
      else if (tab === 'matches') h += '<div class="dm-empty"><span class="dm-empty-ic">' + ICON.swords + '</span><b>No live matches</b>When someone accepts your Clash Squad challenge, the match chat with the other captain shows up here.<br><a class="dm-btn" style="display:inline-grid;place-items:center;margin-top:12px;text-decoration:none" href="/challenges/">Go to challenges</a></div>';
      else if (tab === 'squads') h += '<div class="dm-empty">Make a squad chat for your 2v2–4v4 team: plan, share room IDs, call the next match.</div>';
      else if (!ov.friends.length) h += '<div class="dm-empty"><span class="dm-empty-ic">' + ICON.users + '</span><b>No friends yet</b>Add your squadmates by their username or JD tag (like JD-7F3K2) above. Once they accept, you can chat and make a squad chat together.</div>';
    }
    list.innerHTML = h;
  }

  $('dm-list').addEventListener('click', async function (e) {
    var b = e.target.closest('button'); if (!b) return;
    var id;
    if (b.dataset.rec) { var rc = recs && recs[Number(b.dataset.rec)]; if (rc && rc.go) rc.go(); return; }
    if (b.dataset.new) { newSquadSheet(); return; }
    if ((id = b.dataset.open)) { openKind(b.dataset.k, id); return; }
    if ((id = b.dataset.chat)) { openRequest(id); return; }
    b.disabled = true;
    var r;
    if ((id = b.dataset.accept)) r = await SB.rpc('respond_friend_request', { p_from: id, p_accept: true });
    else if ((id = b.dataset.decline)) r = await SB.rpc('respond_friend_request', { p_from: id, p_accept: false });
    else if ((id = b.dataset.remove)) r = await SB.rpc('remove_friend', { p_who: id });
    else if ((id = b.dataset.unblock)) r = await SB.rpc('unblock_player', { p_who: id });
    if (r && r.error) { note(r.error.message, 'err'); b.disabled = false; return; }
    if (b.dataset.accept) { note('You\'re friends now — say hi! 👋', 'ok'); tab = 'friends'; }
    await loadOverview(); poll();
  });
  function openKind(k, id) {
    if (k === 'zulu') return openZulu();
    if (k === 'jd') return openJd();
    if (k === 'group') return openGroup(id);
    if (k === 'match') return openMatch(id);
    var f = ov && ov.friends.find(function (x) { return x.id === id; });
    if (f) openThread(Object.assign({ kind: 'dm', friend: true }, f));
  }

  // who someone is to you: 'friend', 'in' (they asked you), 'out' (you asked them) or 'none'
  function rel(id) {
    if (!ov) return 'none';
    if (ov.friends.some(function (f) { return f.id === id; })) return 'friend';
    if (ov.incoming.some(function (x) { return x.id === id; })) return 'in';
    if (ov.outgoing.some(function (x) { return x.id === id; })) return 'out';
    return 'none';
  }
  function openRequest(id) {
    var who = ov && (ov.incoming.concat(ov.outgoing).find(function (x) { return x.id === id; }));
    if (!who) return;
    openThread(Object.assign({ kind: 'dm', friend: false, req: rel(id) }, who));
  }
  function note(t, cls) { var n = $('dm-note'); n.className = 'dm-note' + (cls ? ' ' + cls : ''); n.textContent = t || ''; }
  $('dm-add-in').addEventListener('input', function () { filter = this.value.trim(); if (tab === 'requests') tab = 'all'; renderOverview(); });
  $('dm-add').onsubmit = async function (e) {
    e.preventDefault();
    var inp = $('dm-add-in'), v = inp.value.trim(), btn = this.querySelector('button');
    if (!v) { inp.focus(); return; }
    btn.disabled = true; note('');
    var r = await SB.rpc('send_friend_request', { p_who: v });
    btn.disabled = false;
    if (r.error) { note(r.error.message, 'err'); return; }
    inp.value = ''; filter = '';
    var who = v.replace(/^@/, '');
    note({ sent: 'Request sent to ' + who + '. You can chat once they accept.', pending: 'Already sent — waiting for ' + who + ' to accept.',
      already: 'You and ' + who + ' are already friends.', accepted: 'They had already added you — you\'re friends now! 🎉' }[r.data] || 'Done.', 'ok');
    tab = (r.data === 'sent' || r.data === 'pending') ? 'requests' : 'friends';
    await loadOverview(); poll();
    await openWith(v);
    if (cur && cur.kind === 'dm' && cur.friend === false && cur.req === 'none' && (r.data === 'sent' || r.data === 'pending')) { cur.req = 'out'; renderMsgs(false); }
  };

  // ── conversations ──
  function stopThread() { clearInterval(threadTimer); threadTimer = null; }
  async function openWith(who) {
    if (!me) { pendingDeepLink = function () { openWith(who); }; return; }
    var card = null;
    if (ov) card = ov.friends.find(function (f) { return f.id === who || f.tag === who || ('@' + f.username).toLowerCase() === String(who).toLowerCase(); });
    if (card) card = Object.assign({ kind: 'dm', friend: true }, card);
    else {
      var r = await SB.rpc('chat_player', { p_who: String(who) });
      if (r.error || !r.data) { open(); note('That player isn\'t available to chat.', 'err'); return; }
      card = Object.assign({ kind: 'dm' }, r.data);
      if (!card.friend) { card.friend = false; card.req = rel(card.id); }
    }
    if (!isOpen) open();
    openThread(card);
  }
  async function openGroup(id) {
    if (!me) { pendingDeepLink = function () { openGroup(id); }; return; }
    var g = th && th.groups.find(function (x) { return x.id === id; });
    if (!isOpen) open();
    openThread(Object.assign({ kind: 'group', id: id, name: (g && g.name) || 'Squad chat', faces: g && g.faces, count: g && g.count, muted: g && g.muted }, {}));
  }
  async function openMatch(id) {
    if (!me) { pendingDeepLink = function () { openMatch(id); }; return; }
    if (!isOpen) open();
    openThread({ kind: 'match', id: id, mode: '', other: null });
  }
  function openZulu() { if (!isOpen) open(); openThread({ kind: 'zulu', id: 'zulu' }); }
  function openJd() {
    if (!me) { pendingDeepLink = openJd; return; }
    if (!isOpen) open(); openThread({ kind: 'jd', id: 'jd' });
  }

  function composer(ph, max) {
    return '<form class="dm-compose" id="dm-form"><textarea id="dm-in" rows="1" maxlength="' + max + '" placeholder="' + esc(ph) + '" aria-label="' + esc(ph) + '" enterkeyhint="send"></textarea>' +
      '<button type="button" class="dm-quick" id="dm-like" aria-label="Send a thumbs up">👍</button><button type="submit" class="dm-send" id="dm-send" aria-label="Send" hidden>' + ICON.send + '</button></form>';
  }
  function openThread(p) {
    if (PAGE && !wide() && !cur) { try { history.pushState({ jdThread: 1 }, ''); } catch (e) {} }
    cur = p; msgs = []; hasOlder = false; ginfo = null; readMark = 0; sig = '';
    closeSheet(); layout();
    $('dm-home').classList.toggle('on', wide()); $('dm-thread').classList.add('on');
    if (wide()) renderOverview();
    renderPeer();
    $('dm-pin').innerHTML = ''; $('dm-chips').innerHTML = '';
    $('dm-msgs').innerHTML = '<div class="dm-skel msgs"><i></i><i></i><i></i></div>';
    var foot = '';
    if (p.kind === 'dm' && p.friend === false) foot = composer(p.req === 'in' ? 'Reply…' : 'Message request…', 500);
    else if (p.kind === 'zulu') foot = composer(T('askZulu'), 500);
    else if (p.kind === 'jd') foot = composer('Message the JD team…', 1000);
    else if (p.kind === 'match') foot = composer('Message… · @zulu asks AI', 300);
    else if (p.kind === 'group') foot = composer('Message… · @zulu asks AI', 500);
    else foot = composer(T('typePh'), 500);
    $('dm-foot').innerHTML = foot;
    chipFor = null;
    if (p.kind === 'zulu') chips(['👋 Hey ZULU!', '🪙 How many points do I have?', '🎮 When is my next match?', '🏆 Next tournament?', '🎯 Free Fire tips', '😂 Tell me a gaming joke']);
    var inp = $('dm-in');
    if (inp) {
      var sync = function () {
        inp.style.height = 'auto'; inp.style.height = Math.min(inp.scrollHeight, 120) + 'px';
        var has = !!inp.value.trim(); $('dm-send').hidden = !has && cur.kind !== 'zulu'; $('dm-like').hidden = has || cur.kind === 'zulu';
      };
      inp.addEventListener('input', sync); sync();
      inp.addEventListener('keydown', function (e) { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && !phone()) { e.preventDefault(); send(); } });
      inp.addEventListener('focus', function () { setTimeout(fitKeyboard, 250); });
      $('dm-form').onsubmit = function (e) { e.preventDefault(); send(); };
      $('dm-like').onclick = function () { send('👍'); };
      if (!phone()) setTimeout(function () { try { inp.focus(); } catch (e) {} }, 60);
    }
    stopThread();
    if (p.kind === 'zulu') {
      msgs = zuluLoad(); renderMsgs(true);
      loadZn().then(function () { if (cur !== p) return; msgs = zuluLoad(); renderMsgs(true); markZnRead(); });
      return;
    }
    refreshThread(true);
    threadTimer = setInterval(function () { if (!document.hidden) refreshThread(); }, 2500);
  }
  // swap the chips row without hiding the newest message behind it
  function setChips(html) {
    var box = $('dm-msgs'), bottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 80;
    $('dm-chips').innerHTML = html;
    if (bottom) box.scrollTop = box.scrollHeight;
  }
  function chips(list, extra) {
    setChips('<div class="dm-chips">' + (extra || '') + list.map(function (t) { return '<button type="button">' + esc(t) + '</button>'; }).join('') + '</div>');
  }
  // quick replies that fit the last message you got (instant, no AI), then ✨ for AI ideas
  function smartReplies(last, kind) {
    var b = String(last || '').toLowerCase(), out = [];
    var add = function () { for (var i = 0; i < arguments.length; i++) if (out.indexOf(arguments[i]) < 0) out.push(arguments[i]); };
    if (/(room|\bid\b|pass)/.test(b)) add('Room ready ✅', 'Making it now ⏳');
    if (/(\bgg\b|good game|well played|\bwp\b)/.test(b)) add('GG 🤝', 'Rematch? ⚔️');
    if (/(won|win|lost|lose|jit|hara)/.test(b)) add('GG, well played 🤝', 'Rematch? ⚔️');
    if (/(when|what time|kati baje|kahile|kun time)/.test(b)) add('Now 🔥', 'In 10 min ⏳', 'Tonight 9pm?');
    if (/(ready|start|join|aau|aija)/.test(b)) add('Ready ✅', 'Joining now 🏃', 'Wait 2 min ⏳');
    if (/(^|\s)(hi|hello|hey|yo|namaste|k cha|k xa|kxa)(\s|!|$)/.test(b)) add('Hey! 👋', 'K cha bro? 😄');
    if (/(screenshot|proof|ss\b)/.test(b)) add('Sending screenshot 📸');
    if (/\?\s*$/.test(b)) add('Yes ✅', 'No ❌', 'Not sure 🤔');
    if (!out.length) {
      if (kind === 'match') add('Room ready ✅', 'Joining now 🏃', 'Wait 2 min ⏳', 'Start? 🔥', 'GG 🤝');
      else if (b) add('😂', '🔥 Let\'s go', '👍 Okay');
    }
    return out.slice(0, 5);
  }
  function smartChips(force) {
    var p = cur; if (!p || p.kind === 'zulu') return;
    if (p.kind === 'jd') { if (msgs.length) $('dm-chips').innerHTML = ''; else chips(['Hi JD team 👋', 'Our squad is ready ✅', 'I need help with points 🪙', 'Room ID problem 🎮']); return; }
    if (p.kind === 'match' && p.status === 'completed') { $('dm-chips').innerHTML = ''; return; }
    if ((p.kind === 'dm' && p.friend === false) || !$('dm-in')) { $('dm-chips').innerHTML = ''; return; }
    var last = null;
    for (var i = msgs.length - 1; i >= 0; i--) { if (msgs[i].kind !== 'system') { last = msgs[i]; break; } }
    var key = (last ? last.id : '-') + '|' + p.kind;
    if (!force && key === chipFor) return;
    if (!force && $('dm-chips').querySelector('[data-fill]')) return; // keep AI ideas until used
    chipFor = key;
    var theirs = last && !last.mine && last.kind !== 'ai' ? last.body : '';
    var extra = '<button type="button" class="ai" data-ai="1">✨ ' + (NE ? 'AI सुझाव' : 'Ideas') + '</button>' +
      (p.kind !== 'dm' ? '<button type="button" class="ai" data-zulu="1">🤖 @zulu</button>' : '');
    chips(smartReplies(theirs, p.kind), extra);
  }
  async function aiIdeas(btn) {
    var p = cur; if (!p) return;
    btn.disabled = true; btn.textContent = '✨ ' + (NE ? 'सोच्दै…' : 'Thinking…');
    var r = null;
    try { r = await SB.functions.invoke('chat-assist', { body: { kind: p.kind, id: p.id } }); } catch (e) {}
    if (cur !== p) return;
    var list = (r && r.data && r.data.replies) || [];
    if (!list.length) { btn.textContent = '😴 ' + ((r && r.data && r.data.note) || 'No ideas right now'); setTimeout(function () { if (cur === p) smartChips(true); }, 2200); return; }
    setChips('<div class="dm-chips">' + list.map(function (t) { return '<button type="button" class="ai" data-fill="1">✨ ' + esc(t) + '</button>'; }).join('') +
      '<button type="button" data-back="1" aria-label="Back to quick replies">✕</button></div>');
  }
  $('dm-chips').addEventListener('click', function (e) {
    var b = e.target.closest('button'); if (!b || b.disabled) return;
    var inp = $('dm-in');
    if (b.dataset.ai) { aiIdeas(b); return; }
    if (b.dataset.back) { smartChips(true); return; }
    if (b.dataset.zulu || b.dataset.fill) {
      if (!inp) return;
      inp.value = b.dataset.zulu ? '@zulu ' + inp.value.replace(/^@zulu\s*/i, '') : b.textContent.replace(/^✨\s*/, '');
      inp.dispatchEvent(new Event('input')); inp.focus();
      try { inp.setSelectionRange(inp.value.length, inp.value.length); } catch (x) {}
      if (b.dataset.fill) smartChips(true);
      return;
    }
    var t = b.textContent;
    if (cur && cur.kind === 'zulu') t = t.replace(/^\S+\s/, '');
    send(t);
  });

  function renderPeer() {
    var p = cur, av = '', name = '', st = '', on = false;
    if (p.kind === 'dm') { av = avatar(p, 'sm'); name = nameOf(p); st = status(p); on = !!p.online; }
    else if (p.kind === 'group') {
      av = groupAv(p, 'sm'); name = p.name;
      var mem = ginfo ? ginfo.members : null, onl = mem ? mem.filter(function (m) { return m.online && !m.me; }).length : 0;
      st = mem ? mem.length + ' ' + T('members') + (onl ? ' · ' + onl + ' online' : '') + (ginfo.muted ? ' · 🔕' : '') : (p.count ? p.count + ' ' + T('members') : '');
      on = onl > 0;
    } else if (p.kind === 'match') {
      av = matchAv('sm'); name = (p.mode || 'Match') + (p.other ? ' vs ' + nameOf(p.other) : '');
      st = p.status === 'completed' ? 'Finished · chat is read-only' : p.status === 'disputed' ? 'Disputed · post your screenshots' : 'Captains’ match chat';
    } else if (p.kind === 'jd') { av = jdAv('sm'); name = 'JD Esports'; st = 'Official JD team · we reply here'; }
    else { av = zuluAv('sm'); name = 'ZULU'; st = 'AI assistant · replies in seconds'; on = true; }
    $('dm-th-av').innerHTML = av;
    $('dm-th-name').textContent = name;
    if (p.kind === 'jd') $('dm-th-name').insertAdjacentHTML('beforeend', ' ' + VERIFIED);
    var s = $('dm-th-st'); s.textContent = st; s.className = on ? 'on' : '';
  }

  // ── fetching a page of messages, normalised to { id, sender, mine, kind, body, created_at, read_at } ──
  async function fetchPage(p, before) {
    if (p.kind === 'dm') {
      var r = await SB.rpc('dm_thread', before ? { p_with: p.id, p_before: before } : { p_with: p.id });
      return r.error ? r : { data: (r.data || []).map(function (m) { return Object.assign({ sender: m.mine ? me : p.id, kind: 'text' }, m); }) };
    }
    if (p.kind === 'jd') {
      var j = await SB.rpc('jd_thread', before ? { p_before: before } : {});
      return j.error ? j : { data: (j.data || []).map(function (m) { return Object.assign({ sender: m.mine ? me : 'jd' }, m, { kind: 'text' }); }) };
    }
    if (p.kind === 'group') {
      var g = await SB.rpc('group_thread', before ? { p_group: p.id, p_before: before } : { p_group: p.id });
      return g;
    }
    var q = SB.from('challenge_messages').select('id, sender, kind, body, created_at').eq('challenge_id', p.id).order('id', { ascending: false }).limit(60);
    if (before) q = q.lt('id', before);
    var c = await q;
    return c.error ? c : { data: (c.data || []).map(function (m) { return Object.assign({ mine: m.sender === me }, m, { kind: m.kind || 'text' }); }) };
  }

  var sig = '';
  async function refreshThread(first) {
    var p = cur; if (!p || p.kind === 'zulu') return;
    if (sending && !first) return;
    if (first || Math.random() < 0.1) await loadMeta(p);
    if (cur !== p) return;
    var r = await fetchPage(p);
    if (cur !== p || r.error || (sending && !first)) return;
    var rows = (r.data || []).slice().reverse();
    if (first) {
      hasOlder = rows.length >= 60;
      msgs = rows;
    } else {
      var byId = {}; rows.forEach(function (m) { byId[m.id] = m; });
      var newest = 0;
      msgs.forEach(function (m) { if (typeof m.id === 'number') { if (byId[m.id]) m.read_at = byId[m.id].read_at; newest = Math.max(newest, m.id); } });
      var fresh = rows.filter(function (m) { return m.id > newest && !msgs.some(function (x) { return x.id === m.id; }); });
      fresh.forEach(function (m) { m.fresh = true; if (m.kind === 'ai') zuluWait = null; });
      var local = msgs.filter(function (m) { return typeof m.id !== 'number'; });
      msgs = msgs.filter(function (m) { return typeof m.id === 'number'; }).concat(fresh, local);
    }
    var s = msgs.map(function (m) { return m.id + (m.read_at ? 'r' : '') + (m.failed ? 'f' : ''); }).join(',') + (ginfo ? '|' + ginfo.members.map(function (x) { return x.read; }).join(',') : '');
    if (zuluWait && Date.now() > zuluWait.until) { zuluWait = null; s += '~'; }
    if (first || s !== sig) { sig = s; renderMsgs(first); }
    smartChips(first);
    // mark read
    var top = 0; rows.forEach(function (m) { if (!m.mine) top = Math.max(top, m.id); });
    if (top > readMark) {
      readMark = top;
      if (p.kind === 'dm') { if (rows.some(function (m) { return !m.mine && !m.read_at; })) { await SB.rpc('dm_mark_read', { p_with: p.id }); poll(); } }
      else if (p.kind === 'group') { await SB.rpc('group_mark_read', { p_group: p.id }); poll(); }
      else if (p.kind === 'jd') { if (rows.some(function (m) { return !m.mine && !m.read_at; })) { await SB.rpc('jd_mark_read'); poll(); } }
      else { await SB.rpc('challenge_mark_read', { p_id: p.id }); poll(); }
    }
  }
  // header details: online status (dm), members (group), the challenge + room (match)
  async function loadMeta(p) {
    if (p.kind === 'dm') {
      var c = await SB.rpc('chat_player', { p_who: p.tag });
      if (c.data && cur === p) {
        var became = p.friend === false && c.data.friend;
        Object.assign(p, { online: c.data.online, seen: c.data.seen, logo: c.data.logo });
        if (became) { p.friend = true; p.req = 'friend'; renderMsgs(false); loadOverview(); }
        renderPeer();
      }
    } else if (p.kind === 'group') {
      var g = await SB.rpc('group_info', { p_group: p.id });
      if (cur !== p) return;
      if (!g.data) { $('dm-foot').innerHTML = '<div class="dm-locked">You\'re not in this squad chat any more.</div>'; stopThread(); return; }
      ginfo = g.data; p.name = g.data.name; p.faces = g.data.members.filter(function (m) { return !m.me; }); renderPeer();
    } else if (p.kind === 'match') {
      var r = await SB.from('challenges').select('id, creator, opponent, mode, stake, status, room_id, room_pass, map, rounds').eq('id', p.id).maybeSingle();
      if (cur !== p) return;
      if (!r.data) { $('dm-msgs').innerHTML = '<div class="dm-empty">This match chat isn\'t available.</div>'; stopThread(); return; }
      var c2 = r.data, otherId = c2.creator === me ? c2.opponent : c2.creator;
      if (!p.other || p.other.id !== otherId) {
        var t = th && th.matches.find(function (x) { return x.id === p.id; });
        p.other = (t && t.other) || null;
        if (!p.other && otherId) { var n = await SB.rpc('get_challenge_names', { p_ids: [otherId] }); var nm = n.data && n.data[0] ? n.data[0].name : 'Opponent'; p.other = { id: otherId, username: nm.replace(/^@/, '') }; }
      }
      var wasStatus = p.status;
      Object.assign(p, { mode: c2.mode, stake: c2.stake, status: c2.status, room_id: c2.room_id, room_pass: c2.room_pass, map: c2.map, rounds: c2.rounds, creator: c2.creator === me });
      renderPeer(); renderPin();
      if (p.status === 'completed' && wasStatus !== 'completed') $('dm-foot').innerHTML = '<div class="dm-locked">The match is finished — this chat is read-only now.</div>';
      smartChips(true);
    }
  }
  // match chat: the room card pinned under the header
  function renderPin() {
    var p = cur; if (!p || p.kind !== 'match') return;
    var rules = [p.stake ? p.stake + ' pts each' : '', p.rounds ? p.rounds + ' rounds' : '', p.map || ''].filter(Boolean).join(' · ');
    var room = p.room_id
      ? '<button type="button" class="dm-copy" data-copy="' + esc(p.room_id) + '"><small>Room ID</small><b>' + esc(p.room_id) + '</b></button>' +
        '<button type="button" class="dm-copy" data-copy="' + esc(p.room_pass || '') + '"><small>Password</small><b>' + esc(p.room_pass || '—') + '</b></button>'
      : '<span class="dm-pin-wait">No room yet — whoever makes the custom room, post it in the challenge.</span>';
    $('dm-pin').innerHTML = '<div class="dm-pin"><div class="dm-pin-top"><span>' + esc(rules) + '</span><a href="/challenges/?c=' + encodeURIComponent(p.id) + '">' + T('openMatch') + ' →</a></div>' +
      '<div class="dm-pin-room">' + room + '</div>' +
      (p.room_id && p.status !== 'completed' ? '<button type="button" class="dm-pin-share" id="dm-share-room">📣 ' + T('shareRoom') + '</button>' : '') + '</div>';
    var sh = $('dm-share-room');
    if (sh) sh.onclick = function () { shareRoom({ id: p.room_id, pass: p.room_pass, label: p.mode + ' vs ' + nameOf(p.other) }); };
  }
  panel.addEventListener('click', function (e) {
    var b = e.target.closest('[data-copy]'); if (b) { copyText(b.dataset.copy, b.querySelector('b') || b); }
  });

  function senderCard(id) {
    if (cur.kind === 'group' && ginfo) { var m = ginfo.members.find(function (x) { return x.id === id; }); if (m) return m; return { id: id, username: 'former member' }; }
    if (cur.kind === 'match') return cur.other && cur.other.id === id ? cur.other : { id: id, username: 'opponent' };
    if (cur.kind === 'jd') return { id: 'jd', username: 'JD Esports' };
    return cur;
  }
  function renderMsgs(jump) {
    var box = $('dm-msgs'), p = cur;
    var nearBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 80;
    var h = '';
    if (hasOlder) h += '<button type="button" class="dm-more" id="dm-older">Load earlier messages</button>';
    else if (p.kind === 'dm') h += '<div class="dm-hello">' + avatar(p) + '<b>' + esc(nameOf(p)) + '</b>' + esc(p.tag || '') + (p.squad ? ' · ' + esc(p.squad) : '') + '<br>' +
      (p.friend !== false ? 'You\'re friends on JD Arena'
        : p.req === 'in' ? esc(nameOf(p)) + ' wants to be friends. Accept to chat freely.<span class="dm-req"><button type="button" class="dm-btn" data-th-accept="1">' + T('accept') + '</button><button type="button" class="dm-btn ghost" data-th-decline="1">' + T('decline') + '</button></span>'
        : 'Not friends yet. ' + (p.req === 'out' ? 'Your request is waiting. ' : 'Sending a message also sends a friend request. ') + 'You can send 3 messages until they accept.') + '</div>';
    else if (p.kind === 'group') h += '<div class="dm-hello">' + groupAv(p) + '<b>' + esc(p.name) + '</b>Squad chat · plan matches, share room IDs<br><span class="dm-hint">Type <b>@zulu</b> + a question and ZULU (AI) answers here. It reads the last few messages.</span></div>';
    else if (p.kind === 'match') h += '<div class="dm-hello">' + matchAv() + '<b>' + esc((p.mode || '') + ' Clash Squad') + '</b>Only you and the other captain can see this chat.<br>Agree the room, play, then report the result on the challenge.<br><span class="dm-hint">Type <b>@zulu</b> to ask ZULU (AI) about the rules. It reads the last few messages.</span></div>';
    else if (p.kind === 'jd') h += '<div class="dm-hello">' + jdAv() + '<b>JD Esports ' + VERIFIED + '</b>The official JD Esports Arena team.<br>Real people from the JD team (moderators and admin) write here. Ask about events, slots, points or room IDs and we reply. For instant answers, ask ZULU.<br><span class="dm-hint">The JD team never asks for your password or eSewa PIN.</span></div>';
    else h += '<div class="dm-hello">' + zuluAv() + '<b>ZULU</b>Your JD Arena buddy. Chat about anything gaming, get Free Fire tips, or ask about tournaments and your own points, tickets and challenges. It never sees your private chats.</div>';
    var lastMine = -1;
    msgs.forEach(function (m, i) { if (m.mine) lastMine = i; });
    for (var i = 0; i < msgs.length; i++) {
      var m = msgs[i], prev = msgs[i - 1], next = msgs[i + 1];
      var t = new Date(m.created_at).getTime();
      var gapBefore = !prev || t - new Date(prev.created_at).getTime() > 15 * 60000;
      if (gapBefore) h += '<div class="dm-time">' + esc(stamp(m.created_at)) + '</div>';
      if (m.kind === 'system') { h += '<div class="dm-sys">' + esc(m.body) + '</div>'; continue; }
      if (m.kind === 'zn') { h += znHtml(m); continue; }
      var same = function (a) { return a && a.kind !== 'system' && a.kind !== 'zn' && a.sender === m.sender && a.mine === m.mine; };
      var head = gapBefore || !same(prev) || t - new Date(prev.created_at).getTime() > 5 * 60000;
      var tail = !next || !same(next) || new Date(next.created_at).getTime() - t > 5 * 60000;
      var room = m.kind === 'room' ? roomOf(m.body) : null;
      var isAi = m.kind === 'ai';
      var who = m.mine ? null : (p.kind === 'zulu' || isAi ? { username: 'ZULU' } : senderCard(m.sender));
      var cls = 'dm-line ' + (m.mine ? 'me' : 'them') + (head ? ' head' : '') + (tail ? ' tail' : '') + (!room && emojiOnly(m.body) ? ' emoji' : '') +
        (room ? ' roomcard' : '') + (isAi ? ' ai' : '') + (m.pending ? ' pending' : '') + (m.failed ? ' failed' : '') + (m.fresh && !reduced() ? ' new' : '');
      if (head && !m.mine && (p.kind === 'group' || isAi)) h += '<div class="dm-from' + (isAi ? ' ai' : '') + '">' + (isAi ? 'ZULU · AI' : esc(nameOf(who))) + '</div>';
      var av = m.mine ? '' : (p.kind === 'zulu' || isAi ? zuluAv('xs') : p.kind === 'jd' ? jdAv('xs') : avatar(who, 'xs'));
      var bubble = room
        ? '<div class="dm-b dm-room"><span class="dm-room-h">🎮 ' + esc(room.label || 'Custom room') + '</span>' +
          '<span class="dm-room-r"><button type="button" class="dm-copy" data-copy="' + esc(room.id) + '"><small>Room ID</small><b>' + esc(room.id) + '</b></button>' +
          '<button type="button" class="dm-copy" data-copy="' + esc(room.pass) + '"><small>Password</small><b>' + esc(room.pass || '—') + '</b></button></span></div>'
        : (p.kind === 'zulu' || isAi) && !m.mine
          ? '<div class="dm-b"' + (m.streaming ? ' id="dm-zs"' : '') + '><span class="dm-zt">' + linkify(m.body) + '</span>' +
            (m.streaming ? '' : '<button type="button" class="dm-say" data-say="1" aria-label="Read aloud" title="Read aloud">🔊</button>') + '</div>'
          : '<div class="dm-b">' + esc(m.body) + '</div>';
      h += '<div class="' + cls + '" title="' + esc(stamp(m.created_at)) + '">' + av + bubble + '</div>';
      if (m.failed) h += '<div class="dm-err">' + esc(m.failed) + ' · <button type="button" class="dm-more" style="margin:0;padding:2px 8px" data-retry="' + esc(m.id) + '">Retry</button></div>';
      else if (i === lastMine && i === msgs.length - 1 && p.kind !== 'zulu') h += '<div class="dm-seen">' + seenLine(m) + '</div>';
      m.fresh = false;
    }
    if ((p.kind === 'zulu' && zuluBusy) || (zuluWait && zuluWait.key === p.kind + p.id && Date.now() < zuluWait.until)) h += '<div class="dm-line them head tail">' + zuluAv('xs') + '<div class="dm-b dm-typing"><i></i><i></i><i></i></div></div>';
    box.innerHTML = h;
    if (jump || nearBottom) box.scrollTop = box.scrollHeight;
    var older = $('dm-older'); if (older) older.onclick = loadOlder;
  }
  // one alert from the notifications table, as a ZULU message (room ID + password copy buttons)
  function znHtml(m) {
    var n = m.n, room = n.room_id ? '<span class="dm-room-r"><button type="button" class="dm-copy" data-copy="' + esc(n.room_id) + '"><small>Room ID</small><b>' + esc(n.room_id) + '</b></button>' +
      '<button type="button" class="dm-copy" data-copy="' + esc(n.room_pass || '') + '"><small>Password</small><b>' + esc(n.room_pass || '—') + '</b></button></span>' : '';
    return '<div class="dm-line them head tail' + (m.fresh && !reduced() ? ' new' : '') + '" title="' + esc(stamp(m.created_at)) + '">' + zuluAv('xs') +
      '<div class="dm-b dm-zn' + (room ? ' dm-room' : '') + '"><span class="dm-zn-k">🔔 Alert' + (n.tournament_slug ? ' · ' + esc(n.tournament_slug) : '') + '</span><b>' + esc(n.title) + '</b>' +
      (n.body ? '<span class="dm-zn-t">' + linkify(n.body) + '</span>' : '') + room + '</div></div>';
  }
  function seenLine(m) {
    if (m.pending) return 'Sending…';
    if (cur.kind === 'dm' || cur.kind === 'jd') return m.read_at ? 'Seen ' + short(m.read_at).replace('now', 'just now') : 'Sent';
    if (cur.kind === 'group' && ginfo && typeof m.id === 'number') {
      var seen = ginfo.members.filter(function (x) { return !x.me && Number(x.read) >= m.id; });
      if (seen.length) return '<span class="dm-seenby" title="' + esc(T('seenBy') + ' ' + seen.map(nameOf).join(', ')) + '">' + seen.slice(0, 5).map(function (x) { return avatar(x, 'xxs'); }).join('') + '</span>';
    }
    return 'Sent';
  }
  // ZULU ends replies with site paths for the next step; each becomes a tap button.
  var PATHS = { '/challenges/': '⚔️ Challenges', '/wallet/': '🪙 Wallet', '/wallet/#load': '💰 Load points', '/events/': '📅 Join a tournament',
    '/leaderboard.html': '🏆 Leaderboard', '/profile/': '👤 Profile', '/chat/': '💬 Chat', '/privacy/': 'Privacy', '/ban-list.html': '🚫 Ban list',
    '/download/': '📲 Get the app', '/pass/': '🎟 Weekly Pass', '/rules/': '📜 Rules', '/optimizer/': '🚀 PC Optimizer' };
  function linkify(s) {
    return esc(s).replace(/\*\*([^*\n]{1,80})\*\*/g, '<b>$1</b>')
      .replace(/(?:https?:\/\/)?(?:www\.)?jdesport\.co\.uk(\/[a-z-]*\/?(?:[a-z-]+\.html)?(?:#[a-z]+)?)/g, function (m, path) { return path; })
      .replace(/(https?:\/\/[^\s<]+[^\s<.,;:!?)'"])/g, '<a href="$1" target="_blank" rel="noopener">$1</a>')
      .replace(/(^|[\s(])(\/(?:[a-z-]+\/(?:#[a-z]+)?|[a-z-]+\.html))(?=[\s.,;:!?)]|$)/g, function (m, pre, path) {
        return pre + '<a class="dm-pathbtn" href="' + path + '">' + (PATHS[path] || path) + ' →</a>';
      });
  }
  window.zuluRender = linkify;

  // 🔊 Read a ZULU reply aloud with the device's own voices (speechSynthesis, on tap only).
  // Devanagari needs a Nepali (ne) or Hindi (hi) voice - phones usually have one, many PCs don't.
  var sayBtn = null;
  function zuluSpeak(text, btn) {
    var ss = window.speechSynthesis;
    if (!ss || typeof SpeechSynthesisUtterance === 'undefined') return 'This browser can\'t read aloud.';
    if (ss.speaking) { ss.cancel(); var was = sayBtn; if (sayBtn) sayBtn.classList.remove('on'); sayBtn = null; if (was === btn) return ''; }
    var clean = String(text || '').replace(/(^|\s)\/[a-z-]+\/?(?:[a-z-]+\.html)?(?:#[a-z]+)?(?=\s|$)/g, ' ')
      .replace(/https?:\/\/\S+/g, ' ').replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]/gu, '').replace(/\s+/g, ' ').trim();
    if (!clean) return '';
    var deva = /[ऀ-ॿ]/.test(clean), voices = ss.getVoices() || [];
    var pick = function (re) { return voices.find(function (v) { return re.test(v.lang); }); };
    var v = deva ? (pick(/^ne/i) || pick(/^hi/i)) : (pick(/^en-IN/i) || pick(/^en/i));
    if (deva && !v) return 'No Nepali voice on this device - try ZULU on your phone.';
    var u = new SpeechSynthesisUtterance(clean);
    if (v) { u.voice = v; u.lang = v.lang; }
    u.rate = 1;
    u.onend = u.onerror = function () { if (btn) btn.classList.remove('on'); if (sayBtn === btn) sayBtn = null; };
    if (btn) btn.classList.add('on');
    sayBtn = btn;
    ss.speak(u);
    return '';
  }
  window.zuluSpeak = zuluSpeak;
  if (window.speechSynthesis) try { speechSynthesis.getVoices(); } catch (e) {}

  // ZULU reply as it streams in (stream:true): calls onText(textSoFar) for each piece and resolves
  // with the full reply. JSON answers (limits, caps, errors) resolve with their reply or null.
  async function zuluFetch(body, onText) {
    var base = (SB.supabaseUrl || 'https://cnoxvqvpmgowdiyrrusv.supabase.co') + '/functions/v1/zulu-ai-reply';
    body.stream = true;
    var res = await fetch(base, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    if (!res.ok) return null;
    if ((res.headers.get('content-type') || '').indexOf('application/json') >= 0) { var d = await res.json(); return d && d.reply; }
    if (!res.body || !window.TextDecoder) { var t = await res.text(); if (onText && t) onText(t); return t || null; }
    var reader = res.body.getReader(), dec = new TextDecoder(), full = '';
    for (;;) {
      var r = await reader.read();
      if (r.done) break;
      full += dec.decode(r.value, { stream: true });
      if (onText && full) onText(full);
    }
    full += dec.decode();
    return full.trim() || null;
  }
  window.zuluFetch = zuluFetch;
  // follow-up questions after a ZULU answer (local, no AI quota)
  function zuluFollowups(q, a) {
    var t = (q + ' ' + a).toLowerCase(), out = [];
    var add = function () { for (var i = 0; i < arguments.length; i++) if (out.indexOf(arguments[i]) < 0 && arguments[i].toLowerCase().indexOf(q.toLowerCase()) < 0) out.push(arguments[i]); };
    if (/(point|wallet|esewa|balance|withdraw|load)/.test(t)) add('💰 How do I load points?', '🏧 How do I withdraw?');
    if (/(challenge|clash|1v1|2v2|pot|stake)/.test(t)) add('⚔️ How does the pot work?', '🏳️ What if both say they won?');
    if (/(tournament|register|join|room)/.test(t)) add('📝 How do I join?', '🎮 When do I get the room ID?');
    if (/(rank|leaderboard|points work|placement|kill)/.test(t)) add('🏆 How do points work?');
    if (/(cheat|hack|report|ban)/.test(t)) add('🚩 How do I report a cheater?');
    add('🏆 Next tournament?', '🎯 Free Fire tips');
    return out.slice(0, 4);
  }
  // a short summary of the player's own account for ZULU (only the ZULU chat sends it)
  var acctCache = null, acctAt = 0;
  async function zuluAccount() {
    if (!me) return '';
    if (acctCache != null && Date.now() - acctAt < 30000) return acctCache;
    var lines = [];
    try {
      var r = await Promise.all([
        SB.from('wallets').select('balance, unlimited').eq('player_id', me).maybeSingle(),
        SB.from('registrations').select('tournament_slug, status, checked_in_at').eq('player_id', me).order('created_at', { ascending: false }).limit(5),
        th ? Promise.resolve(null) : SB.rpc('chat_threads'),
        SB.from('notifications').select('title, body, created_at, tournament_slug, room_id, room_pass').eq('player_id', me).order('created_at', { ascending: false }).limit(8),
        SB.rpc('my_weekly_pass'),
        SB.rpc('my_contact'),
        SB.rpc('my_pc_reports')
      ]);
      if (myCard) lines.push('Me: ' + (myCard.username ? '@' + myCard.username : '') + ' ' + (myCard.player_tag || '') + (myCard.squad_name ? ', squad "' + myCard.squad_name + '"' : ''));
      var wp = r[4] && r[4].data;
      lines.push(wp && wp.tier ? 'My Weekly Pass: ' + (wp.tier === 'pro' ? 'Weekly Pro' : 'Weekly Pass') + (wp.active_now ? ' active' : ' bought, starts ' + String(wp.starts_at || '').slice(0, 10)) + ' until ' + String(wp.expires_at || '').slice(0, 16).replace('T', ' ') + ' UTC'
        : 'My Weekly Pass: none (free tournaments are still free to join; from 27 Oct a prize won without a pass pays 50 points for one; jdesport.co.uk/pass)');
      var w = r[0].data; if (w) lines.push('Points balance: ' + (w.unlimited ? 'unlimited (admin)' : (w.balance || 0) + ' JD points'));
      var tours = (tourCache && tourCache.tournaments) || [];
      (r[1].data || []).forEach(function (g) {
        var t = tours.find(function (x) { return x.name === g.tournament_slug; }) || {};
        var ms = Date.parse(t.start), left = ms - Date.now(), when = '';
        if (ms && left > 0) when = ', starts in ' + (left > 864e5 ? Math.round(left / 864e5) + ' day(s)' : left > 36e5 ? Math.round(left / 36e5) + ' h' : Math.round(left / 6e4) + ' min');
        var conf = g.status === 'no_show' ? '' : g.checked_in_at ? ', confirmed playing' : (ms && left > 0 ? ', NOT confirmed yet ("Confirm you\'re playing" opens 48 h and closes 24 h before start)' : '');
        lines.push('My ticket: ' + g.tournament_slug + ' (' + (g.status === 'no_show' ? 'no-show, did not play' : g.status) + ')' + (t.date ? ', ' + t.date + ' ' + (t.time || '') : '') + when + conf + (t.status ? ', event ' + t.status : ''));
      });
      var ct = r[5] && r[5].data;
      lines.push(ct && ct.whatsapp && myCard && myCard.squad_name ? 'One-tap join: ready (squad, device and WhatsApp saved - just tick the rules and Confirm & join)'
        : 'One-tap join: not set up yet (the first registration saves squad, device and WhatsApp)');
      var mt = ((th || (r[2] && r[2].data) || {}).matches) || [];
      if (!mt.length) lines.push('My challenges: none open right now (a 1v1 Clash Squad challenge with 20 points pays up to 38 to the winner)');
      var ua = navigator.userAgent || '', inApp = false;
      try { inApp = !!sessionStorage.getItem('jd_twa') || /^android-app:\/\/uk\.co\.jdesport\.arena/.test(document.referrer); } catch (e) {}
      lines.push('My device: ' + (inApp ? 'Android, using the JD Arena app (notifications on the app)'
        : /Android/i.test(ua) ? 'Android phone in the browser or old web version - the JD Arena Android app is NOT in use (suggest /download/ for real app notifications)'
        : /iPhone|iPad|iPod/.test(ua) ? 'iPhone/iPad (no Android app; the home-screen web app gets alerts)' : 'computer'));
      mt.forEach(function (m) { lines.push('My challenge: ' + m.mode + ' vs ' + nameOf(m.other) + ', ' + m.status + ', ' + m.stake + ' pts each' + (m.status !== 'completed' ? (m.room_id ? ', room posted' : ', no room posted yet') : '')); });
      ((r[3] && r[3].data) || []).forEach(function (n) {
        if (n.room_id && Date.now() - Date.parse(n.created_at) < 864e5)      // own room details, last 24 h
          lines.push('My room for ' + (n.tournament_slug || 'my match') + ': Room ID ' + n.room_id + (n.room_pass ? ', password ' + n.room_pass : ''));
        var b = String(n.body || ''); if (b.indexOf('TICKET::') === 0) b = '';
        lines.push('My notification (' + String(n.created_at || '').slice(0, 16).replace('T', ' ') + ' UTC): ' + String(n.title || '').slice(0, 90) + (b ? ' — ' + b.slice(0, 220) : ''));
      });
      ((r[6] && r[6].data) || []).slice(0, 2).forEach(function (x) {
        var pc = x.pc || {}, l = x.last || {};
        lines.push('My PC (JD-Optimiers, private to me + admin): ' + (pc.cpu || '?') + ', ' + (pc.gpu || '?') + ', ' + (pc.ram_gb || '?') + ' GB RAM, PC score ' +
          (pc.score != null ? pc.score : '?') + '/100 (' + (pc.tier || '?') + '). Last session: FPS ' + (l.fps != null ? l.fps : '?') + ', 1% low ' +
          (l.low1 != null ? l.low1 : '?') + ', cap ' + (l.cap || '?') + (l.stable != null && l.stable >= 0 ? ', Stable ' + l.target + ' ' + l.stable + '%' : '') +
          ', renderer ' + (l.renderer || '?') + ', ' + (l.res || '') + (l.hint ? '. Likely reason for drops: ' + l.hint : ''));
      });
      if (ov) lines.push('Friends: ' + ov.friends.length + (ov.incoming.length ? ', ' + ov.incoming.length + ' friend request(s) waiting' : ''));
    } catch (e) {}
    acctCache = lines.join('\n'); acctAt = Date.now();
    return acctCache;
  }
  $('dm-msgs').addEventListener('click', async function (e) {
    var a = e.target.closest('[data-th-accept],[data-th-decline]');
    if (a && cur && cur.kind === 'dm') {
      var p = cur, yes = !!a.dataset.thAccept; a.disabled = true;
      var rr = await SB.rpc('respond_friend_request', { p_from: p.id, p_accept: yes });
      if (rr.error) { a.disabled = false; return; }
      if (yes) { p.friend = true; p.req = 'friend'; renderMsgs(false); } else { showHome(); }
      loadOverview(); poll();
      return;
    }
    var say = e.target.closest('[data-say]');
    if (say) {
      var tx = say.parentNode.querySelector('.dm-zt'), err = zuluSpeak(tx ? tx.textContent : '', say);
      if (err && !say.nextElementSibling) {
        say.insertAdjacentHTML('afterend', '<span class="dm-sayerr">' + esc(err) + '</span>');
        setTimeout(function () { var n = say.nextElementSibling; if (n && n.className === 'dm-sayerr') n.remove(); }, 4000);
      }
      return;
    }
    var b = e.target.closest('[data-retry]'); if (!b) return;
    var m = msgs.find(function (x) { return String(x.id) === b.dataset.retry; });
    if (m) { msgs.splice(msgs.indexOf(m), 1); send(m.body); }
  });

  async function loadOlder() {
    var p = cur, first = msgs.find(function (m) { return typeof m.id === 'number'; });
    if (!p || !first) return;
    var box = $('dm-msgs'), h0 = box.scrollHeight;
    var r = await fetchPage(p, first.id);
    if (cur !== p || r.error) return;
    var rows = (r.data || []).slice().reverse();
    hasOlder = rows.length >= 60;
    msgs = rows.concat(msgs);
    renderMsgs(false);
    box.scrollTop = box.scrollHeight - h0;
  }

  async function send(text, kind) {
    var inp = $('dm-in'), p = cur;
    var body = (text != null ? text : (inp ? inp.value : '')).trim();
    if (!body || !p || sending) return;
    if (p.kind === 'match' && p.status === 'completed') return;
    if (text == null && inp) { inp.value = ''; inp.dispatchEvent(new Event('input')); }
    if (p.kind === 'zulu') return askZulu(body);
    var m = { id: 't' + (++tmp), mine: true, sender: me, kind: kind || 'text', body: body, created_at: new Date().toISOString(), pending: true, fresh: true };
    msgs.push(m); renderMsgs(true);
    sending = true;
    var r;
    if (p.kind === 'dm' && p.friend === false && p.req === 'none') {
      var fq = await SB.rpc('send_friend_request', { p_who: p.username || p.tag });
      if (!fq.error) { p.req = fq.data === 'accepted' || fq.data === 'already' ? 'friend' : 'out'; if (p.req === 'friend') p.friend = true; loadOverview(); }
    }
    if (p.kind === 'dm') r = await SB.rpc('send_dm', { p_to: p.id, p_body: body });
    else if (p.kind === 'group') r = await SB.rpc('send_group_message', { p_group: p.id, p_body: body, p_kind: kind || 'text' });
    else if (p.kind === 'jd') r = await SB.rpc('jd_send', { p_body: body });
    else r = await SB.rpc('send_challenge_message', { p_id: p.id, p_body: body });
    sending = false;
    if (cur !== p) return;
    m.pending = false;
    if (r.error) {
      m.failed = r.error.message || 'Not sent';
      if (/only message your friends/i.test(m.failed)) { p.friend = false; $('dm-foot').innerHTML = '<div class="dm-locked">You can\'t message this player.</div>'; }
      renderMsgs(true); return;
    }
    if (p.kind !== 'dm' && p.kind !== 'jd' && MENTION.test(body)) {
      zuluWait = { key: p.kind + p.id, until: Date.now() + 30000 };
      setTimeout(function () { if (cur === p && zuluWait) { sig += '~'; refreshThread(); } }, 30500);
    }
    if (p.kind === 'match') { msgs.splice(msgs.indexOf(m), 1); await refreshThread(); SB.rpc('challenge_mark_read', { p_id: p.id }); return; }
    m.id = Number(r.data);
    msgs = msgs.filter(function (x) { return x === m || x.id !== m.id; });
    if (p.kind === 'group') readMark = Math.max(readMark, m.id);
    renderMsgs(true);
  }

  // ── ZULU (AI) — history kept on this device, last 40 lines ──
  var zuluBusy = false;
  function zuluLoad() {
    var chat = (store.get('jd_zulu_dm') || []).map(function (z, i) { return { id: 'z' + i, mine: z.role === 'user', kind: 'text', body: z.content, created_at: z.at || new Date().toISOString() }; });
    var alerts = zn.slice(0, 25).map(function (n) { return { id: 'n' + n.id, mine: false, kind: 'zn', n: n, body: n.title, created_at: n.created_at }; });
    var feed = zf.map(function (m) { return { id: 'f' + m.id, mine: false, kind: 'text', body: m.body, created_at: m.created_at }; });
    return alerts.concat(feed, chat).sort(function (a, b) { return new Date(a.created_at) - new Date(b.created_at); });
  }
  var zuluAsking = false;                              // whole question, incl. while the reply streams in
  async function askZulu(q) {
    if (zuluBusy || zuluAsking) return;
    zuluAsking = true;
    try { await askZulu1(q); } finally { zuluAsking = false; }
  }
  async function askZulu1(q) {
    var hist = store.get('jd_zulu_dm') || [];
    hist.push({ role: 'user', content: q.slice(0, 500), at: new Date().toISOString() });
    store.set('jd_zulu_dm', hist.slice(-40));
    zuluBusy = true; msgs = zuluLoad(); msgs[msgs.length - 1].fresh = true; renderMsgs(true);
    var reply = null, local = null;
    if (typeof window.zuluLocalAnswer === 'function') { try { local = await window.zuluLocalAnswer(q); } catch (e) {} }
    if (local && local.text) reply = local.text;
    else try {
      var account = await zuluAccount(), live = null;
      reply = await zuluFetch({ message: q, lang: NE ? 'ne' : 'en', account: account,
        history: hist.slice(-9, -1).map(function (h) { return { role: h.role, content: h.content }; }) }, function (text) {
        if (!cur || cur.kind !== 'zulu') return;
        if (!live) {                                     // first words: swap the typing dots for the reply
          zuluBusy = false;
          live = { id: 'zs', mine: false, kind: 'text', body: text, created_at: new Date().toISOString(), fresh: true, streaming: true };
          msgs = zuluLoad(); msgs.push(live); renderMsgs(true);
        } else {
          var el = $('dm-zs'), box = $('dm-msgs');
          if (el) { el.firstChild.innerHTML = linkify(text); box.scrollTop = box.scrollHeight; }
        }
      });
    } catch (e) {}
    if (!reply && local && local.fallback) reply = local.fallback;
    if (!reply) reply = NE
      ? 'माफ गर्नुहोस्, ZULU अहिले व्यस्त छ। केही बेरपछि फेरि सोध्नुहोस्, वा होमपेजमा Ask ZULU प्रयोग गर्नुहोस्।'
      : 'Sorry, I\'m a bit busy right now. Try again in a minute — or check /events/ for tournaments and /challenges/ for Clash Squad challenges.';
    hist = store.get('jd_zulu_dm') || [];
    hist.push({ role: 'assistant', content: String(reply).slice(0, 2000), at: new Date().toISOString() });
    store.set('jd_zulu_dm', hist.slice(-40));
    zuluBusy = false;
    if (cur && cur.kind === 'zulu') { msgs = zuluLoad(); msgs[msgs.length - 1].fresh = true; renderMsgs(true); chips(zuluFollowups(q, String(reply))); }
    else if (isOpen) renderOverview();
  }

  // ── sheets: options, new squad chat, members, share room ──
  function closeSheet() { var s = $('dm-sheet'); if (s) s.classList.remove('open'); }
  function sheet(html) { $('dm-sheet-in').innerHTML = html; $('dm-sheet').classList.add('open'); var f = $('dm-sheet-in').querySelector('input:not([type=checkbox]),textarea'); if (f && !phone()) setTimeout(function () { f.focus(); }, 50); }
  $('dm-sheet').addEventListener('click', function (e) { if (e.target === this) closeSheet(); });
  var cancelBtn = function () { return '<button type="button" class="dm-btn ghost" data-a="close">' + T('cancel') + '</button>'; };

  function friendPicker(exclude, max) {
    var fr = (ov ? ov.friends : []).filter(function (f) { return exclude.indexOf(f.id) < 0; });
    if (!fr.length) return '<p>No friends to add yet — add your teammates by username or JD tag first.</p>';
    return '<div class="dm-pickl" data-max="' + max + '">' + fr.map(function (f) {
      return '<label class="dm-pk">' + avatar(f, 'sm') + '<span class="dm-mid"><span class="dm-name">' + esc(nameOf(f)) + '</span><span class="dm-prev"><span>' + esc(f.squad || f.tag || '') + '</span></span></span><input type="checkbox" value="' + esc(f.id) + '"><i class="dm-ck" aria-hidden="true"></i></label>';
    }).join('') + '</div>';
  }
  function picked() { return Array.prototype.map.call($('dm-sheet-in').querySelectorAll('.dm-pickl input:checked'), function (x) { return x.value; }); }
  $('dm-sheet-in').addEventListener('change', function (e) {
    var l = e.target.closest('.dm-pickl'); if (!l) return;
    var max = Number(l.dataset.max) || 7;
    if (picked().length > max) { e.target.checked = false; var n = $('dm-sheet-note'); if (n) n.textContent = 'Up to ' + max + ' more players (8 per squad chat).'; }
  });

  async function newSquadSheet() {
    if (!ov) await loadOverview();
    if (!isOpen) open();
    var def = (myCard && myCard.squad_name) || '';
    sheet('<h3>👥 ' + T('newSquad') + '</h3><p>Pick up to 7 friends — your Clash Squad team. Everyone can chat, share room IDs and add their own friends.</p>' +
      '<input class="dm-field" id="dm-gname" maxlength="40" placeholder="Squad chat name" value="' + esc(def) + '">' +
      friendPicker([], 7) + '<div class="dm-sheet-note" id="dm-sheet-note"></div>' +
      '<div class="dm-row2">' + cancelBtn() + '<button type="button" class="dm-btn" data-a="create-group">' + T('create') + '</button></div>');
  }

  $('dm-menu').onclick = function () {
    var p = cur; if (!p) return;
    if (p.kind === 'dm') {
      var n = esc(nameOf(p));
      sheet('<h3>' + n + '</h3>' +
        (p.username ? '<button type="button" class="dm-opt" data-a="challenge">⚔️ Challenge ' + n + ' to a match</button>' : '') +
        '<button type="button" class="dm-opt" data-a="squad-with">👥 Start a squad chat with ' + n + '</button>' +
        '<button type="button" class="dm-opt" data-a="remove">👋 Remove friend</button>' +
        '<button type="button" class="dm-opt red" data-a="block">⛔ Block ' + n + '</button>' +
        '<button type="button" class="dm-opt red" data-a="report">🚩 Report ' + n + '</button>' +
        '<button type="button" class="dm-opt" data-a="close">' + T('cancel') + '</button>');
    } else if (p.kind === 'jd') {
      sheet('<h3>JD Esports ' + VERIFIED + '</h3>' +
        '<a class="dm-opt" href="/events/">🏆 Events and your tickets</a>' +
        '<a class="dm-opt" href="/wallet/">🪙 Wallet · load points</a>' +
        '<a class="dm-opt" href="/rules/">📜 Tournament rules</a>' +
        '<button type="button" class="dm-opt" data-a="close">' + T('cancel') + '</button>');
    } else if (p.kind === 'group') {
      sheet('<h3>' + esc(p.name) + '</h3>' +
        '<button type="button" class="dm-opt" data-a="members">👥 Members' + (ginfo ? ' (' + ginfo.members.length + ')' : '') + '</button>' +
        '<button type="button" class="dm-opt" data-a="add-members">➕ Add friends</button>' +
        '<button type="button" class="dm-opt" data-a="rename">✏️ Rename</button>' +
        '<button type="button" class="dm-opt" data-a="mute">' + (ginfo && ginfo.muted ? '🔔 Unmute notifications' : '🔕 Mute notifications') + '</button>' +
        '<button type="button" class="dm-opt" data-a="challenge-any">⚔️ Make a Clash Squad challenge</button>' +
        '<button type="button" class="dm-opt red" data-a="leave">🚪 Leave squad chat</button>' +
        '<button type="button" class="dm-opt" data-a="close">' + T('cancel') + '</button>');
    } else if (p.kind === 'match') {
      var o = p.other ? esc(nameOf(p.other)) : 'opponent';
      sheet('<h3>' + esc((p.mode || '') + ' vs ') + o + '</h3>' +
        '<a class="dm-opt" href="/challenges/?c=' + encodeURIComponent(p.id) + '">⚔️ ' + T('openMatch') + ' (report result, room)</a>' +
        (p.room_id ? '<button type="button" class="dm-opt" data-a="share-room">📣 ' + T('shareRoom') + '</button>' : '') +
        (p.other && p.other.username ? '<button type="button" class="dm-opt" data-a="connect">💬 Message or add ' + o + ' as a friend</button>' : '') +
        '<button type="button" class="dm-opt" data-a="close">' + T('cancel') + '</button>');
    } else {
      sheet('<h3>ZULU</h3><p>ZULU is an AI assistant; answers can be wrong. Your ZULU chat is stored only on this device. Messages you send it go to our AI providers (see /privacy/).</p>' +
        '<button type="button" class="dm-opt red" data-a="zulu-clear">🧹 Clear ZULU chat</button><button type="button" class="dm-opt" data-a="close">' + T('cancel') + '</button>');
    }
  };
  $('dm-who').onclick = function () { if (cur && cur.kind === 'group') $('dm-menu').click(); };

  $('dm-sheet-in').addEventListener('click', async function (e) {
    var b = e.target.closest('[data-a]'); if (!b) return;
    var a = b.dataset.a, p = cur, r;
    if (a === 'close') return closeSheet();
    if (a === 'create-group') {
      var ids = picked(), nm = ($('dm-gname').value || '').trim();
      if (!ids.length) { $('dm-sheet-note').textContent = 'Pick at least one friend.'; return; }
      if (!nm) nm = ids.length === 1 ? 'Duo' : 'Squad';
      b.disabled = true;
      r = await SB.rpc('create_group_chat', { p_name: nm, p_members: ids });
      if (r.error) { b.disabled = false; $('dm-sheet-note').textContent = r.error.message; return; }
      closeSheet(); await loadOverview(); openGroup(r.data); return;
    }
    if (a === 'squad-with') {
      if (!p) return;
      await newSquadSheet();
      var cb = $('dm-sheet-in').querySelector('input[value="' + p.id + '"]'); if (cb) cb.checked = true;
      return;
    }
    if (a === 'challenge') { location.href = '/challenges/?invite=' + encodeURIComponent(p.username); return; }
    if (a === 'challenge-any') { location.href = '/challenges/'; return; }
    if (a === 'connect') { closeSheet(); connect(p.other.username); return; }
    if (a === 'share-room') { shareRoom({ id: p.room_id, pass: p.room_pass, label: p.mode + ' vs ' + nameOf(p.other) }); return; }
    if (a === 'new-from-share') { newSquadSheet(); return; }
    if (a === 'zulu-clear') { store.set('jd_zulu_dm', []); closeSheet(); msgs = []; renderMsgs(true); return; }
    if (a === 'members') {
      if (!ginfo) return;
      return sheet('<h3>Members · ' + ginfo.members.length + '/8</h3><div class="dm-pickl">' + ginfo.members.map(function (m) {
        var act = m.me ? '<span class="dm-prev">' + T('you') + '</span>' : m.friend ? '<button type="button" class="dm-btn ghost" data-a="dm-member" data-id="' + esc(m.id) + '">Message</button>' : (m.username ? '<button type="button" class="dm-btn ghost" data-a="friend-member" data-u="' + esc(m.username) + '">Add friend</button>' : '');
        return '<div class="dm-pk">' + avatar(m, 'sm') + '<span class="dm-mid"><span class="dm-name">' + esc(nameOf(m)) + '</span><span class="dm-prev"><span>' + esc(m.online ? T('now') : (m.squad || m.tag || '')) + '</span></span></span>' + act + '</div>';
      }).join('') + '</div><div class="dm-row2"><button type="button" class="dm-btn ghost" data-a="add-members">➕ Add friends</button><button type="button" class="dm-btn" data-a="close">Done</button></div>');
    }
    if (a === 'dm-member') { closeSheet(); openWith(b.dataset.id); return; }
    if (a === 'friend-member') { closeSheet(); connect(b.dataset.u); return; }
    if (a === 'add-members') {
      if (!ginfo) return;
      var left = 8 - ginfo.members.length;
      if (left < 1) return sheet('<h3>Squad chat is full</h3><p>A squad chat can have up to 8 players.</p><div class="dm-row2"><button type="button" class="dm-btn" data-a="close">OK</button></div>');
      return sheet('<h3>➕ Add friends to ' + esc(p.name) + '</h3>' + friendPicker(ginfo.members.map(function (m) { return m.id; }), left) +
        '<div class="dm-sheet-note" id="dm-sheet-note"></div><div class="dm-row2">' + cancelBtn() + '<button type="button" class="dm-btn" data-a="add-yes">' + T('add') + '</button></div>');
    }
    if (a === 'add-yes') {
      var add = picked(); if (!add.length) { $('dm-sheet-note').textContent = 'Pick at least one friend.'; return; }
      b.disabled = true;
      r = await SB.rpc('add_group_members', { p_group: p.id, p_members: add });
      if (r.error) { b.disabled = false; $('dm-sheet-note').textContent = r.error.message; return; }
      closeSheet(); await loadMeta(p); refreshThread(); return;
    }
    if (a === 'rename') return sheet('<h3>✏️ Rename</h3><input class="dm-field" id="dm-rn" maxlength="40" value="' + esc(p.name) + '"><div class="dm-sheet-note" id="dm-sheet-note"></div><div class="dm-row2">' + cancelBtn() + '<button type="button" class="dm-btn" data-a="rename-yes">Save</button></div>');
    if (a === 'rename-yes') {
      b.disabled = true;
      r = await SB.rpc('rename_group_chat', { p_group: p.id, p_name: $('dm-rn').value });
      if (r.error) { b.disabled = false; $('dm-sheet-note').textContent = r.error.message; return; }
      closeSheet(); await loadMeta(p); refreshThread(); return;
    }
    if (a === 'mute') { await SB.rpc('mute_group_chat', { p_group: p.id, p_muted: !(ginfo && ginfo.muted) }); closeSheet(); await loadMeta(p); poll(); return; }
    if (a === 'leave') return sheet('<h3>Leave ' + esc(p.name) + '?</h3><p>You\'ll stop getting its messages. A friend in the chat can add you back.</p><div class="dm-row2">' + cancelBtn() + '<button type="button" class="dm-btn danger" data-a="leave-yes">Leave</button></div>');
    if (a === 'leave-yes') { b.disabled = true; await SB.rpc('leave_group_chat', { p_group: p.id }); closeSheet(); note('You left ' + p.name + '.', 'ok'); showHome(); poll(); return; }
    if (a === 'room-to') {
      b.disabled = true;
      r = await SB.rpc('send_group_message', { p_group: b.dataset.g, p_body: shareBody, p_kind: 'room' });
      if (r.error) { b.disabled = false; $('dm-sheet-note').textContent = r.error.message; return; }
      closeSheet(); openGroup(b.dataset.g); return;
    }
    // friend actions (dm)
    var n = esc(nameOf(p));
    if (a === 'remove') return sheet('<h3>Remove ' + n + '?</h3><p>You won\'t be able to message each other until one of you adds the other again. Your chat history stays.</p><div class="dm-row2">' + cancelBtn() + '<button type="button" class="dm-btn danger" data-a="remove-yes">Remove</button></div>');
    if (a === 'block') return sheet('<h3>Block ' + n + '?</h3><p>They won\'t be able to message you or send you friend requests, and they disappear from your chats. You can unblock them under Requests.</p><div class="dm-row2">' + cancelBtn() + '<button type="button" class="dm-btn danger" data-a="block-yes">Block</button></div>');
    if (a === 'report') return sheet('<h3>Report ' + n + '</h3><p>Tell the admin what happened (abuse, scams, cheating). Your report is private.</p><textarea id="dm-rep" maxlength="600" placeholder="What happened?"></textarea><div class="dm-row2">' + cancelBtn() + '<button type="button" class="dm-btn danger" data-a="report-yes">Send report</button></div>');
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

  // ── ⚙️ alert settings: which phone alerts you get (push_prefs; history is unaffected) ──
  var PREFS = [
    ['dm', '💬', 'Direct messages', 'When a friend messages you'],
    ['squad', '👥', 'Squad chats', 'New messages in your squad chats (mute one chat from its ⋯ menu)'],
    ['match', '⚔️', 'Match chats', 'The other captain writes in your challenge chat'],
    ['challenges', '🎯', 'Challenge invites & results', 'Someone challenges you or accepts, and win/loss/refund results. "Confirm your result" deadlines and disputes always alert'],
    ['lobby', '🔥', 'New open challenges', 'Someone posts a challenge anyone can accept'],
    ['friends', '🤝', 'Friend requests & squad invites', 'Someone adds you or puts you in a squad chat'],
    ['wallet', '🪙', 'Wallet', 'Points loaded, withdrawals paid, prizes']
  ];
  async function settingsSheet() {
    if (!me) return;
    if (!isOpen) open();
    sheet('<h3>🔔 Alert settings</h3><div class="dm-skel"><i></i><i></i></div>');
    var r = await SB.rpc('get_push_prefs');
    var off = (r.data && r.data.off) || [], daily = !(r.data && r.data.daily_challenge_alert === false);
    var perm = typeof Notification === 'function' ? Notification.permission : 'unsupported';
    var sw = function (k, on, label) { return '<span class="dm-sw"><input type="checkbox" data-pref="' + k + '"' + (on ? ' checked' : '') + ' aria-label="' + esc(label) + '"><i aria-hidden="true"></i></span>'; };
    var warn = perm === 'granted' ? '' : '<p class="dm-warn">' + (perm === 'denied'
      ? '🚫 Alerts are blocked for this site in your browser or phone settings. Allow notifications there to get them.'
      : '📲 Alerts aren&#39;t on for this device yet. Open 🔔 Notifications on the homepage and tap Turn on.') + '</p>';
    sheet('<h3>🔔 Alert settings</h3>' + warn +
      '<p>Choose which phone alerts you get. Switched-off alerts still show in your notifications and chats.</p>' +
      '<div class="dm-prefs">' + PREFS.map(function (x) {
        return '<label class="dm-pref"><span class="dm-pref-ic" aria-hidden="true">' + x[1] + '</span><span class="dm-mid"><b>' + x[2] + '</b><small>' + x[3] + '</small></span>' + sw(x[0], off.indexOf(x[0]) < 0, x[2]) + '</label>';
      }).join('') +
      '<label class="dm-pref"><span class="dm-pref-ic" aria-hidden="true">⏰</span><span class="dm-mid"><b>Daily challenge reminder</b><small>One alert a day at 6 pm with the open challenges</small></span>' + sw('daily', daily, 'Daily challenge reminder') + '</label>' +
      '<div class="dm-pref locked"><span class="dm-pref-ic" aria-hidden="true">🏆</span><span class="dm-mid"><b>Tournaments & account</b><small>Match reminders, room ID and password, results and security alerts are always on, so you never miss your match.</small></span><span class="dm-on">Always on</span></div>' +
      '</div><div class="dm-sheet-note" id="dm-sheet-note"></div><div class="dm-row2"><button type="button" class="dm-btn" data-a="close">Done</button></div>');
  }
  $('dm-sheet-in').addEventListener('change', async function (e) {
    var k = e.target.dataset && e.target.dataset.pref; if (!k) return;
    var on = e.target.checked, r;
    e.target.disabled = true;
    if (k === 'daily') r = await SB.rpc('set_daily_challenge_alert', { p_on: on });
    else r = await SB.rpc('set_push_pref', { p_type: k, p_on: on });
    e.target.disabled = false;
    if (r.error) { e.target.checked = !on; var n = $('dm-sheet-note'); if (n) n.textContent = r.error.message; }
  });

  // "Share room to squad": post a room card (ID + password, tap to copy) into one of your squad chats
  var shareBody = '';
  async function shareRoom(o) {
    if (!me || !o || !o.id) return;
    shareBody = ['ROOM', String(o.id).replace(/\|/g, ''), String(o.pass || '').replace(/\|/g, ''), String(o.label || 'Custom room').replace(/\|/g, '/')].join('|').slice(0, 500);
    if (!isOpen) open();
    if (!th) await loadOverview();
    var gs = (th && th.groups) || [];
    sheet('<h3>📣 ' + T('shareRoom') + '</h3><p>Post room <b>' + esc(o.id) + '</b> to a squad chat so your teammates can copy the ID and password.</p>' +
      (gs.length ? '<div class="dm-pickl">' + gs.map(function (g) {
        return '<button type="button" class="dm-pk" data-a="room-to" data-g="' + esc(g.id) + '">' + groupAv(g, 'sm') + '<span class="dm-mid"><span class="dm-name">' + esc(g.name) + '</span><span class="dm-prev"><span>' + g.count + ' ' + T('members') + '</span></span></span><span class="dm-btn">Send</span></button>';
      }).join('') + '</div>' : '<p>You don\'t have a squad chat yet.</p><div class="dm-row2"><button type="button" class="dm-btn" data-a="new-from-share">👥 ' + T('newSquad') + '</button></div>') +
      '<div class="dm-sheet-note" id="dm-sheet-note"></div><div class="dm-row2">' + cancelBtn() + '</div>');
  }

  // ── login state (the homepage logs in/out in place) ──
  SB.auth.getSession().then(function (r) { setUser(r && r.data && r.data.session ? r.data.session.user : null); });
  SB.auth.onAuthStateChange(function (_ev, session) { setUser(session ? session.user : null); });

  // deep links: /?dm=<JD tag> (message push), /?g=<squad chat> (squad push), /?chat=1 (friend/squad notifications)
  try {
    var q = new URLSearchParams(location.search), dm = q.get('dm'), g = q.get('g'), ch = q.get('chat'), jdq = q.get('jd'), zq = q.get('zulu');
    if (dm || g || ch || jdq || zq) {
      q.delete('dm'); q.delete('g'); q.delete('chat'); q.delete('jd'); q.delete('zulu');
      history.replaceState(history.state, '', location.pathname + (q.toString() ? '?' + q : '') + location.hash);
      if (jdq) pendingDeepLink = openJd;
      else if (zq) pendingDeepLink = function () { openZulu(); };
      else if (dm) pendingDeepLink = function () { openWith(dm); };
      else if (g && /^[0-9a-f-]{36}$/i.test(g)) pendingDeepLink = function () { openGroup(g); };
      else setTimeout(function () { if (me) open(); }, 800);
    }
  } catch (e) {}

  // "Message / add friend" buttons elsewhere (challenge room): chat if already friends, else send the request
  async function connect(who) {
    if (!me) return;
    who = String(who || '').replace(/[^A-Za-z0-9_-]/g, '');
    if (!who) return;
    var r = await SB.rpc('chat_player', { p_who: who });
    if (r.data && r.data.friend) { if (!isOpen) open(); openThread(Object.assign({ kind: 'dm' }, r.data)); return; }
    var q = await SB.rpc('send_friend_request', { p_who: who });
    if (cur) showHome();
    open();
    if (q.error) { note(q.error.message, 'err'); return; }
    if (q.data === 'accepted') { note('You\'re friends now — say hi! 👋', 'ok'); if (r.data) { r.data.friend = true; openThread(Object.assign({ kind: 'dm' }, r.data)); } return; }
    note(q.data === 'pending' ? 'Request already sent — waiting for @' + who + '.' : 'Friend request sent to @' + who + '. You can chat once they accept.', 'ok');
    tab = 'requests'; loadOverview();
  }

  window.jdChat = { settings: settingsSheet, open: open, close: close, openWith: openWith, openGroup: openGroup, openMatch: openMatch, openZulu: openZulu, connect: connect, shareRoom: shareRoom };
})();
