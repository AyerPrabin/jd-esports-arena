// Merged in (not a separate worker) so OneSignal push works without breaking
// the PWA install flow below — both need to run from one file at root scope.
// Wrapped so a CDN hiccup only costs push, not the rest of this worker.
try {
  importScripts("https://cdn.onesignal.com/sdks/web/v16/OneSignalSDK.sw.js");
} catch (e) {}

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
