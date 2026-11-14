# Configuration

Every setting is read from `.env` at boot. Copy `.env.example` to `.env`, fill in the required values, and restart the stack after changing anything.

## Required values

| Variable | Description | How to generate |
|---|---|---|
| `SECRET_KEY_BASE` | Session cookie secret | `openssl rand -hex 64` |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | Encrypts API keys at rest | `openssl rand -hex 32` |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | Deterministic encryption key | `openssl rand -hex 32` |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | Key derivation salt | `openssl rand -hex 32` |
| `POSTGRES_PASSWORD` | Password for the bundled Postgres container | `openssl rand -hex 16` |
| `OMDB_API_KEY` | Ratings metadata (IMDb, Rotten Tomatoes, Metacritic) | Free key at [omdbapi.com/apikey.aspx](https://www.omdbapi.com/apikey.aspx) |

Generate each encryption value separately. If you rotate the Active Record Encryption keys after users have saved RealDebrid keys, previously stored keys cannot be decrypted.

## Optional values

| Variable | Description | Default |
|---|---|---|
| `RAILS_MASTER_KEY` | Master key for Rails encrypted credentials. Only needed if you add a credentials file | empty |
| `APP_DOMAIN` | Domain the app is served from. Recommended for public deployments, required for correct host authorisation behind a proxy | empty |
| `ENABLE_SIGNUPS` | Set to `true` to allow self-registration | `false` |
| `NEXT_EPISODE_PROMPT_SECONDS` | Near-end fallback window for the next-episode button, 0 to 600 seconds, capped to the final 10% of an episode. `0` disables the estimate but keeps credits chapter markers | `90` |
| `POSTGRES_USER` | Database user | `streamvault` |
| `POSTGRES_DB` | Database name | `streamvault` |
| `PORT` | Host port to expose the app on. The container always listens on 80 | `3000` |
| `STREAM_PROVIDER` | `torrentio`, `comet`, `aiostreams`, or `auto`. See below | `torrentio` |
| `TORRENTIO_API_BASE_URL` | Torrentio API base URL | `https://torrentio.strem.fun` |
| `COMET_URL` | URL of your self-hosted Comet instance | empty |
| `AIOSTREAMS_URL` | AIOStreams install/manifest URL; the `/manifest.json` suffix is optional | empty |
| `AIOSTREAMS_PROXY` | Forward proxy URL for AIOStreams requests | empty |
| `REALDEBRID_API_BASE_URL` | RealDebrid API base URL | `https://api.real-debrid.com/rest/1.0` |
| `TORBOX_API_BASE_URL` | TorBox API base URL | `https://api.torbox.app/v1/api` |
| `TMDB_READ_ACCESS_TOKEN` | TMDB v4 bearer token for recommendations | empty |
| `SUBDL_API_KEY` | SubDL API key for external subtitle fallback | empty |
| `TORRENTIO_PROXY` | Forward proxy URL for Torrentio requests | empty |
| `CINEMETA_PROXY` | Forward proxy URL for Cinemeta requests | empty |
| `COMET_PROXY` | Forward proxy URL for Comet requests | empty |
| `HTTP_WRITE_TIMEOUT` | Thruster response write deadline in seconds. Keep `0` for movie-length streams | `0` |
| `HTTP_IDLE_TIMEOUT` | Thruster keep-alive idle timeout in seconds. Keep `0` to avoid interrupting reconnects | `0` |

## Stream provider modes

| Value | Primary | Fallback | When to use |
|---|---|---|---|
| `torrentio` | Torrentio | none | Default. Simplest setup, no Comet needed |
| `comet` | Comet | Torrentio | Comet first, with Torrentio as backup |
| `aiostreams` | AIOStreams | Torrentio | Uses your AIOStreams install link, which aggregates your own sources and debrid services |
| `auto` | Comet and AIOStreams, whichever are configured | Torrentio | Recommended. Queries them in parallel and picks the best result |

Torrentio, Comet, and AIOStreams are stream providers. They search torrent networks and return a list with quality, size, and language information. StreamVault does not bundle an indexer and does not ship a catalogue.

## Proxies: when you might need one

Some upstream services sit behind Cloudflare, which may block requests from datacentre IP ranges. If you see 403 errors, empty stream lists, or intermittent provider failures, you likely need a proxy.

### The two-server setup

The author's deployment separates compute from network access:

```
┌─────────────────────────────────────┐             ┌──────────────────────────────────┐
│  Dedicated server (powerful)        │             │  Cheap VPS (clean IP)            │
│                                     │             │                                  │
│  • StreamVault (Rails app)          │  Tailscale  │  • Torrentio proxy (Tinyproxy)   │
│  • PostgreSQL                       │ ◄─────────► │  • Comet (self-hosted)           │
│  • FFmpeg (transcoding)             │   tunnel    │  • Jackett (torrent indexer)     │
│                                     │             │                                  │
│  Why: needs CPU/RAM for transcoding │             │  Why: clean IP not blocked by    │
│  and bandwidth for streaming        │             │  Cloudflare; cheap to run        │
└─────────────────────────────────────┘             └──────────────────────────────────┘
```

- **Dedicated server** runs StreamVault, PostgreSQL, and FFmpeg. It needs enough CPU and RAM for smooth transcoding.
- **Cheap VPS** runs the Torrentio proxy and optionally Comet. Proxies use about 5 MB of RAM; Comet uses about 512 MB.
- **Tailscale** connects both machines over an encrypted WireGuard tunnel. No ports need to be opened. The app reaches the proxy through its Tailscale IP.

### Torrentio proxy (Tinyproxy)

A lightweight forward proxy that routes Torrentio and Cinemeta requests through a VPS with a clean IP. It uses about 5 MB of RAM and handles HTTPS transparently. Tinyproxy is locked down with an IP allowlist and a domain whitelist, so it can only reach Torrentio and Cinemeta.

Set `TORRENTIO_PROXY` to the proxy URL. Full instructions: [`proxy/torrentio/README.md`](../proxy/torrentio/README.md).

### Comet (self-hosted provider)

A self-hosted alternative to Torrentio that uses its own scrapers (Jackett and Zilean) instead of the Torrentio API. No Cloudflare dependency, no rate limits, no peak-hour congestion.

Set `COMET_URL` and `STREAM_PROVIDER=auto`. Full instructions, including Jackett indexer configuration: [`proxy/comet/README.md`](../proxy/comet/README.md).

### Tailscale proxy (VPS to home)

If you run StreamVault at home, where the residential IP is not blocked and RealDebrid is happier, but want a public HTTPS URL, put Caddy on a VPS and tunnel traffic to the home machine over Tailscale.

Full instructions: [`proxy/app/README.md`](../proxy/app/README.md).

### Do you need a proxy?

| Your setup | Proxy needed? |
|---|---|
| Running at home on a residential IP | Usually no |
| VPS with a clean IP | Try first. If you get 403s or empty streams, add the Torrentio proxy |
| VPS with a blocked IP | Yes, use the Torrentio proxy or self-host Comet |
| Dedicated server with a blocked IP | Yes, run the app on the dedicated server and proxy through a cheap VPS |

## Troubleshooting

Start with container status, logs, and the health endpoint:

```bash
docker compose ps
docker compose logs --tail=200 -f web
curl -I http://localhost:${PORT:-3000}/up
```

| Symptom | What to check |
|---|---|
| No streams, 403s, or intermittent provider failures | Your server IP may be blocked by Cloudflare. See the proxy sections above |
| Playback buffers during transcoding | Check CPU saturation and FFmpeg throughput in the web logs. Try a 1080p H.264 source before a 4K, HEVC, or AV1 source |
| Direct play works but a resumed stream is CPU-heavy | Expected. A non-zero seek may re-encode video to keep audio and video aligned |
| Subtitles appear slowly on a remote file | The first extraction may need to seek through a large container. Transient extraction timeouts are retried automatically |
| Sign-in does not persist behind a proxy | Confirm the public URL uses HTTPS and that the proxy forwards the original scheme and host. Production cookies are Secure |

## Reverse proxy notes

StreamVault streams for the length of a film, so disable response buffering in whatever sits in front of it:

- Nginx: `proxy_buffering off;` and `proxy_read_timeout` longer than the longest expected stream.
- Caddy: reverse proxy defaults are fine, but set a long `flush_interval` or `-1` for streaming responses.
- Cloudflare: proxying long-lived media responses through the free plan will time out. Stream through a DNS-only record or a direct origin.
