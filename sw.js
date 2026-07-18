// Mini Encanto — Service Worker
// v2 (2026-07-18): navegación siempre a la red sin caché (para que la app
// se actualice al recargar), con fallback a caché solo si no hay conexión.
const CACHE_NAME = 'mini-encanto-v2';
const urlsToCache = ['/', '/index.html'];

self.addEventListener('install', function(event) {
  event.waitUntil(
    caches.open(CACHE_NAME).then(function(cache) {
      return cache.addAll(urlsToCache).catch(function(){});
    })
  );
  self.skipWaiting();
});

self.addEventListener('activate', function(event) {
  event.waitUntil(
    caches.keys().then(function(cacheNames) {
      return Promise.all(
        cacheNames.filter(function(name) { return name !== CACHE_NAME; })
                  .map(function(name) { return caches.delete(name); })
      );
    })
  );
  self.clients.claim();
});

self.addEventListener('fetch', function(event) {
  var req = event.request;
  if (req.url.includes('supabase.co')) return;

  // El documento HTML: SIEMPRE de la red y sin caché del navegador, así la app
  // toma la última versión publicada. Si no hay conexión, cae a la caché.
  if (req.mode === 'navigate' || req.destination === 'document') {
    event.respondWith(
      fetch(req, { cache: 'no-store' })
        .then(function(res) {
          var copy = res.clone();
          caches.open(CACHE_NAME).then(function(c){ c.put('/index.html', copy); }).catch(function(){});
          return res;
        })
        .catch(function() { return caches.match('/index.html') || caches.match('/'); })
    );
    return;
  }

  // Resto de recursos: red primero, caché como respaldo.
  event.respondWith(fetch(req).catch(function() { return caches.match(req); }));
});

self.addEventListener('message', function(event) {
  if (event.data === 'skipWaiting') self.skipWaiting();
});
