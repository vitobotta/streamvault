// Cloudflare Worker: torrentio proxy
//
// Deploys a reverse proxy for torrentio.strem.fun on Cloudflare's edge
// network. Since the Worker runs on Cloudflare, it bypasses the WAF
// block that prevents the production server from reaching torrentio
// directly.
//
// Deploy:
//   1. Go to https://dash.cloudflare.com → Workers & Pages → Create
//   2. Name it "torrentio-proxy", paste this code, deploy
//   3. Set env var in .env.vars production():
//      TORRENTIO_API_BASE_URL=https://torrentio-proxy.<your-subdomain>.workers.dev
//   4. Redeploy: production kamal deploy

const UPSTREAM = "https://torrentio.strem.fun";

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const upstream = new URL(UPSTREAM + url.pathname + url.search);

    const headers = new Headers(request.headers);
    headers.set("Host", "torrentio.strem.fun");
    // Cloudflare Workers set their own User-Agent; let the upstream see a browser-like one
    headers.set("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36");

    const response = await fetch(upstream, {
      method: request.method,
      headers,
      redirect: "manual", // preserve 302 redirects so the app sees the RealDebrid download URL
    });

    // Pass through the response, including redirect Location headers
    const newHeaders = new Headers(response.headers);
    // Rewrite Location headers that point to torrentio.strem.fun → this Worker
    const location = newHeaders.get("Location");
    if (location) {
      newHeaders.set("Location", location.replace("https://torrentio.strem.fun", new URL(request.url).origin));
    }

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: newHeaders,
    });
  },
};
