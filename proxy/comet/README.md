# Comet (Self-Hosted Stream Provider)

Self-hosted [Comet](https://github.com/g0ldyy/comet) — a fast torrent/debrid search addon that speaks the same Stremio protocol as Torrentio, but runs on your own VPS. No Cloudflare blocks, no rate limits, no peak-hour congestion.

## Why

Torrentio (the public instance at `torrentio.strem.fun`) is frequently down, Cloudflare-blocked, or rate-limited — especially during evening peak hours. A self-hosted Comet instance on your VPS eliminates all three problems:

| Problem | Public Torrentio | Self-hosted Comet |
|---------|------------------|-------------------|
| Cloudflare 403 blocks | Common (datacentre IPs flagged) | No Cloudflare — direct connection |
| Rate limiting | Public instance throttles all users | Private instance — you're the only user |
| Peak-hour congestion | Evening slowdowns (8 PM CET) | No shared load |
| Scraper diversity | Torrentio's scrapers only | Jackett, Prowlarr, Zilean, Torrentio, more |

StreamVault supports Comet as a first-class stream provider with automatic fallback to Torrentio. When both are configured, streams from both providers are merged and the best one wins — if Comet is down, Torrentio fills in, and vice versa.

## How it works

```
StreamVault → Comet (self-hosted, VPS)          ← primary
            ↘ Torrentio (public, via Tinyproxy)  ← fallback
```

Comet speaks the standard Stremio addon protocol (`/stream/{type}/{id}.json` → `{ "streams": [...] }`), but encodes the RealDebrid API key in a base64 config path segment (`/{b64config}/stream/...`) instead of Torrentio's `/realdebrid={key}/` prefix. StreamVault's `CometService` handles this transparently — `ContentStreamingService` queries all configured providers and merges results.

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Comet + Postgres, healthcheck, persistent volumes |
| `.env.example` | Configuration template — admin password, optional scrapers |
| `Caddyfile` | HTTPS reverse proxy (only needed for Stremio direct install) |

## Deploy on a VPS

### 1. Configure

```bash
cd proxy/comet
cp .env.example .env
```

Edit `.env` — at minimum set a strong admin password:

```bash
ADMIN_DASHBOARD_PASSWORD=your-strong-password
```

### 2. Start

```bash
docker compose up -d
```

Verify it's running:

```bash
docker compose ps
curl http://localhost:8000/health
# → {"status":"ok"}
```

### 3. Configure StreamVault

In StreamVault's `.env`:

```bash
# Comet instance URL (use Tailscale IP for privacy — see below)
COMET_URL=http://<vps-tailscale-ip>:8000

# Comet primary, Torrentio fallback
STREAM_PROVIDER=auto
```

Restart StreamVault. Stream listings now come from Comet first, falling back to Torrentio if Comet is unavailable.

### 4. (Optional) Configure Comet's web UI

Open `http://<vps-ip>:8000/configure` in a browser to set up scrapers (Jackett, Zilean, etc.), quality filters, and debrid settings. The RealDebrid API key is injected by StreamVault per-request via the base64 config path — you don't need to configure it in Comet's UI for StreamVault usage.

To access the admin dashboard: `http://<vps-ip>:8000/admin` (login with `ADMIN_DASHBOARD_PASSWORD`).

## Privacy

When you access StreamVault through Tailscale (which you already use for the Tinyproxy), your home ISP sees **only encrypted WireGuard traffic** — they cannot see Comet, torrent indexers, RealDebrid, or the content. All scraping and downloading happens on the VPS, not in your browser.

| What | Without Tailscale | With Tailscale |
|------|-------------------|----------------|
| Home ISP sees torrent scraping | ✅ (DNS/SNI) | ❌ (encrypted) |
| Home ISP sees RealDebrid | ✅ (SNI) | ❌ (encrypted) |
| Home ISP sees data volume | ✅ | ✅ (indistinguishable from VPN) |
| VPS provider sees scraping | N/A | ✅ (SNI to indexers) |
| VPS provider sees RealDebrid | N/A | ✅ (SNI + bandwidth) |

The VPS provider can see Comet's outbound scraping and RealDebrid traffic (SNI reveals domains, bandwidth is visible), but cannot see the content (HTTPS encrypted). Data centre providers rarely act on traffic patterns — DMCA enforcement targets residential ISPs, not VPS traffic.

## STREAM_PROVIDER modes

| Value | Primary | Fallback | When to use |
|-------|---------|----------|-------------|
| `torrentio` | Torrentio | — | Default, backward-compatible (no Comet needed) |
| `comet` | Comet | Torrentio | Explicit Comet-first with fallback |
| `auto` | Comet (if `COMET_URL` set) | Torrentio | Recommended — best of both |

## HTTPS (for Stremio direct installation)

Stremio requires HTTPS for non-local addon URLs. StreamVault can use HTTP over Tailscale — you only need HTTPS if you want to install Comet directly in the Stremio desktop app.

Add the `Caddyfile` to your existing Caddy setup:

```bash
# In your main Caddyfile, add:
import /path/to/proxy/comet/Caddyfile
```

Replace `comet.example.com` with your domain (DNS A record → VPS IP). Caddy handles TLS automatically.

## Troubleshooting

**`{"status":"ok"}` but no streams in StreamVault** — Comet's scrapers haven't indexed the content yet. The first request for a title triggers a scrape (may take 5-10s). Subsequent requests are cached. Check the admin dashboard for scraper status.

**Connection refused** — Comet isn't running or the port is wrong. Check `docker compose ps` and `docker compose logs comet`. Verify `COMET_URL` in StreamVault's `.env` matches the VPS IP and port.

**StreamVault shows "Could not connect to Comet"** — The VPS isn't reachable from StreamVault. If using Tailscale, verify both machines are on the same Tailnet. If using a public IP, verify port 8000 is open.

**Comet works but StreamVault ignores it** — Check `STREAM_PROVIDER` is set to `auto` or `comet` (not `torrentio`), and `COMET_URL` is set (not commented out). Restart StreamVault after changing `.env`.

**Scrapers not finding content** — Comet supports multiple scrapers. The built-in Torrentio scraper is enabled by default. For broader coverage, add Jackett or Prowlarr via the `/configure` page or `.env`. See [Comet's documentation](https://github.com/g0ldyy/comet/blob/main/.env-sample) for all scraper options.

## Requirements

- A VPS with Docker + Docker Compose (same VPS as Tinyproxy works fine)
- ~256MB RAM for Comet + Postgres
- RealDebrid subscription (same one StreamVault already uses)
- Tailscale (recommended for private access — hides all traffic from your home ISP)

## Resource usage

Comet + Postgres: ~256MB RAM, minimal CPU (scraping is I/O-bound). The SQLite cache keeps repeated lookups instant. Background scraping runs at low priority and doesn't interfere with StreamVault or Tinyproxy on the same VPS.
