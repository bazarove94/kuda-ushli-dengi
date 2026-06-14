const CACHE_NAME = "kuda-dengi-v4.2.2";
const APP_SHELL = [
    "./",
    "./index.html",
    "./manifest.webmanifest",
    "./app-icon.svg"
  ];

self.addEventListener("install", event => {
    event.waitUntil(
          caches.open(CACHE_NAME)
            .then(cache => Promise.allSettled(APP_SHELL.map(url => cache.add(url))))
            .then(() => self.skipWaiting())
        );
});

self.addEventListener("activate", event => {
    event.waitUntil(
          caches.keys()
            .then(keys => Promise.all(keys.filter(key => key.startsWith("kuda-dengi-") && key !== CACHE_NAME).map(key => caches.delete(key))))
            .then(() => self.clients.claim())
        );
});

self.addEventListener("message", event => {
    if (event.data?.type === "SKIP_WAITING") self.skipWaiting();
});

self.addEventListener("fetch", event => {
    const request = event.request;
    if (request.method !== "GET") return;

                        const url = new URL(request.url);
    if (url.hostname.endsWith("supabase.co")) return;

                        if (request.mode === "navigate") {
                              event.respondWith(
                                      fetch(request)
                                        .then(response => {
                                                    if (response.ok) {
                                                                  const copy = response.clone();
                                                                  caches.open(CACHE_NAME).then(cache => cache.put("./index.html", copy));
                                                    }
                                                    return response;
                                        })
                                        .catch(async () => (await caches.match("./index.html")) || (await caches.match("./")))
                                    );
                              return;
                        }

                        if (url.origin === self.location.origin) {
                              event.respondWith(
                                      caches.match(request).then(cached => {
                                                const network = fetch(request).then(response => {
                                                            if (response.ok) caches.open(CACHE_NAME).then(cache => cache.put(request, response.clone()));
                                                            return response;
                                                });
                                                return cached || network;
                                      })
                                    );
                              return;
                        }

                        if (url.hostname === "cdn.jsdelivr.net") {
                              event.respondWith(
                                      caches.match(request).then(cached => cached || fetch(request).then(response => {
                                                if (response.ok || response.type === "opaque") {
                                                            caches.open(CACHE_NAME).then(cache => cache.put(request, response.clone()));
                                                }
                                                return response;
                                      }))
                                    );
                        }
});
