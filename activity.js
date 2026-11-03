/* Player activity timeline for staff (mod panel + admin). Data comes from mod-panel { action: 'chat_player_activity' }.
   jdActivity(box, fetcher, removeAvatar?): fetcher() resolves to { player, events }; removeAvatar(reason) deletes their
   profile picture (staff). Everything printed is escaped. */
(function () {
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var ICON = { money: '💰', event: '🎮', challenge: '⚔️', withdraw: '🏦', promo: '🎬', alert: '🔔' };
  var LABEL = { all: 'All', money: 'Money', event: 'Events', challenge: 'Challenges', withdraw: 'Withdrawals', promo: 'Promo', alert: 'Alerts' };
  var css = '.jda{text-align:left;margin-top:10px}.jda-top{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 8px}.jda-top span{font-size:.74rem;padding:4px 9px;border-radius:999px;border:1px solid rgba(255,255,255,.12)}' +
    '.jda-top .bad{border-color:#ff6b6b;color:#ff9d9d}.jda-f{display:flex;gap:6px;overflow-x:auto;padding-bottom:6px;margin-bottom:4px}.jda-f button{flex:none;font:inherit;font-size:.74rem;padding:5px 10px;border-radius:999px;border:1px solid rgba(255,255,255,.14);background:none;color:inherit;cursor:pointer}' +
    '.jda-f button.on{background:rgba(255,200,61,.16);border-color:rgba(255,200,61,.5)}.jda-l{display:grid;gap:2px;max-height:420px;overflow-y:auto}.jda-r{display:grid;grid-template-columns:22px minmax(0,1fr) auto;gap:8px;align-items:start;padding:7px 4px;border-bottom:1px solid rgba(255,255,255,.06);font-size:.8rem}' +
    '.jda-pic{display:flex;align-items:center;gap:12px;margin:0 0 10px}.jda-pic img{width:72px;height:72px;border-radius:18px;object-fit:cover;border:1px solid rgba(255,255,255,.15)}' +
    '.jda-pic button{font:inherit;font-size:.76rem;padding:7px 12px;border-radius:10px;border:1px solid rgba(255,120,120,.5);background:none;color:#ff9d9d;cursor:pointer}' +
    '.jda-r small{display:block;opacity:.6;font-size:.7rem}.jda-r b.p{color:#5EDB95}.jda-r b.n{color:#ff9d9d}';
  function ago(t) { var m = Math.round((Date.now() - Date.parse(t)) / 60000); return m < 1 ? 'now' : m < 60 ? m + 'm ago' : m < 1440 ? Math.floor(m / 60) + 'h ago' : Math.floor(m / 1440) + 'd ago'; }
  window.jdActivity = function (box, fetcher, removeAvatar) {
    if (!document.getElementById('jda-css')) { var st = document.createElement('style'); st.id = 'jda-css'; st.textContent = css; document.head.appendChild(st); }
    box.innerHTML = '<p style="opacity:.7;font-size:.8rem">Loading activity…</p>';
    Promise.resolve().then(fetcher).then(function (d) {
      var p = d.player || {}, ev = d.events || [], f = 'all';
      var kinds = ['all'].concat(Object.keys(LABEL).filter(function (k) { return k !== 'all' && ev.some(function (e) { return e.kind === k; }); }));
      var draw = function () {
        var list = ev.filter(function (e) { return f === 'all' || e.kind === f; });
        var pic = p.avatar && /^https:/.test(p.avatar) ? '<div class="jda-pic"><img src="' + esc(p.avatar) + '" alt="Profile picture of ' + esc(p.name) + '">' +
          (removeAvatar ? '<button type="button" data-rm="1">🚫 Remove picture</button>' : '') + '</div>' : '';
        box.innerHTML = '<div class="jda">' + pic + '<div class="jda-top"><span>Balance <b>' + (+p.balance || 0).toLocaleString() + '</b></span>' +
          (p.banned ? '<span class="bad">Banned: ' + esc(p.banned) + '</span>' : '') + (p.ff ? '<span>FF ' + esc(p.ff) + '</span>' : '') +
          (p.seen ? '<span>Seen ' + esc(ago(p.seen)) + '</span>' : '') + (p.city ? '<span>' + esc(p.city) + '</span>' : '') + '</div>' +
          '<div class="jda-f">' + kinds.map(function (k) { return '<button type="button" data-k="' + k + '" class="' + (k === f ? 'on' : '') + '">' + LABEL[k] + '</button>'; }).join('') + '</div>' +
          '<div class="jda-l">' + (list.length ? list.map(function (e) {
            return '<div class="jda-r"><span>' + (ICON[e.kind] || '•') + '</span><span>' + esc(e.text) + '<small>' + esc(new Date(e.at).toLocaleString()) + ' · ' + esc(ago(e.at)) + '</small></span>' +
              (e.amt ? '<b class="' + (e.amt > 0 ? 'p' : 'n') + '">' + (e.amt > 0 ? '+' : '') + (+e.amt || 0) + '</b>' : '<span></span>') + '</div>';
          }).join('') : '<p style="opacity:.7;font-size:.8rem">Nothing here yet.</p>') + '</div></div>';
        var rm = box.querySelector('[data-rm]');
        if (rm) rm.onclick = function (e) {
          e.stopPropagation();
          var why = prompt('Remove this profile picture? The player is told why.', 'Not allowed: rude, fake or not your own photo');
          if (why === null) return;
          rm.disabled = true;
          Promise.resolve(removeAvatar(why)).then(function () { p.avatar = null; draw(); }, function (x) { rm.disabled = false; alert(x.message || x); });
        };
        box.querySelectorAll('[data-k]').forEach(function (b) { b.onclick = function (e) { e.stopPropagation(); f = b.dataset.k; draw(); }; });
      };
      draw();
    }).catch(function (e) { box.innerHTML = '<p style="color:#ff9d9d;font-size:.8rem">' + esc(e.message || e) + '</p>'; });
  };
})();
