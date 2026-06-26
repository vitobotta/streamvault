<p align="center">
  <img src="public/icon.png" width="120" height="120" alt="StreamVault logo">
</p>

<h1 align="center">StreamVault</h1>

<p align="center"><em>Your personal cinema — search, stream, and manage movies and TV shows, all in one place.</em></p>

---

## What is StreamVault?

StreamVault is a self-hosted media streaming application that lets you discover, organise, and watch media content directly in your browser — your own personal streaming hub.

It works with any content available via torrent networks, including **fully legal content**: public domain films and Creative Commons releases. StreamVault integrates with **RealDebrid**, a legitimate premium service that caches torrents on high-speed servers and provides direct streaming links — the same service used by Stremio and other media centres.

Behind the scenes, StreamVault acts as a client: it searches for available streams, sends a magnet link to RealDebrid (which handles the download on its own infrastructure), and then streams the file to your browser in real time, handling format conversion automatically so everything "just plays." StreamVault itself never downloads, stores, or distributes any media files.

## Disclaimer & responsible use

StreamVault is a **general-purpose media client** — like a web browser or BitTorrent client, it is neutral regarding what users choose to access. The application does not host, store, upload, or distribute any copyrighted content. It does not contain any pre-configured lists of pirated material. All content discovery and streaming is driven by the user's own choices and subscriptions.

**The author does not endorse, encourage, or support the use of StreamVault to access copyrighted content without proper authorisation.** Users are solely responsible for ensuring they have the legal right to access any content they stream. StreamVault is intended for use with:

- Public domain films and media
- Creative Commons and open-licensed content
- Any other content the user has the legal right to access

This project is provided as-is for educational and personal use. The author accepts no responsibility for how the application is used.

## How it works

```
You (browser)
  │
  ▼
StreamVault (Rails app + FFmpeg)
  │
  ├──► Torrentio / Comet  →  finds available streams for the content
  │
  ├──► RealDebrid         →  caches the file on their servers, gives back a direct streaming link
  │
  └──► FFmpeg             →  converts the file on-the-fly to a browser-friendly format
                             (MKV → MP4, DTS/AC3 → AAC, burns subtitles if needed)
```

1. **Search** — Type a title. StreamVault queries metadata catalogues (Cinemeta) and returns matching content with posters, ratings, and plots.
2. **Pick a stream** — Each title shows a list of available streams with quality (4K, 1080p, 720p), file size, and audio languages. Streams are sorted by your language preferences.
3. **Press play** — StreamVault sends the magnet link to RealDebrid, which caches the file on its servers and returns a direct streaming link. If the file is already in a browser-friendly format (MP4 with AAC audio), it plays directly. If not (MKV, DTS audio, exotic codecs), FFmpeg transcodes it on-the-fly.
4. **Watch** — The custom in-browser player handles playback with seeking, audio track switching, subtitles, and progress tracking. Close the tab and come back later — you'll resume right where you left off.

## Features

### Discovery & browsing
- **Search** — Find any movie or TV show by title, with rich metadata: posters, plots, cast, genres, age ratings.
- **Ratings** — IMDb, Rotten Tomatoes, and Metacritic scores displayed on every title (via OMDB).
- **Popular & Trending** — Browse what's popular and trending right now, for both movies and shows.
- **Recommendations** — A "Recommended for You" carousel that learns from your watch history using TMDB's collaborative filtering ("viewers also watched…").
- **Content detail pages** — Full overview with poster, plot, cast, ratings, and available streams.

### Library management
- **Library** — Add movies and shows to your personal library. Track what you've watched and what's pending.
- **Wishlist** — Save content for later. Move items to your library when you're ready to watch.
- **Watch History** — See everything you've watched, with progress indicators. Clear history anytime.
- **Continue Watching** — Resume any title from where you left off, right from the home page.

### TV show support
- **Season & episode browser** — Browse seasons and episodes with air dates, overviews, and progress tracking per episode.
- **Episode streaming** — Stream individual episodes with the same quality and language options as movies.
- **Auto-advance** — When an episode finishes, the next one is ready to go.

