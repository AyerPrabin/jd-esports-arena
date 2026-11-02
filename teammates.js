// Find Teammate board on the home page (#teammates). Data: supabase/teammate_finder.sql
// (lfg_list / lfg_post / lfg_delete / lfg_contact / lfg_pay). Needs home.js globals: sb, _player, _lastData,
// effectiveStatus, authOpen, loadWallet, lang. "Team up" = friend request with the post's context, then the
// chat opens in 💬 Messages. Paid posts are paid in JD points only (wallet to wallet), never eSewa.
(function () {
  var list = document.getElementById('tm-list');
  if (!list || typeof sb === 'undefined' || !sb) { var s = document.getElementById('teammates'); if (s) s.hidden = true; return; }
  var ROLES = [['rusher', '⚡ Rusher'], ['sniper', '🎯 Sniper'], ['supporter', '🛡 Supporter'], ['igl', '🧠 IGL'], ['bomber', '💣 Bomber'], ['all-rounder', '🌟 All-rounder']];
  var ROLE_LBL = {}; ROLES.forEach(function (r) { ROLE_LBL[r[0]] = r[1]; });
  var NE = function () { return typeof lang !== 'undefined' && lang === 'ne'; };
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var posts = [], event = null, filter = 'all', armed = null, editing = null;

  function me() { return typeof _player !== 'undefined' ? _player : null; }
  function needGameId() {
    var p = me();
    if (!p) { authOpen('login'); return true; }
    if (!p.ff_uid || !p.ff_name) { authOpen('gameid'); return true; }
    return false;
  }
  function upcoming() {
    var d = typeof _lastData !== 'undefined' && _lastData;
    return ((d && d.tournaments) || []).filter(function (t) { var s = effectiveStatus(t); return s === 'upcoming' || s === 'live'; });
  }

  async function load() {
    var r = await sb.rpc('lfg_list', { p_tournament: event });
    posts = r.error ? [] : (r.data || []);
    render();
  }
  function chips() {
    var F = [['all', NE() ? 'सबै' : 'All'], ['player', NE() ? 'स्क्वाड खोज्दै' : 'Needs a squad'], ['squad', NE() ? 'खेलाडी चाहियो' : 'Needs a player'], ['free', 'Free'], ['paid', '🪙 Paid']];
    document.getElementById('tm-chips').innerHTML = F.map(function (f) {
      return '<button type="button" class="tm-chip' + (filter === f[0] ? ' on' : '') + '" data-f="' + f[0] + '">' + f[1] + '</button>';
    }).join('');
    var ev = document.getElementById('tm-event');
    ev.hidden = !event;
    ev.innerHTML = event ? '👥 ' + (NE() ? 'प्रतियोगिता: ' : 'For ') + '<b>' + esc(event) + '</b> <button type="button" data-clear="1">✕ ' + (NE() ? 'सबै देखाउनुहोस्' : 'Show all') + '</button>' : '';
  }
  function card(p) {
    var roles = (p.roles || []).map(function (r) { return '<span class="tm-role' + (ROLE_LBL[r] ? ' r-' + r : '') + '">' + esc(ROLE_LBL[r] || r) + '</span>'; }).join('');
    var pay = p.pay === 'paid' ? '<span class="tm-pay paid">🪙 ' + esc(p.amount) + ' pts</span>' : '<span class="tm-pay">Free</span>';
    var av = p.logo ? '<img src="' + esc(p.logo) + '" alt="">' : esc(String(p.username || '?').charAt(0).toUpperCase());
    var acts = p.mine
      ? '<button type="button" class="tm-btn ghost" data-del="' + p.id + '">' + (NE() ? 'हटाउनुहोस्' : 'Delete') + '</button><button type="button" class="tm-btn ghost" data-edit="' + p.id + '">' + (NE() ? 'सम्पादन' : 'Edit') + '</button>'
      : '<button type="button" class="tm-btn" data-up="' + p.id + '">👥 ' + (NE() ? 'टिम बनाउनुहोस्' : 'Team up') + '</button>' +
        (p.pay === 'paid' ? '<button type="button" class="tm-btn gold" data-pay="' + p.id + '">' + (armed === p.id ? (NE() ? 'फेरि थिच्नुहोस्: ' : 'Tap again: pay ') + esc(p.amount) + ' pts' : '🪙 ' + (NE() ? 'तिर्नुहोस्' : 'Pay')) + '</button>' : '');
    return '<article class="tm-card' + (p.mine ? ' mine' : '') + '">' +
      '<div class="tm-top"><span class="tm-av">' + av  + '</span>' +
      '<div class="tm-who"><b>@' + esc(p.username) + '</b><span>🎮 ' + esc(p.ign) + '</span>' + (p.uid ? '<button type="button" class="tm-uid" data-copy="' + esc(p.uid) + '" title="Copy UID">UID ' + esc(p.uid) + ' ⧉</button>' : '') + '</div>' + pay + '</div>' +
      '<div class="tm-kind ' + p.kind + '">' + (p.kind === 'player' ? (NE() ? 'स्क्वाड खोज्दै' : 'Looking for a squad') : (NE() ? 'स्क्वाडलाई खेलाडी चाहियो' : 'Squad needs a player')) +
      (p.tournament ? ' · ' + esc(p.tournament) : ' · ' + (NE() ? 'जुनसुकै प्रतियोगिता' : 'Any event')) + '</div>' +
      '<div class="tm-roles">' + roles + '</div>' + (p.note ? '<p class="tm-note">' + esc(p.note) + '</p>' : '') +
      '<div class="tm-acts">' + acts + '</div></article>';
  }
  function render() {
    chips();
    var shown = posts.filter(function (p) { return filter === 'all' || p.kind === filter || p.pay === filter; });
    list.innerHTML = shown.length ? shown.map(card).join('')
      : '<div class="tm-empty">' + (NE() ? 'अहिले कोही छैन। पहिलो पोस्ट गर्नुहोस्!' : 'No one here yet. Be the first to post: tell squads your role.') + '</div>';
  }
  function msg(t, bad) { var m = document.getElementById('tm-msg'); m.textContent = t || ''; m.className = 'tm-msg' + (bad ? ' bad' : ''); }

  document.getElementById('teammates').addEventListener('click', async function (e) {
    var b = e.target.closest('button'); if (!b) return;
    var id;
    if (b.dataset.f) { filter = b.dataset.f; render(); return; }
    if (b.dataset.clear) { event = null; load(); return; }
    if (b.dataset.copy) { try { await navigator.clipboard.writeText(b.dataset.copy); b.textContent = '✓ Copied'; } catch (x) {} return; }
    if (b.id === 'tm-post') { compose(); return; }
    if ((id = +b.dataset.edit)) { compose(posts.find(function (p) { return p.id === id; })); return; }
    if ((id = +b.dataset.del)) { b.disabled = true; await sb.rpc('lfg_delete', { p_id: id }); load(); return; }
    if ((id = +b.dataset.up)) {
      if (needGameId()) return;
      b.disabled = true;
      var r = await sb.rpc('lfg_contact', { p_id: id });
      b.disabled = false;
      if (r.error) { msg(r.error.message, true); return; }
      var p = posts.find(function (x) { return x.id === id; });
      msg({ sent: 'Request sent to @' + p.username + '. You can chat once they accept.', pending: 'Already asked: waiting for @' + p.username + '.',
        accepted: 'You\'re friends now. Say hi! 👋', friend: 'Opening your chat…' }[r.data] || '');
      if (window.jdChat && (r.data === 'friend' || r.data === 'accepted')) jdChat.openWith('@' + p.username);
      return;
    }
    if ((id = +b.dataset.pay)) {
      if (needGameId()) return;
      if (armed !== id) { armed = id; render(); setTimeout(function () { if (armed === id) { armed = null; render(); } }, 4000); return; }
      armed = null; b.disabled = true;
      var pp = posts.find(function (x) { return x.id === id; });   // pay exactly the fee shown on the card
      var q = await sb.rpc('lfg_pay', { p_id: id, p_amount: pp ? pp.amount : null });
      if (q.error) { msg(q.error.message, true); load(); return; }
      msg('Paid ✓ Your balance: ' + q.data + ' pts');
      if (typeof loadWallet === 'function') loadWallet();
      render();
    }
  });

  // ── post / edit sheet ──
  var ov = document.getElementById('tm-overlay');
  function compose(p) {
    if (needGameId()) return;
    editing = p || null;
    p = p || { kind: 'player', roles: [], pay: 'free', amount: null, tournament: event || '', note: '' };
    var custom = (p.roles || []).filter(function (r) { return !ROLE_LBL[r]; }).join(', ');
    var evs = upcoming().map(function (t) { return t.name; });
    if (p.tournament && evs.indexOf(p.tournament) < 0) evs.unshift(p.tournament);
    var u = me();
    document.getElementById('tm-form').innerHTML =
      '<button type="button" class="fb-x tm-x" data-x="1" aria-label="Close">×</button><h3>' + (NE() ? 'टिममेट पोस्ट' : 'Find a teammate') + '</h3>' +
      '<div class="tm-seg"><label><input type="radio" name="tm-kind" value="player"' + (p.kind === 'player' ? ' checked' : '') + '><span>🙋 I need a squad</span></label>' +
      '<label><input type="radio" name="tm-kind" value="squad"' + (p.kind === 'squad' ? ' checked' : '') + '><span>👥 My squad needs a player</span></label></div>' +
      '<label class="tm-lbl">Role (pick any)</label><div class="tm-pick">' + ROLES.map(function (r) {
        return '<label><input type="checkbox" name="tm-role" value="' + r[0] + '"' + ((p.roles || []).indexOf(r[0]) >= 0 ? ' checked' : '') + '><span>' + r[1] + '</span></label>';
      }).join('') + '</div>' +
      '<input id="tm-custom" maxlength="64" placeholder="Your own role, e.g. Grenade king, Flanker" value="' + esc(custom) + '">' +
      '<label class="tm-lbl">Event</label><select id="tm-ev"><option value="">Any event</option>' + evs.map(function (n) {
        return '<option value="' + esc(n) + '"' + (n === p.tournament ? ' selected' : '') + '>' + esc(n) + '</option>'; }).join('') + '</select>' +
      '<label class="tm-lbl">Play for</label><div class="tm-seg"><label><input type="radio" name="tm-pay" value="free"' + (p.pay !== 'paid' ? ' checked' : '') + '><span>Free</span></label>' +
      '<label><input type="radio" name="tm-pay" value="paid"' + (p.pay === 'paid' ? ' checked' : '') + '><span>🪙 JD points</span></label></div>' +
      '<input id="tm-amt" type="number" inputmode="numeric" min="1" max="5000" placeholder="Fee in JD points (1-5000)" value="' + esc(p.amount || '') + '"' + (p.pay === 'paid' ? '' : ' hidden') + '>' +
      '<p class="tm-fine" id="tm-payfine"' + (p.pay === 'paid' ? '' : ' hidden') + '>Fees are paid in JD points inside the app only, never by eSewa between players. Only accept points sent in JD Arena.</p>' +
      '<label class="tm-lbl">Note</label><textarea id="tm-note" maxlength="160" rows="2" placeholder="e.g. KD 3.2, mic on, free after 8pm">' + esc(p.note) + '</textarea>' +
      '<p class="tm-fine">Your card shows <b>' + esc(u.ff_name) + '</b> and UID <b>' + esc(u.ff_uid) + '</b> so players can add you in Free Fire. It stays up for 7 days.</p>' +
      '<div class="tm-msg" id="tm-fmsg"></div><button type="submit" class="btn-primary" style="width:100%">' + (NE() ? 'पोस्ट गर्नुहोस्' : 'Post') + '</button>';
    ov.classList.add('open');
  }
  document.getElementById('tm-form').addEventListener('change', function (e) {
    if (e.target.name !== 'tm-pay') return;
    var paid = e.target.value === 'paid';
    document.getElementById('tm-amt').hidden = !paid; document.getElementById('tm-payfine').hidden = !paid;
  });
  document.getElementById('tm-form').addEventListener('submit', async function (e) {
    e.preventDefault();
    var f = this, v = function (n) { var x = f.querySelector('input[name="' + n + '"]:checked'); return x && x.value; };
    var roles = [].map.call(f.querySelectorAll('input[name="tm-role"]:checked'), function (x) { return x.value; })
      .concat(document.getElementById('tm-custom').value.split(',').map(function (s) { return s.trim(); }).filter(Boolean));
    var btn = f.querySelector('button[type=submit]'), m = document.getElementById('tm-fmsg');
    if (!roles.length) { m.textContent = 'Pick at least one role.'; return; }
    btn.disabled = true;
    var r = await sb.rpc('lfg_post', { p_kind: v('tm-kind'), p_roles: roles.slice(0, 5), p_pay: v('tm-pay'),
      p_amount: v('tm-pay') === 'paid' ? (parseInt(document.getElementById('tm-amt').value, 10) || 0) : null,
      p_tournament: document.getElementById('tm-ev').value, p_note: document.getElementById('tm-note').value });
    btn.disabled = false;
    if (r.error) { m.textContent = r.error.message; return; }
    // moved to another event: the old post goes (posts are one per event)
    if (editing && editing.id !== r.data) await sb.rpc('lfg_delete', { p_id: editing.id });
    ov.classList.remove('open'); load();
  });
  ov.addEventListener('click', function (e) { if (e.target === ov || e.target.closest('[data-x]')) ov.classList.remove('open'); });

  // 👥 on an event card: that event's posts
  window.tmFor = function (name) {
    event = name || null; filter = 'all'; load();
    document.getElementById('teammates').scrollIntoView({ behavior: 'smooth', block: 'start' });
  };
  load();
  sb.auth.onAuthStateChange(function (ev) { if (ev === 'SIGNED_IN' || ev === 'SIGNED_OUT') setTimeout(load, 300); });
})();
