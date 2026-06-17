// ❌ DOES NOT WORK — Cloudflare Workers cannot proxy torrentio.strem.fun
//
// Both the Worker and torrentio.strem.fun are on Cloudflare's network.
// When the Worker's fetch() reaches torrentio, Cloudflare's WAF sees
// the request originating from a Worker IP and returns 403.
// There is no cf option, header, or fetch trick that bypasses this.
//
// Use one of these instead (both run on non-Cloudflare infrastructure):
//
// 1. torrentio-proxy.ts  — Deno Deploy (easiest, free, web UI paste)
// 2. proxy.js            — Node.js (Railway, Render, Fly.io, any VPS)