### Streaming & playback
- **Custom video player** — Built from scratch with seeking, volume control, playback speed, and full keyboard support.
- **Audio track selection** — Switch between audio languages when a stream has multiple tracks.
- **Subtitles** — Select from embedded subtitle tracks (text and image-based). Falls back to external subtitles from SubDL when none are embedded.
- **Burned subtitles** — Image-based subtitles (PGS, VobSub) are burned onto the video via FFmpeg since browsers can't render them natively.
- **Resume playback** — Automatically resumes from your last position.
- **Stall recovery** — If a stream stalls, the player attempts automatic recovery before failing.
- **Progress tracking** — Watch progress is saved every few seconds and synced across sessions.

### Personalisation
- **Language preferences** — Choose your preferred audio languages (16 supported). Streams are filtered and sorted to prioritise your languages.
- **Default language** — Set which language is selected by default when starting a stream.
- **Per-user configuration** — Each user has their own library, history, wishlist, and settings. API keys are encrypted at rest.

### Interface
- **Dark theme** — Easy on the eyes, with an indigo-violet accent on dark neutral surfaces.
- **Responsive** — Sidebar navigation on desktop, bottom navigation bar on mobile.
- **Installable PWA** — Add StreamVault to your home screen for a full-screen, app-like experience.
- **Carousels** — Horizontally scrollable content rows with smooth navigation buttons.

## Integrations & services

StreamVault relies on several external services. Here's what each one does and how to get set up:

