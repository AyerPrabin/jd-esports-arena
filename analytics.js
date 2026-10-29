// Google Analytics 4 + conversion events. Does nothing until GA_ID is set (Admin > Data streams > Measurement ID).
(function () {
  var GA_ID = 'G-TF6BE9NYJD';
  if (!GA_ID || /^(localhost|127\.0\.0\.1)$/.test(location.hostname)) return;

  var s = document.createElement('script');
  s.async = true;
  s.src = 'https://www.googletagmanager.com/gtag/js?id=' + GA_ID;
  document.head.appendChild(s);
  window.dataLayer = window.dataLayer || [];
  window.gtag = function () { dataLayer.push(arguments); };
  gtag('js', new Date());
  gtag('config', GA_ID);

  // Conversions: mark these as key events in GA4 (Admin > Events).
  document.addEventListener('click', function (e) {
    var el = e.target.closest && e.target.closest('a,button');
    if (!el) return;
    var href = el.getAttribute('href') || '';
    if (/\.apk(\?|$)/i.test(href)) gtag('event', 'apk_download', { file: href });
    else if (/\.(exe|zip)(\?|$)/i.test(href)) gtag('event', 'optimizer_download', { file: href });
    else if (el.id === 'signup-btn') gtag('event', 'sign_up_click');
    else if (el.id === 'join') gtag('event', 'mega_join_click');
    else if (/discord\.gg|instagram\.com|tiktok\.com/i.test(href)) gtag('event', 'social_click', { url: href });
    else if (el.dataset.track) gtag('event', el.dataset.track);
  }, true);
})();
