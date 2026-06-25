# Comet (Self-Hosted Stream Provider)

Self-hosted [Comet](https://github.com/g0ldyy/comet) — a fast torrent/debrid search addon that speaks the same Stremio protocol as Torrentio, but runs on your own VPS with **independent scrapers**. No Cloudflare blocks, no rate limits, no peak-hour congestion, no dependency on the Torrentio API.

## Why

Torrentio (the public instance at `torrentio.strem.fun`) is frequently down, Cloudflare-blocked, or rate-limited — especially during evening peak hours. A self-hosted Comet instance on your VPS eliminates all three problems by using its own scrapers (Jackett + Zilean) instead of the Torrentio API:

| Problem | Public Torrentio | Self-hosted Comet |
|---------|------------------|-------------------|
| Cloudflare 403 blocks | Common (datacentre IPs flagged) | No Cloudflare — Jackett scrapes directly |
| Rate limiting | Public instance throttles all users | Private instance — you're the only user |
| Peak-hour congestion | Evening slowdowns (8 PM CET) | No shared load |
| Torrentio API dependency | Single point of failure | Independent — doesn't use Torrentio at all |

StreamVault uses Comet as the primary stream source with Torrentio as fallback. When both are configured, streams from both providers are queried in parallel and the best one wins — if Comet is down, Torrentio fills in, and vice versa.

## How it works

```
StreamVault → Comet (self-hosted, VPS)              ← primary
               ├─ Jackett (self-hosted scrapers)     ← 1337x, TPB, etc.
               └─ Zilean (DMM hashlist index)        ← pre-computed hashes
            ↘ Torrentio (public, via Tinyproxy)      ← fallback only
```

Comet speaks the standard Stremio addon protocol (`/stream/{type}/{id}.json` → `{ "streams": [...] }`), but encodes the RealDebrid API key in a base64 config path segment (`/{b64config}/stream/...`) instead of Torrentio's `/realdebrid={key}/` prefix. StreamVault's `CometService` handles this transparently — `ContentStreamingService` queries all configured providers in parallel and merges results.

### Scrapers

Comet is configured with two independent scrapers — **neither uses the Torrentio API**:

| Scraper | What it does | Setup required |
|---------|-------------|----------------|
| **Jackett** | Self-hosted indexer aggregator. Scrapes torrent sites directly (1337x, TPB, TorrentGalaxy, etc.). | Yes — get API key after first start, configure indexers at `:9117` |
| **Zilean** | DMM hashlist index. Uses pre-computed torrent hashes from DebridMediaManager. | No — public instance works out of the box |

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Comet + Postgres + Jackett, healthchecks, persistent volumes |
| `.env.example` | Configuration template — admin password, scraper settings |
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

### 2. Start (first boot — Jackett needs initialising)

```bash
docker compose up -d
```

Wait ~30 seconds for Jackett to initialise, then get its API key:

```bash
docker compose exec jackett bash -c "cat /config/Jackett/ServerConfig.json | jq -r .APIKey"
```

Add the API key to `.env`:

```bash
JACKETT_API_KEY=<the-key-from-above>
```

Restart Comet to pick up the key:

```bash
docker compose up -d
```

### 3. (Optional) Configure Jackett indexers

Open `http://<vps-ip>:9117` in a browser. Jackett ships with several public indexers pre-configured. Add or remove indexers as desired — more indexers mean broader search coverage but slower scrapes.

You don't need to configure RealDebrid in Jackett — Comet handles RD resolution itself. Jackett only searches for torrents; Comet takes the results and checks RD cache.

### 4. Verify

```bash
# Comet health
curl http://localhost:8000/health
# → {"status":"ok"}

# Test stream search (should return streams via Jackett/Zilean)
curl -s 'http://localhost:8000/stream/movie/tt1375666.json' | python3 -m json.tool | head -20
```

If you get `"streams": []`, the scrapers are still indexing — wait a minute and try again. If still empty, check the Comet logs: `docker compose logs comet`.

### 5. Configure StreamVault

In StreamVault's `.env`:

```bash
# Comet instance URL (use Tailscale IP for privacy — see below)
COMET_URL=http://<vps-tailscale-ip>:8000

# Comet primary, Torrentio fallback
STREAM_PROVIDER=auto
```

Restart StreamVault. Stream listings now come from Comet (via Jackett + Zilean) first, falling back to Torrentio only if Comet is unavailable.

### 6. (Optional) Enable background scraper

Pre-caches popular content so first searches resolve instantly. Add to `.env`:

```bash
BACKGROUND_SCRAPER_ENABLED=True
BACKGROUND_SCRAPER_CONCURRENT_WORKERS=1
```

Increases RAM/CPU usage slightly but eliminates first-request delays.

## Privacy

When you access StreamVault through Tailscale (which you already use for the Tinyproxy), your home ISP sees **only encrypted WireGuard traffic** — they cannot see Comet, Jackett, torrent indexers, RealDebrid, or the content. All scraping and downloading happens on the VPS, not in your browser.

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

**`{"status":"ok"}` but no streams** — Scrapers haven't indexed the content yet. First requests trigger a live scrape (5-10s via Jackett). Check `docker compose logs comet` for scraper errors. Verify the Jackett API key is set correctly in `.env`.

**Jackett API key not found** — Jackett hasn't finished initialising. Wait 30s and try again. If still failing, check `docker compose logs jackett`.

**Connection refused** — Comet or Jackett isn't running. Check `docker compose ps` and `docker compose logs comet`.

**StreamVault shows "Could not connect to Comet"** — The VPS isn't reachable. If using Tailscale, verify both machines are on the same Tailnet. If using a public IP, verify port 8000 is open.

**Comet works but StreamVault ignores it** — Check `STREAM_PROVIDER` is set to `auto` or `comet` (not `torrentio`), and `COMET_URL` is set. Restart StreamVault after changing `.env`.

**Streams are slow on first search** — Normal. Jackett scrapes torrent sites live on first request. Subsequent searches are cached. Enable the background scraper to pre-cache popular content.

## Requirements

- A VPS with Docker + Docker Compose (same VPS as Tinyproxy works fine)
- ~512MB RAM (Comet + Postgres + Jackett)
- RealDebrid subscription (same one StreamVault already uses)
- Tailscale (recommended for private access — hides all traffic from your home ISP)

## Resource usage

- **Comet + Postgres**: ~256MB RAM, minimal CPU
- **Jackett**: ~128MB RAM, CPU spikes during active scraping
- **Zilean**: no local resource (uses public instance)
- Background scraper adds ~50MB RAM when enabled
