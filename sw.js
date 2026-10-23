// JD Arena service worker: keeps the installed app fresh and shows push alerts
// (native Web Push — sent by supabase/functions/_shared/push.ts) even when the site is closed.

// The app's "no internet" screen (instead of Chrome's dinosaur) is cached on install.
self.addEventListener("install", e => {
  self.skipWaiting();
  // v2: the offline page also shows the saved tickets; cache:"reload" skips the 10-minute HTTP cache
  e.waitUntil(caches.open("jd-offline").then(c => c.add(new Request("/offline.html", { cache: "reload" }))).catch(() => {}));
});
self.addEventListener("activate", e => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k.startsWith("jd-static-") && k !== STATIC_CACHE) await caches.delete(k);
  await self.clients.claim();
})()));
// Pages (navigations) are always revalidated with GitHub Pages: it serves HTML with
// max-age=600, so without this a returning player could run a 10-minute-old copy of
// the site after an update. `no-cache` still sends If-None-Match, so an unchanged page
// costs a tiny 304, not a re-download. redirect:'manual' keeps Pages' /about ->
// /about/ redirects valid (a followed redirect can't answer a navigation request).
self.addEventListener("fetch", e => {
  const r = e.request;
  if (r.mode === "navigate" && r.method === "GET") {
    e.respondWith(
      fetch(r.url, { cache: "no-cache", credentials: "include", redirect: "manual" })
        .catch(() => fetch(r))
        .catch(async () => (await caches.match("/offline.html")) || Response.error())
    );
    return;
  }
  // Static files (images, styles, scripts, fonts) come from the phone's cache at once and are refreshed in
  // the background (stale-while-revalidate), so the app opens without waiting on the network. Data (JSON,
  // Supabase), the APK and anything else go straight to the network, untouched.
  const u = new URL(r.url);
  const font = u.hostname === "fonts.gstatic.com" || u.hostname === "fonts.googleapis.com";
  if (r.method === "GET" && (font || (u.origin === self.location.origin && STATIC.test(u.pathname) && !/\/sw\.js$/.test(u.pathname)))) {
    e.respondWith(swr(e, r));
    return;
  }
});
const STATIC = /\.(?:png|jpe?g|webp|gif|svg|ico|css|js|woff2?)$/i;   // not audio: players ask for byte ranges
const STATIC_CACHE = "jd-static-v1";
async function swr(e, r) {
  const cache = await caches.open(STATIC_CACHE);
  const hit = await cache.match(r);
  const net = fetch(r).then(res => {
    if (res && (res.status === 200 || res.type === "opaque")) cache.put(r, res.clone()).catch(() => {});
    return res;
  }).catch(() => hit || Response.error());
  if (hit) { e.waitUntil(net.catch(() => {})); return hit; }
  return net;
}

// A push always shows a notification — even if the payload can't be read — because a
// silent push makes Chrome show its own "site updated in the background" message and can
// cancel the subscription.
// Bundling: a new alert with the same tag (one per chat / challenge) replaces the old one
// and says how many arrived ("3 new messages"); the phone only buzzes again if the last
// buzz for that chat was over 30 seconds ago. Action buttons show on Android and desktop
// Chrome/Edge (iOS ignores them). The app icon gets a badge dot until JD Arena is opened.
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data ? e.data.text() : "" }; }
  const tag = d.tag || "jd-arena";
  const url = d.url || "/";
  const chat = /[?&](dm|g|chat)=|\/chat\//.test(url) || /^jd-(g-|c-|dm-|chat|staff-chat|zulu)/.test(tag);
  const room = /\/challenges\/\?c=/.test(url);
  // Each alert type looks and buzzes differently so players know what it is before opening:
  // messages = blue 💬, short buzz, bundled; Room ID/password = green 🔑, long urgent buzz,
  // stays until tapped; results = gold 🏆, celebration buzz.
  const kind = tag === "jd-room" || /^room code/i.test(d.title || "") ? "roomcode"
    : tag === "jd-results" || /^results are in/i.test(d.title || "") ? "result"
    : chat ? "msg" : "";
  const STYLE = {
    msg: { icon: "/notif-msg.png", pre: "💬 ", vibrate: [90, 60, 90] },
    roomcode: { icon: "/notif-room.png", pre: "🔑 ", vibrate: [600, 200, 600, 200, 600], sticky: true, action: "🔑 Show Room ID" },
    result: { icon: "/notif-result.png", pre: "🏆 ", vibrate: [120, 60, 120, 60, 120, 60, 500], action: "🏆 See results" },
  }[kind] || { icon: "/icon-192.png", pre: "", vibrate: [200, 100, 200, 100, 200] };
  e.waitUntil((async () => {
    let old = null;
    try { old = (await self.registration.getNotifications({ tag }))[0] || null; } catch (x) {}
    const od = (old && old.data) || {};
    const count = old ? (od.count || 1) + 1 : 1;
    const now = Date.now();
    const loud = STYLE.sticky || !old || now - (od.buzzAt || 0) > 30000;
    const t0 = d.title || "JD Arena";
    const title = (STYLE.pre && !t0.startsWith(STYLE.pre.trim()) ? STYLE.pre : "") + t0 + (count > 1 && (chat || room) ? ` · ${count} new` : "");
    const actions = chat ? [{ action: "open", title: "💬 Reply" }] : room ? [{ action: "open", title: "⚔️ Open room" }] : STYLE.action ? [{ action: "open", title: STYLE.action }] : [];
    // if a browser rejects any of the extras, still show a plain alert (a push without a
    // visible notification can get the subscription cancelled)
    const plain = () => self.registration.showNotification(d.title || "JD Arena", {
      body: d.body || "You have a new notification.", icon: "/icon-192.png", badge: "/badge-96.png", tag, data: { url } });
    try { await self.registration.showNotification(title, {
      body: d.body || "You have a new notification.",
      icon: STYLE.icon,
      badge: "/badge-96.png",
      tag,
      renotify: loud,
      silent: !loud,
      requireInteraction: !!STYLE.sticky,
      vibrate: loud ? STYLE.vibrate : undefined,
      actions,
      timestamp: now,
      data: { url, count, buzzAt: loud ? now : od.buzzAt },
    }); } catch (x) { await plain(); }
    try { if (self.navigator.setAppBadge) await self.navigator.setAppBadge(); } catch (x) {}
  })());
});

// Tap: focus an open JD Arena tab (and take it to the link) or open a new one.
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "/", self.location.origin).href;
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const w of wins) {
      if (new URL(w.url).origin === self.location.origin) {
        try { await w.focus(); if ("navigate" in w) await w.navigate(url); return; } catch (x) {}
      }
    }
    await self.clients.openWindow(url);
  })());
});
