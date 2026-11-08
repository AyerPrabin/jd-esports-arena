/* iPhone/iPad install guide for the web version (owner's ask, 8 Nov 2026: "make it easy").
   Apple lets no website install itself, so this shows the 2 taps as pictures, with an arrow bouncing at
   Safari's Share button. Inside TikTok/Instagram/Chrome it first moves the page to Safari (iOS 17+: x-safari-),
   with a Copy link fallback. Use: jdIosInstall()  */
(function () {
  var SHARE = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="#0A84FF" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12M7.5 7.5 12 3l4.5 4.5"/><path d="M7 11H5.5A1.5 1.5 0 0 0 4 12.5v7A1.5 1.5 0 0 0 5.5 21h13a1.5 1.5 0 0 0 1.5-1.5v-7a1.5 1.5 0 0 0-1.5-1.5H17"/></svg>';
  var PLUS = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" aria-hidden="true"><rect x="3.5" y="3.5" width="17" height="17" rx="4"/><path d="M12 8v8M8 12h8"/></svg>';
  var css = '#jdii{position:fixed;inset:0;z-index:99999;background:rgba(3,5,10,.82);backdrop-filter:blur(4px);-webkit-backdrop-filter:blur(4px);display:flex;align-items:flex-end;justify-content:center;font:15px/1.45 system-ui,-apple-system,sans-serif;color:#fff}' +
    '#jdii .s{width:100%;max-width:440px;background:linear-gradient(160deg,#151b2a,#0b0f19);border:1px solid rgba(255,200,80,.35);border-bottom:0;border-radius:22px 22px 0 0;padding:20px 18px 120px;position:relative}' +
    '#jdii h3{margin:0 0 4px;font-size:1.15rem}#jdii .sub{margin:0 0 14px;color:#A6AFC2;font-size:.9rem}' +
    '#jdii .st{display:flex;gap:12px;align-items:center;padding:12px;border-radius:14px;background:rgba(255,255,255,.05);margin-bottom:8px}' +
    '#jdii .n{flex:none;width:26px;height:26px;border-radius:50%;background:#FFC83D;color:#2b1d00;font-weight:800;display:grid;place-items:center}' +
    '#jdii .ic{flex:none;width:40px;height:40px;border-radius:10px;background:#fff;display:grid;place-items:center}#jdii .ic.d{background:#2c2c2e}' +
    '#jdii b{color:#FFDD85}#jdii .x{position:absolute;top:10px;right:12px;background:none;border:0;color:#A6AFC2;font-size:1.5rem;cursor:pointer;padding:6px}' +
    '#jdii .go{display:block;width:100%;margin-top:6px;padding:14px;border:0;border-radius:14px;font-weight:800;font-size:1rem;background:linear-gradient(180deg,#FFD25C,#FFAE00);color:#2b1d00;cursor:pointer}' +
    '#jdii .ar{position:fixed;bottom:18px;left:50%;transform:translateX(-50%);display:flex;flex-direction:column;align-items:center;color:#FFC83D;font-weight:800;font-size:.85rem;animation:jdiib 1s ease-in-out infinite;pointer-events:none;text-align:center}' +
    '#jdii .ar i{font-style:normal;font-size:2.2rem;line-height:1}' +
    '@keyframes jdiib{50%{transform:translate(-50%,8px)}}@media (prefers-reduced-motion:reduce){#jdii .ar{animation:none}}';

  function inSafari() {
    var ua = navigator.userAgent;
    return /Safari/.test(ua) && !/CriOS|FxiOS|EdgiOS|OPiOS|GSA|Instagram|FBAN|FBAV|TikTok|musical_ly|Line|Snapchat/.test(ua);
  }
  function close() { var o = document.getElementById('jdii'); if (o) o.remove(); }

  window.jdIosInstall = function () {
    if (window.matchMedia('(display-mode: standalone)').matches || navigator.standalone) {
      alert('JD Arena is already installed on this phone. 🎮'); return;
    }
    close();
    if (!document.getElementById('jdii-css')) { var st = document.createElement('style'); st.id = 'jdii-css'; st.textContent = css; document.head.appendChild(st); }
    var url = 'https://jdesport.co.uk/', o = document.createElement('div');
    o.id = 'jdii'; o.setAttribute('role', 'dialog'); o.setAttribute('aria-modal', 'true'); o.setAttribute('aria-label', 'Install JD Arena on iPhone');
    if (!inSafari()) {
      o.innerHTML = '<div class="s"><button class="x" aria-label="Close">×</button><h3>📲 Open in Safari first</h3>' +
        '<p class="sub">iPhone apps can only be added to the home screen from Safari.</p>' +
        '<button class="go" id="jdii-saf">Open in Safari</button>' +
        '<button class="go" id="jdii-copy" style="background:rgba(255,255,255,.1);color:#fff">Copy link</button>' +
        '<p class="sub" id="jdii-msg" style="margin-top:10px">Then paste it in Safari and tap Install again.</p></div>';
      o.querySelector('#jdii-saf').onclick = function () { location.href = 'x-safari-' + url + 'download/?ios=1'; };
      o.querySelector('#jdii-copy').onclick = function () {
        var m = o.querySelector('#jdii-msg');
        (navigator.clipboard ? navigator.clipboard.writeText(url) : Promise.reject()).then(function () { m.textContent = '✓ Copied. Open Safari, paste it in the address bar, and tap Install again.'; },
          function () { m.textContent = 'Open Safari and type jdesport.co.uk, then tap Install again.'; });
      };
      o.style.alignItems = 'center'; o.querySelector('.s').style.cssText = 'border-radius:22px;border-bottom:1px solid rgba(255,200,80,.35);padding-bottom:20px;margin:16px';
    } else {
      o.innerHTML = '<div class="s"><button class="x" aria-label="Close">×</button><h3>📲 Install JD Arena: 2 taps</h3>' +
        '<p class="sub">Free, no App Store. It opens like an app and gets alerts.</p>' +
        '<div class="st"><span class="n">1</span><span class="ic">' + SHARE + '</span><span>Tap <b>Share</b> in Safari\'s bar below. No Share icon? Tap <b>•••</b> first.</span></div>' +
        '<div class="st"><span class="n">2</span><span class="ic d">' + PLUS + '</span><span>Scroll down, tap <b>Add to Home Screen</b>, then <b>Add</b>.</span></div>' +
        '<p class="sub" style="margin:10px 0 0">Done: open <b>JD Arena</b> from your home screen and allow notifications.</p></div>' +
        '<div class="ar"><span>Share is down here</span><i>⬇</i></div>';
    }
    o.addEventListener('click', function (e) { if (e.target === o || e.target.classList.contains('x')) close(); });
    document.addEventListener('keydown', function k(e) { if (e.key === 'Escape') { close(); document.removeEventListener('keydown', k); } });
    document.body.appendChild(o);
    var x = o.querySelector('.x'); if (x) x.focus();
  };
})();
