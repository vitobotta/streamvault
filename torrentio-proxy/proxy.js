const http = require("http");
const https = require("https");

// The upstream we proxy. Hardcoded — torrentio has one host.
// If torrentio adds alternate hosts, add them here.
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
    // so resolve redirects also go through this proxy.
    const headers = { ...proxyRes.headers };
    if (headers.location) {
      const proxyOrigin = `http://${clientReq.headers.host}`;
      headers.location = headers.location.replace("https://torrentio.strem.fun", proxyOrigin);
    }
    clientRes.writeHead(proxyRes.statusCode, headers);
    proxyRes.pipe(clientRes);
  });

  proxyReq.on("error", (e) => {
    console.error(`[${new Date().toISOString()}] Proxy error: ${e.message}`);
    clientRes.writeHead(502, { "Content-Type": "text/plain" });
    clientRes.end("Proxy error: " + e.message);
  });

  proxyReq.end();
});

server.listen(PORT, () => {
  console.log(`torrentio proxy listening on :${PORT}`);
});
