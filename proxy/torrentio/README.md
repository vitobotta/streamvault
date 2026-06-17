# Torrentio Proxy

Reverse proxy for `torrentio.strem.fun` that bypasses Cloudflare's WAF IP blocks. Runs on any VPS outside Cloudflare's network.

## Why

`torrentio.strem.fun` is behind Cloudflare. Cloudflare blocks requests from:
- Cloudflare Workers (same network — WAF blocks Worker subrequests)
- Deno Deploy / Vercel edge (shared egress IPs get rate-limited or blocked)
- Some VPS providers (datacentre IP ranges flagged by Cloudflare)

A dedicated VPS with a clean IP reliably reaches torrentio without blocks.

## Files

| File | Purpose |
|------|---------|
| `proxy.js` | Node.js HTTP proxy — rewrites `Location` headers so resolve redirects also go through the proxy |
| `Dockerfile` | Container image |
| `docker-compose.yml` | Orchestration (HTTP or HTTPS via Caddy) |
| `Caddyfile` | Caddy config for automatic Let's Encrypt TLS |

## Deploy on a VPS

### 1. Quick test (HTTP only)

```bash
git clone <your-streamvault-repo> && cd streamvault/torrentio-proxy
docker compose up --build -d
curl http://<vps-ip>:3000/stream/movie/tt0145487.json
```

If you get JSON with streams, the VPS IP isn't blocked.

### 2. Production (HTTPS with a domain)

```bash
# Point DNS A record: torrentio.yourdomain.com → <vps-ip>
export TORRENTIO_DOMAIN=torrentio.yourdomain.com
docker compose --profile https up --build -d
```

Caddy auto-provisions Let's Encrypt certificates. Verify:

```bash
curl https://torrentio.yourdomain.com/stream/movie/tt0145487.json
```

### 3. Configure StreamVault

In `.env.vars` `production()`:

```
TORRENTIO_API_BASE_URL=https://torrentio.yourdomain.com
```

Or in `config/deploy.yml` under `env.clear`:

```yaml
env:
  clear:
    TORRENTIO_API_BASE_URL: https://torrentio.yourdomain.com
```

Redeploy StreamVault:

```bash
production kamal deploy
```

## Requirements

- Any VPS with a clean IP (Hetzner, OVH, Contabo, etc.)
- Docker + Docker Compose
- A domain for HTTPS (optional but recommended)

## Resource usage

~10MB RAM, ~0% CPU. The proxy is a thin TCP relay — no processing, no caching.
