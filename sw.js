// JD Arena service worker: keeps the installed app fresh and shows push alerts
// (native Web Push — sent by supabase/functions/_shared/push.ts) even when the site is closed.

self.addEventListener("install", e => self.skipWaiting());
self.addEventListener("activate", e => self.clients.claim());
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
    );
    return;
  }
  e.respondWith(fetch(r));
});

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
  const chat = /[?&](dm|g|chat)=|\/chat\//.test(url);
  const room = /\/challenges\/\?c=/.test(url);
  e.waitUntil((async () => {
    let old = null;
    try { old = (await self.registration.getNotifications({ tag }))[0] || null; } catch (x) {}
    const od = (old && old.data) || {};
    const count = old ? (od.count || 1) + 1 : 1;
    const now = Date.now();
    const loud = !old || now - (od.buzzAt || 0) > 30000;
    const title = (d.title || "JD Arena") + (count > 1 && (chat || room) ? ` · ${count} new` : "");
    const actions = chat ? [{ action: "open", title: "💬 Reply" }] : room ? [{ action: "open", title: "⚔️ Open room" }] : [];
    // if a browser rejects any of the extras, still show a plain alert (a push without a
    // visible notification can get the subscription cancelled)
    const plain = () => self.registration.showNotification(d.title || "JD Arena", {
      body: d.body || "You have a new notification.", icon: "/icon-192.png", badge: "/favicon-64.png", tag, data: { url } });
    try { await self.registration.showNotification(title, {
      body: d.body || "You have a new notification.",
      icon: "/icon-192.png",
      badge: "/favicon-64.png",
      tag,
      renotify: loud,
      silent: !loud,
      vibrate: loud ? [200, 100, 200, 100, 200] : undefined,
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
