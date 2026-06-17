// Simple HTTP proxy for torrentio.strem.fun
//
// Deploy on any non-Cloudflare platform (Railway, Render, Fly.io, etc.)
// Cloudflare Workers CANNOT proxy torrentio — both are on Cloudflare's
// network, so the WAF blocks Worker-originated subrequests.
//
// Railway (easiest):
//   1. Go to https://railway.app → New Project → Deploy from GitHub
//   2. Or: railway up (after `npm i -g @railway/cli`)
//   3. Set the port env var if needed (defaults to 3000)
//
// Render:
//   1. Go to https://render.com → New → Web Service
//   2. Use this file, set start command: node proxy.js
//
// Then set in .env.vars production():
//   TORRENTIO_API_BASE_URL=https://<your-app>.railway.app
//   (or .onrender.com, etc.)

const http = require("http");
const https = require("https");

const UPSTREAM = "https://torrentio.strem.fun";
const PORT = process.env.PORT || 3000;

const server = http.createServer((clientReq, clientRes) => {
  const upstream = new URL(UPSTREAM + clientReq.url);

  const options = {
    method: clientReq.method,
    headers: {
      "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
      "Accept": "application/json, text/html, */*",
    },
  };

  const proxyReq = https.request(upstream, options, (proxyRes) => {
    // Rewrite Location headers that point back to torrentio.strem.fun
    const headers = { ...proxyRes.headers };
    if (headers.location) {
      const proxyOrigin = `http://${clientReq.headers.host}`;
      headers.location = headers.location.replace("https://torrentio.strem.fun", proxyOrigin);
    }
    clientRes.writeHead(proxyRes.statusCode, headers);
    proxyRes.pipe(clientRes);
  });

  proxyReq.on("error", (e) => {
    console.error("Proxy error:", e.message);
    clientRes.writeHead(502, { "Content-Type": "text/plain" });
    clientRes.end("Proxy error: " + e.message);
  });

  proxyReq.end();
});

server.listen(PORT, () => {
  console.log(`torrentio proxy running on port ${PORT}`);
});
