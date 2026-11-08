/* Login captcha (owner's ask, 8 Nov 2026): Cloudflare Turnstile for Supabase Auth.
   jdCaptcha() gives a fresh one-use token for signUp / signInWithPassword / signInWithOtp / resetPasswordForEmail.
   While KEY is empty it returns undefined and nothing changes. Order matters: set KEY and publish FIRST, then turn on
   captcha in Supabase (Authentication → Attack Protection, Turnstile + secret key). The other way round, logins fail.
   Turnstile shows nothing for most people; a check box appears only when Cloudflare is unsure. Google sign-in is not affected. */
(function () {
  var KEY = '';   // Turnstile SITE key (public), from dash.cloudflare.com → Turnstile, domain jdesport.co.uk
  var ready = null;
  function load() {
    if (ready) return ready;
    ready = new Promise(function (res, rej) {
      var s = document.createElement('script');
      s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
      s.async = true;
      s.onload = function () { res(window.turnstile); };
      s.onerror = function () { ready = null; rej(new Error('The security check could not load. Check your internet and try again.')); };
      document.head.appendChild(s);
    });
    return ready;
  }
  window.jdCaptcha = async function () {
    if (!KEY) return undefined;
    var t = await load();
    var box = document.getElementById('jd-cap');
    if (!box) {
      box = document.createElement('div'); box.id = 'jd-cap';
      box.style.cssText = 'position:fixed;left:50%;bottom:16px;transform:translateX(-50%);z-index:100000';
      document.body.appendChild(box);
    }
    box.innerHTML = '';
    return new Promise(function (res, rej) {
      t.render(box, {
        sitekey: KEY, appearance: 'interaction-only',
        callback: function (tok) { setTimeout(function () { box.innerHTML = ''; }, 0); res(tok); },
        'error-callback': function () { rej(new Error('Security check failed. Try again.')); },
        'timeout-callback': function () { rej(new Error('Security check timed out. Try again.')); },
      });
    });
  };
})();
