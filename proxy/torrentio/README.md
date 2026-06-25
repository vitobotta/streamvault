# Torrentio Proxy (Tinyproxy)

Forward proxy that routes torrentio / Cinemeta requests through a VPS with a clean IP, bypassing Cloudflare WAF blocks. Runs on any VPS outside Cloudflare's network.

## Why

`torrentio.strem.fun` is behind Cloudflare. Cloudflare blocks requests from:
- Cloudflare Workers (same network — WAF blocks Worker subrequests)
- Deno Deploy / Vercel edge (shared egress IPs get rate-limited or blocked)
- Some VPS providers (datacentre IP ranges flagged by Cloudflare)

A dedicated VPS with a clean IP reliably reaches torrentio without blocks. The app sends requests through this proxy via the `TORRENTIO_PROXY` env var — no app code changes required.

## How it works

StreamVault's `TorrentioService` reads `ENV["TORRENTIO_PROXY"]` and applies it to both its API connection and the resolve-URL follow connection. Set `TORRENTIO_API_BASE_URL` to the real torrentio URL (`https://torrentio.strem.fun`) and `TORRENTIO_PROXY` to this proxy. Tinyproxy transparently handles HTTPS `CONNECT` tunneling — no custom `Location` header rewriting, no per-service logic.

## Files

| File | Purpose |
|------|---------|
| `tinyproxy.conf` | Tinyproxy config — port, IP allowlist, domain whitelist, stealth mode |
| `filter` | Domain whitelist — only torrentio and Cinemeta are allowed |
| `Dockerfile` | Alpine image with tinyproxy |
| `docker-compose.yml` | Orchestration (uses `network_mode: host` for correct client IP visibility) |

## Deploy on a VPS

### 1. Configure access control

Edit `tinyproxy.conf`:

```conf
# ── Allow: IP-based access control ───────────────────────────────
# Only listed IPs/CIDRs can use the proxy.
# When any Allow line is present, all other IPs are denied by default.
Allow 127.0.0.1
Allow <your-dedicated-server-tailscale-ip>
# Allow 192.168.1.0/24   # CIDR range example
```

Each `Allow` line takes a single IP address or CIDR range. When any `Allow` line is present, all other IPs are denied by default — you don't need an explicit `Deny` rule.

**Tailscale-only (recommended):** Set `Listen` to your VPS's Tailscale IP instead of `0.0.0.0`. The port becomes invisible on the public interface — only authenticated Tailscale devices can reach it:

```conf
Listen 100.x.x.x
```

### 2. Configure domain whitelist

The `filter` file restricts which domains the proxy will forward. It uses shell-glob (`fnmatch`) matching — `*.strem.fun` matches all subdomains of `strem.fun`. The default allows only torrentio and Cinemeta:

```
torrentio.strem.fun
v3-cinemeta.strem.io
```

To add another domain, append it to the `filter` file and restart:

```bash
echo "another-api.example.com" >> filter
docker compose restart
```

The `FilterDefaultDeny Yes` directive in `tinyproxy.conf` makes this a whitelist — any domain not listed is blocked.

### 3. Start the proxy

```bash
git clone <your-streamvault-repo> && cd streamvault/proxy/torrentio
docker compose up -d --build
```

Verify from an allowed IP:

```bash
curl -x http://<vps-ip>:8888 https://torrentio.strem.fun/stream/movie/tt0145487.json
```

If you get JSON with streams, the proxy works.

### 4. Configure StreamVault

Set these in your `.env` (or `config/deploy.yml` under `env.clear`):

```bash
# Use the real torrentio URL — the proxy handles routing transparently
TORRENTIO_API_BASE_URL=https://torrentio.strem.fun

# Point at the proxy. Use the VPS's Tailscale IP if Tailscale-only.
TORRENTIO_PROXY=http://<vps-ip>:8888
```

Redeploy StreamVault:

```bash
production kamal deploy
```

## Security

This proxy is locked down with two layers:

1. **IP allowlist (`Allow`)** — Only listed IPs can connect. Default-deny when any `Allow` line is present.
2. **Domain whitelist (`Filter` + `FilterDefaultDeny Yes`)** — Only torrentio and Cinemeta domains are forwarded. Prevents the proxy from being used as an open relay for arbitrary sites.

Additional hardening (already configured):
- `DisableViaHeader Yes` — Stealth mode. The `Via` header is not added, so Cloudflare can't detect proxy traffic.
- `ConnectPort 443` — Only HTTPS `CONNECT` tunneling is allowed. Blocks non-HTTPS proxying.
- `network_mode: host` — Required so tinyproxy sees real client IPs for the `Allow` directive (Docker's bridge network NATs source IPs, which would break IP-based access control).

## Troubleshooting

**403 Forbidden from the proxy** — Your client IP isn't in the `Allow` list. Add it to `tinyproxy.conf` and restart.

**403 Forbidden from torrentio** — Cloudflare is still blocking the VPS IP. Try a different VPS provider (Hetzner, OVH, Contabo tend to have clean IPs).

**Connection refused** — The proxy isn't running or `Listen` is bound to an IP that doesn't exist on the VPS. Check `docker compose logs`.

**Proxy works but app gets no streams** — Verify `TORRENTIO_API_BASE_URL` is set to `https://torrentio.strem.fun` (not the proxy URL). The proxy is a forward proxy, not a reverse proxy — the app must connect to the real URL *through* the proxy.

## Requirements

- Any VPS with a clean IP (Hetzner, OVH, Contabo, etc.)
- Docker + Docker Compose
- Tailscale (optional but recommended for secure access without exposing a public port)

## Resource usage

~5MB RAM, ~0% CPU. Tinyproxy is a thin TCP relay — no processing, no caching.
