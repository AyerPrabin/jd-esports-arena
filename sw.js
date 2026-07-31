// Merged in (not a separate worker) so OneSignal push works without breaking
// the PWA install flow below — both need to run from one file at root scope.
// Wrapped so a CDN hiccup only costs push, not the rest of this worker.
try {
  importScripts("https://cdn.onesignal.com/sdks/web/v16/OneSignalSDK.sw.js");
} catch (e) {}

self.addEventListener("install", e => self.skipWaiting());
self.addEventListener("activate", e => self.clients.claim());
self.addEventListener("fetch", e => e.respondWith(fetch(e.request)));
