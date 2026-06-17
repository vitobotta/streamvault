// Deno Deploy: torrentio proxy
//
// Cloudflare Workers CANNOT proxy torrentio.strem.fun because both are on
// Cloudflare's network — the WAF blocks Worker-originated subrequests.
// Deno Deploy runs on Google Cloud / Deno's own edge, NOT Cloudflare, so
// it can reach torrentio without being blocked.
//
// Deploy:
//   1. Go to https://dash.deno.com → New Playground
//   2. Paste this code, save
//   3. Note the URL: https://<your-project>.deno.dev
//   4. Set env var in .env.vars production():
//      TORRENTIO_API_BASE_URL=https://<your-project>.deno.dev
//   5. Redeploy: production kamal deploy

const UPSTREAM = "https://torrentio.strem.fun";

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  const upstream = new URL(UPSTREAM + url.pathname + url.search);

  const headers = new Headers();
  headers.set("User-Agent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36");
  headers.set("Accept", "application/json, text/html, */*");

  const response = await fetch(upstream, {
    method: req.method,
    headers,
    redirect: "manual", // preserve 302 redirects so the app sees the RealDebrid download URL
  });

  // Pass through the response, rewriting Location headers that point
  // back to torrentio.strem.fun → this proxy, so resolve redirects also
  // go through us instead of hitting Cloudflare directly.
  const newHeaders = new Headers(response.headers);
  const location = newHeaders.get("Location");
  if (location) {
    newHeaders.set("Location", location.replace("https://torrentio.strem.fun", new URL(req.url).origin));
  }

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: newHeaders,
  });
});
