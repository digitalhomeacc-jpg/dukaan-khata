// Offline support: keeps the app on the phone so it opens without internet.
// • the page itself: network first (always the newest version when online),
//   falling back to the saved copy when offline
// • everything else from this site (code, fonts, engine): saved on first use,
//   then served from the phone
// Requests to other sites (Supabase, PowerSync sync) are never touched.
const CACHE = 'dk-__BUILD__';
// Every file of this build (filled in by tool/build_web.sh).
const FILES = __FILES__;

// Fingerprint of each file's content (filled in by tool/build_web.sh).
const HASHES = __HASHES__;
const HASH_KEY = '__hashes__';

// Save the whole app once. A file is copied from the old saved copy only if
// its fingerprint is unchanged (engine, text fonts); anything that changed –
// e.g. the icon font, which Flutter trims to the icons each build uses – is
// downloaded fresh, so no icon ever shows up blank after an update.
self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    let oldHashes = {};
    try {
      const r = await caches.match(HASH_KEY);
      if (r) oldHashes = await r.json();
    } catch (_) { /* first install */ }
    await Promise.all(FILES.map(async (f) => {
      const same = HASHES[f] && oldHashes[f] === HASHES[f];
      const old = same ? await caches.match(f) : null;
      if (old) return cache.put(f, old);
      try {
        const res = await fetch(f, { cache: 'reload' });
        if (res.ok) await cache.put(f, res);
      } catch (_) { /* offline during install – saved on next use */ }
    }));
    await cache.put(HASH_KEY, new Response(JSON.stringify(HASHES), { headers: { 'Content-Type': 'application/json' } }));
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k.startsWith('dk-') && k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  const scope = new URL(self.registration.scope);
  if (!url.pathname.startsWith(scope.pathname)) return;

  const isPage = req.mode === 'navigate' || url.pathname === scope.pathname || url.pathname.endsWith('/index.html');
  if (isPage) {
    e.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put('./', copy));
          return res;
        })
        .catch(() => caches.match('./').then((r) => r || caches.match('index.html'))),
    );
    return;
  }
  e.respondWith(
    caches.match(req).then(
      (hit) =>
        hit ||
        fetch(req).then((res) => {
          if (res.ok && res.type === 'basic') {
            const copy = res.clone();
            caches.open(CACHE).then((c) => c.put(req, copy));
          }
          return res;
        }),
    ),
  );
});
