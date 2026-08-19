const CACHE_NAME = 'dyqp-v1.1.4';
const ASSETS = [
  '/shop/',
  '/shop/index.html',
  '/shop/manifest.json'
];

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  // Skip non-GET and non-same-origin
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  // Network-first for HTML, cache-first for assets
  if (e.request.headers.get('accept')?.includes('text/html')) {
    e.respondWith(
      fetch(e.request).catch(() => caches.match('/shop/index.html'))
    );
  } else {
    e.respondWith(
      caches.match(e.request).then(cached => cached || fetch(e.request).then(resp => {
        if (resp.ok && resp.type === 'basic') {
          const clone = resp.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(e.request, clone));
        }
        return resp;
      }))
    );
  }
});
