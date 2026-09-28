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
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { body: e.data ? e.data.text() : "" }; }
  const title = d.title || "JD Arena";
  e.waitUntil(self.registration.showNotification(title, {
    body: d.body || "You have a new notification.",
    icon: "/icon-192.png",
    badge: "/favicon-64.png",
    tag: d.tag || "jd-arena",
    renotify: true,
    vibrate: [200, 100, 200, 100, 200],
    data: { url: d.url || "/" },
  }));
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
