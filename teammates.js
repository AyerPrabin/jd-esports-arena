// Find Teammates. Full page: /squad/ (#squad-page). Home: a short preview (#teammates) that links there.
// Data: supabase/teammate_finder.sql (lfg_list / lfg_post / lfg_delete / lfg_contact / lfg_pay).
// "Add friend" = a friend request carrying the post's context; once they accept, "Message" opens the chat.
// Fees are JD points only (wallet to wallet, after you're friends), never eSewa between players.
(function () {
  var PAGE = document.getElementById('squad-page'), HOME = document.getElementById('teammates');
  var root = PAGE || HOME;
  var SB = typeof sb !== 'undefined' ? sb : null;
  if (!root) return;
  if (!SB) { if (HOME) HOME.hidden = true; return; }
  var list = document.getElementById('tm-list');
  var ROLES = [['rusher', '⚡ Rusher'], ['sniper', '🎯 Sniper'], ['supporter', '🛡 Supporter'], ['igl', '🧠 IGL'], ['bomber', '💣 Bomber'], ['all-rounder', '🌟 All-rounder']];
  var ROLE_LBL = {}; ROLES.forEach(function (r) { ROLE_LBL[r[0]] = r[1]; });
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var qs = new URLSearchParams(location.search);
  var posts = [], me = null, event = qs.get('event') || null, kind = 'all', role = '', freeOnly = false, q = '', armed = null, editing = null;

  async function loadMe() {
    var s = (await SB.auth.getSession()).data.session;
    if (!s) { me = null; return; }
    var r = await SB.from('players').select('id, username, ff_uid, ff_name').eq('id', s.user.id).maybeSingle();
    me = r.data || { id: s.user.id };
  }
  function signIn(post) {
    if (HOME && typeof authOpen === 'function') authOpen('login');
    else location.href = '/?signin=1&next=' + encodeURIComponent('/squad/' + (post ? '?post=1' + (event ? '&event=' + encodeURIComponent(event) : '') : location.search));
  }
  var tourList = null;
  async function upcoming() {
    if (!tourList) {
      var d = typeof _lastData !== 'undefined' && _lastData;
      if (!d) { try { d = await (await fetch('/tournaments.json', { cache: 'no-cache' })).json(); } catch (e) { d = {}; } }
      tourList = ((d && d.tournaments) || []).filter(function (t) {
        var st = String(t.status || 'upcoming').toLowerCase(), ms = Date.parse(t.start);
        return (st === 'upcoming' || st === 'live') && !String(t.winner || '').trim() && (!isFinite(ms) || ms > Date.now() - 3 * 3600e3);
      }).map(function (t) { return t.name; });
    }
    return tourList;
  }

  async function load() {
    var r = await SB.rpc('lfg_list', { p_tournament: event });
    posts = r.error ? [] : (r.data || []);
    render();
  }

  // ── one card (same markup on both pages; the page CSS lays it out) ──
  function relBtn(p) {
    if (p.mine) return '<button type="button" class="tm-btn ghost" data-edit="' + p.id + '">✏️ Edit</button><button type="button" class="tm-btn ghost" data-del="' + p.id + '">Delete</button>';
    var b = p.rel === 'friend' ? '<button type="button" class="tm-btn ghost" data-msg="' + esc(p.username) + '">💬 Message</button>'
      : p.rel === 'sent' ? '<button type="button" class="tm-btn ghost" disabled>✓ Requested</button>'
      : p.rel === 'received' ? '<button type="button" class="tm-btn" data-up="' + p.id + '">✓ Accept</button>'
      : '<button type="button" class="tm-btn" data-up="' + p.id + '">➕ Add friend</button>';
    if (p.pay === 'paid' && p.rel === 'friend') b += '<button type="button" class="tm-btn gold" data-pay="' + p.id + '">' + (armed === p.id ? 'Tap again: pay ' + esc(p.amount) : '🪙 Pay ' + esc(p.amount)) + '</button>';
    return b;
  }
  function card(p) {
    var roles = (p.roles || []).map(function (r) { return '<span class="tm-role' + (ROLE_LBL[r] ? ' r-' + r : '') + '">' + esc(ROLE_LBL[r] || r) + '</span>'; }).join('');
    var av = p.logo ? '<img src="' + esc(p.logo) + '" alt="" loading="lazy">' : esc(String(p.username || '?').charAt(0).toUpperCase());
    return '<article class="tm-card' + (p.mine ? ' mine' : '') + '" data-id="' + p.id + '">' +
      '<div class="tm-top"><span class="tm-av">' + av + '</span>' +
        '<div class="tm-who"><b>@' + esc(p.username) + (p.mine ? ' <small>(you)</small>' : '') + '</b><span>🎮 ' + esc(p.ign) + '</span></div>' +
        (p.pay === 'paid' ? '<span class="tm-pay paid">🪙 ' + esc(p.amount) + ' pts</span>' : '<span class="tm-pay">Free</span>') + '</div>' +
      '<div class="tm-kind ' + esc(p.kind) + '">' + (p.kind === 'player' ? '🙋 Looking for a squad' : '👥 Squad needs a player') + ' · ' + (p.tournament ? esc(p.tournament) : 'Any event') + '</div>' +
      '<div class="tm-roles">' + roles + '</div>' + (p.note ? '<p class="tm-note">' + esc(p.note) + '</p>' : '') +
      (p.uid ? '<button type="button" class="tm-uid" data-copy="' + esc(p.uid) + '">UID ' + esc(p.uid) + ' <span>⧉ Copy</span></button>' : '') +
      '<div class="tm-acts">' + relBtn(p) + '</div></article>';
  }
  function match(p) {
    if (kind !== 'all' && p.kind !== kind) return false;
    if (freeOnly && p.pay !== 'free') return false;
    if (role && (p.roles || []).indexOf(role) < 0) return false;
    if (q) {
      var hay = [p.username, p.ign, p.note, p.tournament].concat(p.roles || []).join(' ').toLowerCase();
      if (q.split(/\s+/).some(function (w) { return hay.indexOf(w) < 0; })) return false;
    }
    return true;
  }
  function render() {
    if (PAGE) {
      document.getElementById('sq-count').textContent = posts.length ? posts.filter(function (p) { return !p.mine; }).length + ' looking now' : '';
      var ev = document.getElementById('tm-event');
      ev.hidden = !event;
      ev.innerHTML = event ? '🏆 <b>' + esc(event) + '</b> <button type="button" data-clear="1" aria-label="Show every event">✕</button>' : '';
      document.querySelectorAll('[data-kind]').forEach(function (b) { b.setAttribute('aria-pressed', String(b.dataset.kind === kind)); });
      document.querySelectorAll('[data-role]').forEach(function (b) { b.setAttribute('aria-pressed', String(b.dataset.role === role)); });
      document.getElementById('sq-free').setAttribute('aria-pressed', String(freeOnly));
      var mine = posts.find(function (p) { return p.mine; });
      document.getElementById('sq-fab').innerHTML = mine ? '✏️ <span>Edit my post</span>' : '＋ <span>Post yourself</span>';
      var shown = posts.filter(match);
      list.innerHTML = shown.length ? shown.map(card).join('')
        : posts.length ? '<div class="tm-empty">No one matches that.<button type="button" class="tm-btn ghost" data-reset="1">Clear filters</button></div>'
        : '<div class="tm-empty"><b>No one is looking yet.</b>Post your role and squads will find you.<button type="button" class="tm-btn" data-post="1">＋ Post yourself</button></div>';
    } else {
      var top = posts.slice(0, 8);
      list.innerHTML = top.length ? top.map(card).join('') + '<a class="tm-more" href="/squad/">See all<br><b>' + posts.length + '</b> players →</a>'
        : '<div class="tm-empty">No one here yet. <a href="/squad/#post">Post your role</a> and squads will find you.</div>';
    }
  }
  var toastT;
  function msg(t, bad) {
    var m = document.getElementById('tm-msg'); if (!m) return;
    m.textContent = t || ''; m.className = 'tm-msg' + (bad ? ' bad' : '') + (t ? ' show' : '');
    clearTimeout(toastT); if (t && PAGE) toastT = setTimeout(function () { m.className = 'tm-msg'; }, 3500);
  }
  function openChat(u) {
    if (window.jdChat && jdChat.openWith) jdChat.openWith('@' + u);
    else location.href = '/chat/';
  }
  function needGameId() {
    if (!me) { signIn(); return true; }
    if (!me.ff_uid || !me.ff_name) {
      if (HOME && typeof authOpen === 'function') authOpen('gameid'); else compose();
      return true;
    }
    return false;
  }

  root.addEventListener('click', async function (e) {
    var b = e.target.closest('button'); if (!b || b.disabled) return;
    var id, p;
    if (b.dataset.kind) { kind = b.dataset.kind; render(); return; }
    if (b.dataset.role != null) { role = role === b.dataset.role ? '' : b.dataset.role; render(); return; }
    if (b.id === 'sq-free') { freeOnly = !freeOnly; render(); return; }
    if (b.dataset.reset) { kind = 'all'; role = ''; freeOnly = false; q = ''; var si = document.getElementById('sq-q'); if (si) si.value = ''; render(); return; }
    if (b.dataset.clear) { event = null; history.replaceState(null, '', location.pathname + location.hash); load(); return; }
    if (b.dataset.copy) { try { await navigator.clipboard.writeText(b.dataset.copy); msg('UID copied. Add them in Free Fire.'); } catch (x) {} return; }
    if (b.dataset.post || b.id === 'sq-fab') { var m0 = posts.find(function (x) { return x.mine; }); compose(m0); return; }
    if (b.dataset.msg) { openChat(b.dataset.msg); return; }
    if ((id = +b.dataset.edit)) { if (HOME) { location.href = '/squad/#post'; return; } compose(posts.find(function (x) { return x.id === id; })); return; }
    if ((id = +b.dataset.del)) { b.disabled = true; await SB.rpc('lfg_delete', { p_id: id }); msg('Post removed.'); load(); return; }
    if ((id = +b.dataset.up)) {
      if (needGameId()) return;
      b.disabled = true;
      var r = await SB.rpc('lfg_contact', { p_id: id });
      b.disabled = false;
      if (r.error) { msg(r.error.message, true); return; }
      p = posts.find(function (x) { return x.id === id; });
      if (r.data === 'sent' || r.data === 'pending') { p.rel = 'sent'; msg('Friend request sent to @' + p.username + '. You can chat once they accept.'); }
      else { p.rel = 'friend'; msg(r.data === 'accepted' ? 'You’re friends with @' + p.username + ' now. Say hi! 👋' : 'Opening your chat…'); openChat(p.username); }
      render();
      return;
    }
    if ((id = +b.dataset.pay)) {
      if (needGameId()) return;
      if (armed !== id) { armed = id; render(); setTimeout(function () { if (armed === id) { armed = null; render(); } }, 4000); return; }
      armed = null; b.disabled = true;
      p = posts.find(function (x) { return x.id === id; });   // pay exactly the fee shown on the card
      var pr = await SB.rpc('lfg_pay', { p_id: id, p_amount: p ? p.amount : null });
      if (pr.error) { msg(pr.error.message, true); load(); return; }
      msg('Paid ✓ Your balance: ' + pr.data + ' pts');
      if (typeof loadWallet === 'function') loadWallet();
      render();
    }
  });
  var sq = document.getElementById('sq-q');
  if (sq) sq.addEventListener('input', function () { q = sq.value.trim().toLowerCase(); render(); });

  // ── post / edit sheet (full page only) ──
  var ov = document.getElementById('tm-overlay'), form = document.getElementById('tm-form');
  async function compose(p) {
    if (!ov) { location.href = '/squad/#post'; return; }
    if (!me) { signIn(true); return; }
    editing = p || null;
    if (!me.ff_uid || !me.ff_name) {   // game ID first: UID + in-game name are on every card
      form.dataset.mode = 'gameid';
      form.innerHTML = '<div class="tm-grab" aria-hidden="true"></div><button type="button" class="tm-x" data-x="1" aria-label="Close">×</button>' +
        '<h3>Add your Free Fire ID</h3><p class="tm-fine">Squads see your in-game name and UID on your card, so they can add you in Free Fire.</p>' +
        '<label class="tm-lbl" for="tm-uidin">Free Fire UID</label><input id="tm-uidin" inputmode="numeric" maxlength="13" autocomplete="off" placeholder="Numbers on your Free Fire profile" value="' + esc(me.ff_uid || '') + '">' +
        '<label class="tm-lbl" for="tm-ignin">In-game name</label><input id="tm-ignin" maxlength="30" autocomplete="off" placeholder="Your name in Free Fire" value="' + esc(me.ff_name || '') + '">' +
        '<div class="tm-msg" id="tm-fmsg" role="status"></div><button type="submit" class="tm-btn big">Save and continue</button>';
      ov.classList.add('open'); return;
    }
    form.dataset.mode = 'post';
    p = p || { kind: 'player', roles: [], pay: 'free', amount: null, tournament: event || '', note: '' };
    var custom = (p.roles || []).filter(function (r) { return !ROLE_LBL[r]; }).join(', ');
    var evs = (await upcoming()).slice();
    if (p.tournament && evs.indexOf(p.tournament) < 0) evs.unshift(p.tournament);
    form.innerHTML = '<div class="tm-grab" aria-hidden="true"></div><button type="button" class="tm-x" data-x="1" aria-label="Close">×</button>' +
      '<h3>' + (editing ? 'Edit your post' : 'Find a teammate') + '</h3>' +
      '<div class="tm-seg"><label><input type="radio" name="tm-kind" value="player"' + (p.kind === 'player' ? ' checked' : '') + '><span>🙋 I need a squad</span></label>' +
      '<label><input type="radio" name="tm-kind" value="squad"' + (p.kind === 'squad' ? ' checked' : '') + '><span>👥 My squad needs a player</span></label></div>' +
      '<label class="tm-lbl">Your role (pick any)</label><div class="tm-pick">' + ROLES.map(function (r) {
        return '<label><input type="checkbox" name="tm-role" value="' + r[0] + '"' + ((p.roles || []).indexOf(r[0]) >= 0 ? ' checked' : '') + '><span>' + r[1] + '</span></label>';
      }).join('') + '</div>' +
      '<input id="tm-custom" maxlength="64" placeholder="Your own role, e.g. Grenade king, Flanker" value="' + esc(custom) + '">' +
      '<label class="tm-lbl" for="tm-ev">Event</label><select id="tm-ev"><option value="">Any event</option>' + evs.map(function (n) {
        return '<option value="' + esc(n) + '"' + (n === p.tournament ? ' selected' : '') + '>' + esc(n) + '</option>'; }).join('') + '</select>' +
      '<label class="tm-lbl">Play for</label><div class="tm-seg"><label><input type="radio" name="tm-pay" value="free"' + (p.pay !== 'paid' ? ' checked' : '') + '><span>Free</span></label>' +
      '<label><input type="radio" name="tm-pay" value="paid"' + (p.pay === 'paid' ? ' checked' : '') + '><span>🪙 JD points</span></label></div>' +
      '<input id="tm-amt" type="number" inputmode="numeric" min="1" max="5000" placeholder="Fee in JD points (1-5000)" value="' + esc(p.amount || '') + '"' + (p.pay === 'paid' ? '' : ' hidden') + '>' +
      '<p class="tm-fine" id="tm-payfine"' + (p.pay === 'paid' ? '' : ' hidden') + '>Fees are paid in JD points inside the app only, never by eSewa between players.</p>' +
      '<label class="tm-lbl" for="tm-note">Note</label><textarea id="tm-note" maxlength="160" rows="2" placeholder="e.g. KD 3.2, mic on, free after 8pm">' + esc(p.note) + '</textarea>' +
      '<p class="tm-fine">Your card shows <b>' + esc(me.ff_name) + '</b> and UID <b>' + esc(me.ff_uid) + '</b>. It stays up for 7 days.</p>' +
      '<div class="tm-msg" id="tm-fmsg" role="status"></div><button type="submit" class="tm-btn big">' + (editing ? 'Save' : 'Post') + '</button>';
    ov.classList.add('open');
  }
  if (form) {
    form.addEventListener('change', function (e) {
      if (e.target.name !== 'tm-pay') return;
      var paid = e.target.value === 'paid';
      document.getElementById('tm-amt').hidden = !paid; document.getElementById('tm-payfine').hidden = !paid;
    });
    form.addEventListener('submit', async function (e) {
      e.preventDefault();
      var f = this, m = document.getElementById('tm-fmsg'), btn = f.querySelector('button[type=submit]');
      if (f.dataset.mode === 'gameid') {
        var uid = document.getElementById('tm-uidin').value.replace(/\s/g, ''), ign = document.getElementById('tm-ignin').value.trim();
        if (!/^[0-9]{6,13}$/.test(uid)) { m.textContent = 'Enter your Free Fire UID: 6-13 numbers (Free Fire > tap your profile picture > UID).'; return; }
        if (!ign || ign.length > 30) { m.textContent = 'Enter your Free Fire in-game name.'; return; }
        btn.disabled = true;
        var g = await SB.rpc('set_my_game_id', { p_uid: uid, p_name: ign });
        btn.disabled = false;
        if (g.error) { m.textContent = g.error.message; return; }
        me.ff_uid = uid; me.ff_name = ign; compose(editing); return;
      }
      var v = function (n) { var x = f.querySelector('input[name="' + n + '"]:checked'); return x && x.value; };
      var roles = [].map.call(f.querySelectorAll('input[name="tm-role"]:checked'), function (x) { return x.value; })
        .concat(document.getElementById('tm-custom').value.split(',').map(function (s) { return s.trim(); }).filter(Boolean));
      if (!roles.length) { m.textContent = 'Pick at least one role.'; return; }
      btn.disabled = true;
      var r = await SB.rpc('lfg_post', { p_kind: v('tm-kind'), p_roles: roles.slice(0, 5), p_pay: v('tm-pay'),
        p_amount: v('tm-pay') === 'paid' ? (parseInt(document.getElementById('tm-amt').value, 10) || 0) : null,
        p_tournament: document.getElementById('tm-ev').value, p_note: document.getElementById('tm-note').value });
      btn.disabled = false;
      if (r.error) { m.textContent = r.error.message; return; }
      if (editing && editing.id !== r.data) await SB.rpc('lfg_delete', { p_id: editing.id });   // moved to another event: posts are one per event
      ov.classList.remove('open'); msg(editing ? 'Post updated.' : 'You’re on the board! Squads can add you now.'); load();
    });
    ov.addEventListener('click', function (e) { if (e.target === ov || e.target.closest('[data-x]')) ov.classList.remove('open'); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') ov.classList.remove('open'); });
  }

  // 👥 on a home event card: that event's players, on the full page
  window.tmFor = function (name) { location.href = '/squad/' + (name ? '?event=' + encodeURIComponent(name) : ''); };
  loadMe().then(function () {
    load().then(function () { if (PAGE && (location.hash === '#post' || /[?&]post=1/.test(location.search))) { history.replaceState(null, '', location.pathname + location.search.replace(/[?&]post=1/, '').replace(/^&/, '?')); compose(posts.find(function (x) { return x.mine; })); } });
  });
  SB.auth.onAuthStateChange(function (ev) { if (ev === 'SIGNED_IN' || ev === 'SIGNED_OUT') setTimeout(function () { loadMe().then(load); }, 300); });
})();
