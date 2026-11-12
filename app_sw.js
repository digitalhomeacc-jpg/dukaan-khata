// Offline support: keeps the app on the phone so it opens without internet.
// • the page itself: network first (always the newest version when online),
//   falling back to the saved copy when offline
// • everything else from this site (code, fonts, engine): saved on first use,
//   then served from the phone
// Requests to other sites (Supabase, PowerSync sync) are never touched.
const CACHE = 'dk-202611121850';
// Every file of this build (filled in by tool/build_web.sh).
const FILES = ["./", "assets/AssetManifest.bin", "assets/AssetManifest.bin.json", "assets/FontManifest.json", "assets/NOTICES", "assets/assets/fonts/NotoSansDevanagari-Bold.ttf", "assets/assets/fonts/NotoSansDevanagari-Regular.ttf", "assets/fonts/MaterialIcons-Regular.otf", "assets/fonts/fallback/Roboto-Regular.ttf", "assets/packages/cupertino_icons/assets/CupertinoIcons.ttf", "assets/packages/material_ui/shaders/ink_sparkle.frag", "assets/shaders/ink_sparkle.frag", "assets/shaders/stretch_effect.frag", "canvaskit/canvaskit.js", "canvaskit/canvaskit.wasm", "canvaskit/chromium/canvaskit.js", "canvaskit/chromium/canvaskit.wasm", "favicon.png", "flutter.js", "flutter_bootstrap.js?v=202611121850", "icons/Icon-192.png", "icons/Icon-512.png", "icons/Icon-maskable-192.png", "icons/Icon-maskable-512.png", "icons/apple-touch-icon.png", "index.html", "main.dart.js?v=202611121850", "manifest.json", "pdf_text.js?v=202611121850", "pdfjs/LICENSE", "pdfjs/pdf.min.js", "pdfjs/pdf.worker.min.js", "powersync_db.worker.js", "sqlite3.wasm"];

// Fingerprint of each file's content (filled in by tool/build_web.sh).
const HASHES = {"assets/AssetManifest.bin": "c52ff0074ffb9fdc", "assets/AssetManifest.bin.json": "1121e78e42e44a2d", "assets/FontManifest.json": "ddadcf5f7b5fe950", "assets/NOTICES": "c58bcedb07f2484b", "assets/assets/fonts/NotoSansDevanagari-Bold.ttf": "8a2ed3baf163d695", "assets/assets/fonts/NotoSansDevanagari-Regular.ttf": "80d0aa95681f9323", "assets/fonts/MaterialIcons-Regular.otf": "03cd051babc32783", "assets/fonts/fallback/Roboto-Regular.ttf": "dd1b1db13ff1f721", "assets/packages/cupertino_icons/assets/CupertinoIcons.ttf": "2e76c70d09fb1d8e", "assets/packages/material_ui/shaders/ink_sparkle.frag": "62b1055b4fc0da06", "assets/shaders/ink_sparkle.frag": "62b1055b4fc0da06", "assets/shaders/stretch_effect.frag": "4e55da261b4244de", "canvaskit/canvaskit.js": "0c6310118813bdda", "canvaskit/canvaskit.wasm": "be8f3627f67c99cf", "canvaskit/chromium/canvaskit.js": "dff71f7181981f0d", "canvaskit/chromium/canvaskit.wasm": "10918cabfe82f0f2", "favicon.png": "f478e35e4a0d411e", "flutter.js": "d868a09134c9f796", "icons/Icon-192.png": "6b5d6af704f5ca80", "icons/Icon-512.png": "664aa81de65e5ba0", "icons/Icon-maskable-192.png": "e91e4d35f1a187c3", "icons/Icon-maskable-512.png": "f835bf17a0549dc8", "icons/apple-touch-icon.png": "c8769c0909a7788a", "manifest.json": "0418c3e8eba0ef27", "pdfjs/LICENSE": "598f87f072f66e22", "pdfjs/pdf.min.js": "a4641a2626f396d0", "pdfjs/pdf.worker.min.js": "49162d546a1a5a11", "powersync_db.worker.js": "8486b7ea4f5465bd", "sqlite3.wasm": "fd7a1d3fc69e7ded"};
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
  // Big files that never change between versions (engine, database, PDF reader,
  // text fonts) and files whose name carries ?v=<build>: straight from the phone.
  const p = url.pathname.slice(scope.pathname.length);
  const fixed = url.search.includes('v=') || /^(canvaskit\/|pdfjs\/|icons\/|sqlite3\.wasm|assets\/assets\/fonts\/|assets\/fonts\/fallback\/|favicon)/.test(p);
  const save = (res) => {
    if (res.ok && res.type === 'basic') {
      const copy = res.clone();
      caches.open(CACHE).then((c) => c.put(req, copy));
    }
    return res;
  };
  if (fixed) {
    e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then(save)));
    return;
  }
  // Small files that can change with an update (icon font, asset lists, workers):
  // ask the site first so an update never shows blank icons; use the saved copy
  // when offline or when the network is too slow.
  e.respondWith((async () => {
    const net = fetch(req, { cache: 'no-cache' }).then(save);
    const slow = new Promise((r) => setTimeout(r, 4000));
    try {
      const res = await Promise.race([net, slow.then(() => null)]);
      if (res) return res;
    } catch (_) { /* offline */ }
    const hit = await caches.match(req);
    return hit || net;
  })());
});
