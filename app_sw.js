// Offline support: keeps the app on the phone so it opens without internet.
// • the page itself: network first (always the newest version when online),
//   falling back to the saved copy when offline
// • everything else from this site (code, fonts, engine): saved on first use,
//   then served from the phone
// Requests to other sites (Supabase, PowerSync sync) are never touched.
const CACHE = 'dk-202611090237';
// Every file of this build (filled in by tool/build_web.sh).
const FILES = ["./", "assets/AssetManifest.bin", "assets/AssetManifest.bin.json", "assets/FontManifest.json", "assets/NOTICES", "assets/assets/fonts/NotoSansDevanagari-Bold.ttf", "assets/assets/fonts/NotoSansDevanagari-Regular.ttf", "assets/fonts/MaterialIcons-Regular.otf", "assets/fonts/fallback/Roboto-Regular.ttf", "assets/packages/cupertino_icons/assets/CupertinoIcons.ttf", "assets/packages/material_ui/shaders/ink_sparkle.frag", "assets/shaders/ink_sparkle.frag", "assets/shaders/stretch_effect.frag", "canvaskit/canvaskit.js", "canvaskit/canvaskit.wasm", "canvaskit/chromium/canvaskit.js", "canvaskit/chromium/canvaskit.wasm", "favicon.png", "flutter.js", "flutter_bootstrap.js?v=202611090237", "icons/Icon-192.png", "icons/Icon-512.png", "icons/Icon-maskable-192.png", "icons/Icon-maskable-512.png", "icons/apple-touch-icon.png", "index.html", "main.dart.js?v=202611090237", "manifest.json", "pdf_text.js?v=202611090237", "pdfjs/LICENSE", "pdfjs/pdf.min.js", "pdfjs/pdf.worker.min.js", "powersync_db.worker.js", "sqlite3.wasm"];

// Save the whole app once. Files that did not change since the last version
// (engine, fonts) are copied from the old saved copy instead of downloaded again.
self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    await Promise.all(FILES.map(async (f) => {
      const old = f.includes('?v=') ? null : await caches.match(f);
      if (old) return cache.put(f, old);
      try {
        const res = await fetch(f, { cache: 'reload' });
        if (res.ok) await cache.put(f, res);
      } catch (_) { /* offline during install – saved on next use */ }
    }));
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
