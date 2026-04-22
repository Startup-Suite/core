// ROLLBACK of PR #245.
//
// Restores the suite-v1 service worker logic but with CACHE_NAME bumped
// to suite-v3. The version bump is critical: reverting the code alone
// would leave users with the suite-v2 cache still populated, because
// the running SW would no longer match their browser-installed version
// byte-for-byte but would still reference the suite-v2 cache by name.
//
// The activate handler (carried over from the original) deletes any
// cache whose name isn't CACHE_NAME, so bumping to suite-v3 wipes both
// suite-v1 (if still present on some client) AND suite-v2 as a one-
// shot cleanup on next page load.

const CACHE_NAME = "suite-v3";
const STATIC_ASSETS = ["/"];

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(STATIC_ASSETS).catch(() => {}))
  );
  self.skipWaiting();
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", event => {
  if (event.request.method !== "GET") return;
  // Skip cross-origin requests — intercepting e.g. livekit.milvenan.technology
  // breaks the LiveKit SDK's /rtc/v1/validate reconnect path.
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;
  event.respondWith(
    fetch(event.request).catch(() =>
      caches.match(event.request).then(r => r || Response.error())
    )
  );
});

self.addEventListener("push", event => {
  const data = event.data?.json() ?? {};
  event.waitUntil(
    self.registration.showNotification(data.title ?? "Suite", {
      body: data.body,
      icon: "/images/icon-192.png",
      badge: "/images/icon-192.png",
      data: { url: data.url ?? "/chat" }
    })
  );
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  event.waitUntil(clients.openWindow(event.notification.data.url));
});
