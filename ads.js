// Rewarded-ad gate for free tournaments (supabase/ad_gate.sql). Players without a Weekly Pass watch 3 Google
// rewarded ads (max 1 per hour) before joining a free event. Off until public.ad_config.enabled is set, and then
// jdAds.gate() resolves true straight away for everyone. Only Google's rewarded format (GPT rewarded) is used:
// the credit is claimed only after Google fires rewardedSlotGranted, and the server enforces the hour + count.
// jdAds.gate(sb, eventName) -> Promise<boolean>: true = go on and register.
(function () {
  var css = document.createElement('style');
  css.textContent = '#ad-gate{position:fixed;inset:0;z-index:9999;display:grid;place-items:center;background:rgba(5,7,12,.82);padding:16px}' +
    '#ad-gate .b{width:100%;max-width:380px;background:#11151F;border:1px solid rgba(255,200,61,.35);border-radius:18px;padding:22px;color:#F3EEE3;text-align:center;font-family:inherit}' +
    '#ad-gate h3{margin:0 0 6px;font-size:1.2rem;color:#FFC83D}#ad-gate p{margin:6px 0 14px;color:#C8CDDC;font-size:.92rem;line-height:1.4}' +
    '#ad-gate .dots{display:flex;gap:10px;justify-content:center;margin:12px 0 16px}#ad-gate .dots i{width:42px;height:10px;border-radius:6px;background:#2A3142}' +
    '#ad-gate .dots i.on{background:#FFC83D}#ad-gate button{width:100%;padding:13px;border:0;border-radius:12px;font-weight:700;font-size:1rem;font-family:inherit;cursor:pointer;margin-top:8px}' +
    '#ad-gate .go{background:#FFC83D;color:#0A0A12}#ad-gate .go:disabled{opacity:.5;cursor:default}#ad-gate .alt{background:transparent;color:#C8CDDC;border:1px solid #2A3142}' +
    '#ad-gate .err{color:#FF7A8A;font-size:.85rem;min-height:1.2em}';
  document.head.appendChild(css);

  var gptLoaded = null;
  function loadGpt() {
    if (gptLoaded) return gptLoaded;
    gptLoaded = new Promise(function (res, rej) {
      window.googletag = window.googletag || { cmd: [] };
      var s = document.createElement('script');
      s.async = true; s.src = 'https://securepubads.g.doubleclick.net/tag/js/gpt.js';
      s.onload = res; s.onerror = function () { gptLoaded = null; rej(new Error('Ad blocked or offline.')); };
      document.head.appendChild(s);
    });
    return gptLoaded;
  }

  // shows one rewarded ad; resolves true only when Google says the reward was earned
  function showRewarded(unit) {
    return loadGpt().then(function () {
      return new Promise(function (res, rej) {
        googletag.cmd.push(function () {
          var slot = googletag.defineOutOfPageSlot(unit, googletag.enums.OutOfPageFormat.REWARDED);
          if (!slot) { rej(new Error('Rewarded ads are not supported on this page.')); return; }
          slot.addService(googletag.pubads());
          var granted = false, done = false, pa = googletag.pubads();
          function end(ok, err) { if (done) return; done = true; try { googletag.destroySlots([slot]); } catch (e) {} if (err) rej(err); else res(ok); }
          pa.addEventListener('rewardedSlotReady', function (e) { if (e.slot === slot) { clearTimeout(tmo); e.makeRewardedVisible(); } });
          pa.addEventListener('rewardedSlotGranted', function (e) { if (e.slot === slot) granted = true; });
          pa.addEventListener('rewardedSlotClosed', function (e) { if (e.slot === slot) end(granted); });
          pa.addEventListener('slotRenderEnded', function (e) { if (e.slot === slot && e.isEmpty) end(false, new Error('No ad available right now - try again in a few minutes.')); });
          googletag.enableServices();
          googletag.display(slot);
          var tmo = setTimeout(function () { end(false, new Error('The ad did not load - try again.')); }, 30000);   // load only; cleared once the ad is ready
        });
      });
    });
  }

  function fmtWait(at) {
    var m = Math.max(1, Math.ceil((new Date(at) - Date.now()) / 60000));
    return m >= 60 ? '1 hour' : m + ' min';
  }

  // retry = called after the server refused a join: only a real "Join now" tap may send it again (no loops)
  function gate(sb, eventName, retry) {
    return sb.rpc('ad_status').then(function (r) {
      var st = r && r.data;
      if (!st || !st.enabled || st.exempt || st.have >= st.needed || !st.unit) return !retry;
      return new Promise(function (resolve) {
        var box = document.createElement('div');
        box.id = 'ad-gate';
        document.body.appendChild(box);
        var timer = null, busy = false;
        // admob:<unit> = the ad plays in the Android app (RewardActivity, app 1.5.0+); elsewhere it can't
        var admob = /^admob:/.test(st.unit), app = typeof JD_TWA !== 'undefined' && JD_TWA !== 0;
        function close(ok) { clearInterval(timer); box.remove(); resolve(ok); }
        function draw(msg) {
          busy = false;
          var dots = '';
          for (var i = 0; i < st.needed; i++) dots += '<i class="' + (i < st.have ? 'on' : '') + '"></i>';
          var wait = st.next_at && new Date(st.next_at) > Date.now();
          var ready = st.have >= st.needed;
          box.innerHTML = '<div class="b"><h3>' + (ready ? 'Unlocked!' : 'Free entry = ' + st.needed + ' short ads') + '</h3>' +
            '<p>' + (ready ? 'You can join ' + eventName.replace(/</g, '&lt;') + ' now.' :
              'Watch ' + st.needed + ' ads to join this free tournament - one ad per hour. Weekly Pass holders skip the ads.') + '</p>' +
            '<div class="dots">' + dots + '</div><div class="err">' + (msg || '') + '</div>' +
            (ready ? '<button class="go" data-a="join">Join now</button>'
              : admob && !app ? '<p>The ads play in the JD Arena Android app.</p><button class="go" data-a="getapp">Get the JD Arena app</button>'
              : '<button class="go" data-a="watch"' + (wait ? ' disabled' : '') + '>' + (wait ? 'Next ad in ' + fmtWait(st.next_at) : 'Watch ad ' + (st.have + 1) + ' of ' + st.needed) + '</button>' +
                '<button class="alt" data-a="pass">Get a Weekly Pass - no ads</button>') +
            '<button class="alt" data-a="close">Later</button></div>';
        }
        box.onclick = function (e) {
          var a = e.target.dataset && e.target.dataset.a;
          if (e.target === box || a === 'close') return close(false);
          if (a === 'join') return close(true);
          if (a === 'pass') { location.href = '/pass/'; return; }
          if (a === 'getapp') { location.href = '/download/'; return; }
          if (a !== 'watch') return;
          busy = true; e.target.disabled = true; e.target.textContent = 'Loading ad…';
          if (admob) { openAppAd(eventName); return; }
          showRewarded(st.unit).then(function (ok) {
            if (!ok) { draw('Watch the ad to the end to earn it.'); return; }
            return sb.rpc('ad_reward_claim').then(function (c) {
              if (c.error) { var m = /AD_COOLDOWN: next ad at (\S+)/.exec(c.error.message); if (m) st.next_at = m[1]; draw(m ? '' : c.error.message); return; }
              st = c.data; draw();
            });
          }).catch(function (err) { draw(err.message || 'Ad failed to load.'); });
        };
        draw();
        timer = setInterval(function () { if (!busy && st.next_at) draw(); }, 30000);
      });
    }).catch(function () { return !retry; });   // gate not installed / offline: the server still decides
  }

  // ── in the Android app: the native screen plays the AdMob ad and comes back with ?adreward=<nonce>&adok=1 ──
  var PENDING = 'jd_ad_pending';
  function openAppAd(eventName) {
    var n = Math.random().toString(36).slice(2, 12) + Date.now().toString(36);
    try { localStorage.setItem(PENDING, JSON.stringify({ n: n, ev: eventName, t: Date.now() })); } catch (e) {}
    // an app older than 1.5.0 has no ad screen: Chrome then opens the download page to update
    location.href = 'intent://ad?n=' + n + '#Intent;scheme=jdarena;package=uk.co.jdesport.arena;S.browser_fallback_url=' +
      encodeURIComponent('https://jdesport.co.uk/download/') + ';end';
  }
  function resume() {
    var q = new URLSearchParams(location.search), n = q.get('adreward'), okv = q.get('adok');
    if (!n) return;
    q.delete('adreward'); q.delete('adok');
    history.replaceState(history.state, '', location.pathname + (q.toString() ? '?' + q : '') + location.hash);
    var p = null;
    try { p = JSON.parse(localStorage.getItem(PENDING) || 'null'); localStorage.removeItem(PENDING); } catch (e) {}
    if (!p || p.n !== n || Date.now() - p.t > 30 * 60000) return;   // only the ad this page asked for
    var tries = 0;
    (function wait() {   // home.js globals: the Supabase client, the event list, the join flow
      var ready = typeof sb !== 'undefined' && sb && typeof _lastData !== 'undefined' && _lastData && typeof registerInApp === 'function' && typeof _player !== 'undefined' && _player;
      if (!ready) { if (++tries < 40) setTimeout(wait, 250); return; }
      sb.auth.getSession().then(function (r) {
        if (!r || !r.data || !r.data.session) return;
        var next = function () { registerInApp(p.ev); };   // re-opens the ad popup with the new count (or the join form)
        if (okv !== '1') return next();
        sb.rpc('ad_reward_claim').then(next, next);
      });
    })();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', resume); else resume();

  window.jdAds = { gate: gate };
})();