| Service | Role | Required? | How to get access |
|---------|------|-----------|-------------------|
| **RealDebrid** | Caches files on their servers and provides direct streaming links — a legitimate premium service also used by Stremio | **Yes** — streaming won't work without it | Sign up at [real-debrid.com](https://real-debrid.com), then get your API key at [real-debrid.com/apitoken](https://real-debrid.com/apitoken) |
| **Torrentio** | Finds available streams for a given title | Yes (default provider) | Works out of the box with the public instance. May need a proxy if your server IP is blocked (see below) |
| **Comet** | Alternative stream provider — self-hosted, independent of Torrentio | Optional (recommended) | Self-host via Docker — see [proxy/comet](proxy/comet) |
| **Cinemeta** | Provides content metadata (titles, posters, plots, episodes) | Yes (built-in) | No setup needed — uses the public Stremio metadata service |
| **OMDB** | Enriches content with IMDb, Rotten Tomatoes, and Metacritic ratings | Yes | Get a free API key at [omdbapi.com/apikey.aspx](https://www.omdbapi.com/apikey.aspx) |
| **TMDB** | Powers the "Recommended for You" feature using your watch history | Optional | Create an account at [themoviedb.org](https://www.themoviedb.org), then get a Read Access Token at [themoviedb.org/settings/api](https://www.themoviedb.org/settings/api) |
| **SubDL** | Provides external subtitles when embedded ones aren't available | Optional | Get a free API key at [subdl.com/panel/api](https://subdl.com/panel/api) |

### How the services work together

- **Torrentio and Comet** are both stream *providers*. They search torrent networks for available streams and return a list with quality, size, and language information. You can use either one or both — when both are configured (`STREAM_PROVIDER=auto`), StreamVault queries them in parallel and picks the best stream regardless of which provider found it. If one is down, the other fills in.

- **RealDebrid** is the *downloader*. Once you pick a stream, StreamVault sends its magnet link to RealDebrid, which retrieves the file on its high-speed servers (from cache if available). RealDebrid then returns a direct HTTPS link that StreamVault can stream from. The file is never downloaded to your server — RealDebrid handles all of that on its infrastructure.

- **FFmpeg** is the *translator*. Many media files use formats (MKV containers, DTS/AC3 audio, PGS subtitles) that web browsers can't play. FFmpeg runs on your server and converts the stream on-the-fly into browser-friendly MP4 with AAC audio. If the video is already compatible, FFmpeg just remuxes (copies without re-encoding) for minimal CPU usage. If the video is in an exotic codec or 4K, it transcodes to 1080p H.264.

- **Cinemeta and OMDB** are the *librarians*. Cinemeta (Stremio's metadata service) provides titles, posters, plots, cast, and episode lists. OMDB adds ratings from IMDb, Rotten Tomatoes, and Metacritic.

- **TMDB** is the *recommender*. It looks at what you've watched and finds similar content that other viewers enjoyed — powering the "Recommended for You" carousel.

- **SubDL** is the *subtitle backup*. When a stream has no embedded subtitles, StreamVault fetches external ones from SubDL so you always have subtitles available.

## Deployment

### Minimum server requirements

The most demanding component is **FFmpeg transcoding**, which happens on-the-fly when a stream needs format conversion. For smooth playback:

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| **CPU** | 2 cores | 4+ cores (transcoding 1080p in real time is CPU-intensive) |
| **RAM** | 2 GB | 4 GB+ (Rails + Postgres + FFmpeg + jemalloc) |
| **Storage** | 10 GB | 20 GB+ (Postgres data, logs, Docker images) |
| **Network** | 50 Mbps | 100 Mbps+ (streaming bandwidth) |
| **OS** | Any Linux with Docker | Ubuntu/Debian LTS |

> **Note on transcoding:** FFmpeg uses the `ultrafast` H.264 preset to minimise CPU load. When the source video is already H.264 with AAC audio in an MP4 container, no transcoding occurs — the stream is remuxed (near-zero CPU). The heavier cases are 4K/UHD sources (transcoded to 1080p) and non-H.264 codecs (x265, AV1), which require real-time video encoding. On Apple Silicon servers, hardware acceleration via VideoToolbox is used automatically when available.

### Prerequisites

- A server or VPS with **Docker** and **Docker Compose** installed
- A **RealDebrid subscription** (starts at ~€3/month)
- API keys for **OMDB** (free) and optionally **TMDB** (free) and **SubDL** (free)

### Steps

```bash
# Clone the repository
git clone https://github.com/vitobotta/StreamVault.git
cd StreamVault

# Create environment config
cp .env.example .env

# Edit .env and fill in all values — see the table below
nano .env

# Build and start the container
docker compose up -d --build
```

The app is available at `http://localhost:${PORT:-3000}`.

Assets are precompiled inside the image during build — no local Ruby or Node installation needed. The PostgreSQL database is persisted in a local `./data` directory and survives container rebuilds.

### Create your first user

Sign-ups are disabled by default for security. Create your user via the Rails console:

```bash
docker compose exec web bin/rails c
> User.create!(email: "you@example.com", password: "password", password_confirmation: "password")
```

To enable self-registration, set `ENABLE_SIGNUPS=true` in `.env` and restart.

### Configure your RealDebrid key

After logging in, go to **Settings** and enter your RealDebrid API key. The app verifies the key automatically and shows a confirmation. Your key is encrypted at rest using Active Record Encryption — it never appears in logs or is transmitted in plain text.

### Auto-start on boot

Containers restart automatically after crashes and system reboots (`restart: unless-stopped`). Ensure the Docker daemon is enabled at boot:

```bash
sudo systemctl enable docker
```

### Updating

```bash
git pull
docker compose up -d --build
```

### Environment variables

| Variable | Description | Default |
|---|---|---|
| `RAILS_MASTER_KEY` | Master key for credentials decryption (from `config/master.key`) | Required |
| `SECRET_KEY_BASE` | Session cookie secret (generate with `bin/rails secret`) | Required |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | Encryption key for API keys (generate with `openssl rand -hex 32`) | Required |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | Deterministic encryption key (generate with `openssl rand -hex 32`) | Required |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | Key derivation salt (generate with `openssl rand -hex 32`) | Required |
| `APP_DOMAIN` | Domain the app is served from (for Rails host authorisation) | Required |
| `ENABLE_SIGNUPS` | Set to `true` to allow new user registration | `false` |
| `POSTGRES_USER` | PostgreSQL database user | `streamvault` |
| `POSTGRES_PASSWORD` | PostgreSQL database password (generate with `openssl rand -hex 16`) | Required |
| `POSTGRES_DB` | PostgreSQL database name | `streamvault` |
| `PORT` | Host port to expose the app on | `3000` |
| `STREAM_PROVIDER` | Which stream provider to use: `torrentio`, `comet`, or `auto` (see below) | `torrentio` |
| `TORRENTIO_API_BASE_URL` | Torrentio API base URL | `https://torrentio.strem.fun` |
| `COMET_URL` | URL of your self-hosted Comet instance | Optional |
| `REALDEBRID_API_BASE_URL` | RealDebrid API base URL | `https://api.real-debrid.com/rest/1.0` |
| `OMDB_API_KEY` | OMDB API key for ratings metadata | Required |
| `TMDB_READ_ACCESS_TOKEN` | TMDB v4 bearer token for recommendations | Optional |
| `SUBDL_API_KEY` | SubDL API key for external subtitle fallback | Optional |
| `TORRENTIO_PROXY` | Forward proxy URL for Torrentio requests (if IP is blocked) | Optional |
| `CINEMETA_PROXY` | Forward proxy URL for Cinemeta requests (if needed) | Optional |
| `COMET_PROXY` | Forward proxy URL for Comet requests (if needed) | Optional |

## Proxies: when and why you might need them

Some of the services StreamVault uses are behind **Cloudflare**, which may block requests coming from datacentre IP ranges (common with VPS providers). If you see 403 errors or empty stream lists, you likely need a proxy.

### The Torrentio problem

The public Torrentio instance (`torrentio.strem.fun`) is behind Cloudflare. Cloudflare frequently blocks or rate-limits requests from datacentre IPs — meaning your VPS might not be able to reach it. Symptoms include 403 errors, empty stream lists, or intermittent failures during peak hours.

### The solution: a two-server setup

The author's deployment uses a **two-server architecture** that separates compute from network access:

```
┌─────────────────────────────────────┐             ┌──────────────────────────────────┐
│  Dedicated server (powerful)        │             │  Cheap VPS (clean IP)            │
│                                     │             │                                  │
│  • StreamVault (Rails app)          │  Tailscale  │  • Torrentio proxy (Tinyproxy)   │
│  • PostgreSQL                       │ ◄─────────► │  • Comet (self-hosted)           │
│  • FFmpeg (transcoding)             │   tunnel    │  • Jackett (torrent indexer)     │
│                                     │             │                                  │
│  Why: needs CPU/RAM for transcoding │             │  Why: clean IP not blocked by    │
│  and bandwidth for streaming        │             │  Cloudflare; cheap to run         │
└─────────────────────────────────────┘             └──────────────────────────────────┘
```

- **Dedicated server** (e.g. Hetzner dedicated, OVH Eco) — runs StreamVault, PostgreSQL, and FFmpeg. This machine needs enough CPU and RAM for smooth transcoding. Its IP may or may not be blocked by Cloudflare — that's fine, because it doesn't talk to Torrentio directly.

- **Cheap VPS** (e.g. €3–5/month from a provider with clean IPs) — runs the Torrentio proxy and/or Comet. This machine's IP is not blocked by Cloudflare, so it can reach Torrentio. It's lightweight (proxies use ~5 MB RAM; Comet uses ~512 MB).

- **Tailscale** (free for personal use) — connects both machines securely over an encrypted WireGuard tunnel. No ports need to be opened on either machine — Tailscale handles it. The app on the dedicated server reaches the proxy on the VPS via its Tailscale IP (`100.x.x.x`).

### Proxy options

StreamVault includes three proxy setups in the `proxy/` directory:

#### 1. Torrentio Proxy (Tinyproxy)

A lightweight forward proxy that routes Torrentio and Cinemeta requests through a VPS with a clean IP. Uses ~5 MB RAM, handles HTTPS transparently.

- **When you need it:** Your server's IP is blocked by Cloudflare (403 errors, empty stream lists).
- **How it works:** StreamVault sends requests *through* the proxy (via `TORRENTIO_PROXY` env var). The proxy forwards them to Torrentio. Tinyproxy is locked down with an IP allowlist and domain whitelist — it can only reach torrentio and Cinemeta domains.
- **Setup:** See [`proxy/torrentio/README.md`](proxy/torrentio/README.md) for full instructions.

#### 2. Comet (self-hosted stream provider)

A self-hosted alternative to Torrentio that uses its own scrapers (Jackett + Zilean) instead of the Torrentio API. No Cloudflare dependency, no rate limits, no peak-hour congestion.

- **When you need it:** Torrentio is unreliable (frequent blocks, rate limits, downtime) or you want a more stable stream source.
- **How it works:** Comet runs on your VPS and scrapes torrent indexers directly. StreamVault queries Comet first (`STREAM_PROVIDER=auto`), falling back to Torrentio only if Comet is unavailable.
- **Setup:** See [`proxy/comet/README.md`](proxy/comet/README.md) for full instructions, including Jackett indexer configuration.

#### 3. Tailscale Proxy (VPS → home)

If you run StreamVault on your home computer (which has a residential IP that RealDebrid prefers) but want a public URL with TLS, this setup puts Caddy on a VPS and tunnels traffic to your home machine via Tailscale.

- **When you need it:** You're running the app at home but want a public HTTPS URL without exposing your home network.
- **Setup:** See [`proxy/app/README.md`](proxy/app/README.md) for full instructions.

### Do you need a proxy?

| Your setup | Proxy needed? |
|-----------|---------------|
| Running at home (residential IP) | Usually no — residential IPs aren't blocked by Cloudflare |
| VPS with a clean IP | Try first — if you get 403s or empty streams, set up the Torrentio proxy |
| VPS with a blocked IP | Yes — set up the Torrentio proxy or self-host Comet |
| Dedicated server with blocked IP | Yes — run the app on the dedicated server, proxy through a cheap VPS |

### STREAM_PROVIDER modes

| Value | Primary | Fallback | When to use |
|-------|---------|----------|-------------|
| `torrentio` | Torrentio | — | Default, simplest setup (no Comet needed) |
| `comet` | Comet | Torrentio | Explicit Comet-first with Torrentio fallback |
| `auto` | Comet (if `COMET_URL` set) | Torrentio | **Recommended** — best of both worlds |

## Testing

```bash
# Run all tests (requires local Ruby + bundler setup)
bundle install
bundle exec rspec

# Run specific test types
bundle exec rspec spec/models/      # Model specs
bundle exec rspec spec/services/    # Service specs
bundle exec rspec spec/policies/    # Policy specs
bundle exec rspec spec/requests/    # Request specs
```

## Architecture

```
app/
├── controllers/     # Home, search, content, library, wishlist, streaming, settings, episodes, transcode
├── models/          # User, LibraryEntry, WatchHistoryEntry, WishlistEntry, EpisodeProgress
├── services/        # Business logic (see below)
├── policies/        # ActionPolicy authorisation — all resources scoped per-user
├── javascript/      # Stimulus controllers (video player, carousels, language picker, etc.)
└── views/           # Dark-themed Tailwind views with Turbo Drive
```

### Services

| Service | Role |
|---------|------|
| **TorrentioService** | Searches content via Cinemeta, fetches streams from Torrentio, enriches with OMDB ratings |
| **CometService** | Fetches streams from a self-hosted Comet instance (independent of Torrentio) |
| **StreamProvider** | Factory that returns the configured provider(s) with fallback ordering |
| **RealDebridService** | Manages RealDebrid API: add magnets, select files, get streaming links, verify keys |
| **ContentStreamingService** | Orchestrates the full streaming flow: fetch streams → resolve best candidate → verify link |
| **TranscodeService** | FFmpeg-based transcoding: MKV→MP4, audio→AAC, subtitle extraction/burning, video normalisation |
| **ProgressTrackingService** | Saves watch progress, auto-advances episodes, builds the "Continue Watching" list |
| **RecommendationService** | Generates "Recommended for You" from watch history via TMDB collaborative filtering |
| **TmdbService** | TMDB API client for recommendations and poster URLs |
| **ExternalSubtitleService** | Fetches and serves external subtitles from SubDL |
| **SubdlSubtitleProvider** | SubDL API client for subtitle search |

### Authorisation

All resources are scoped to the current user via ActionPolicy. Users can only access their own library entries, watch history, wishlist, and episode progress. API keys are encrypted at rest using Active Record Encryption.

## License

MIT
