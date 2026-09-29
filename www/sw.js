// Service worker: abre o app mesmo com internet instável.
// Páginas: rede primeiro (pega atualizações), cache se estiver offline.
// Bibliotecas e ícones: cache primeiro. Chamadas ao Supabase nunca passam pelo cache.
const VERSAO = "ga-v2.0.0";
const BASE = ["./", "index.html", "config.js", "manifest.webmanifest",
  "vendor/supabase.js", "vendor/xlsx.full.min.js", "vendor/jspdf.umd.min.js", "vendor/qrcode.js",
  "icons/icon-192.png", "icons/icon-512.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(VERSAO).then(c => c.addAll(BASE)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSAO).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;              // Supabase, fontes etc.
  if (req.mode === "navigate" || url.pathname.endsWith("config.js")) {
    e.respondWith(fetch(req).then(r => { const cp = r.clone(); caches.open(VERSAO).then(c => c.put(req, cp)); return r; })
      .catch(() => caches.match(req).then(r => r || caches.match("index.html"))));
    return;
  }
  e.respondWith(caches.match(req).then(r => r || fetch(req).then(res => {
    if (res.ok) { const cp = res.clone(); caches.open(VERSAO).then(c => c.put(req, cp)); }
    return res;
  })));
});
