<p align="center">
  <img src="public/icon.png" width="120" height="120" alt="StreamVault logo">
</p>

<h1 align="center">StreamVault</h1>

<p align="center"><em>Your personal cinema — search, stream, and manage movies and TV shows, all in one place.</em></p>

<p align="center">
  <a href="#features">Features</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#environment-variables">Configuration</a> ·
  <a href="#troubleshooting">Troubleshooting</a> ·
  <a href="#testing">Development</a>
</p>

---

## What is StreamVault?

StreamVault is a self-hosted Rails application for discovering, organising, and watching media in a browser. It combines metadata and stream providers with your own RealDebrid account, then chooses the lightest playback path the browser can handle: direct play, video remuxing, or FFmpeg transcoding.

The player supports movies and episodic TV, multiple audio tracks, embedded and external subtitles, progress tracking, automatic recovery, and responsive desktop/mobile controls.

StreamVault does not ship with a media catalogue or maintain a persistent library of source files. Media is requested from the services you configure and delivered on demand; source data may pass through temporary buffers while it is proxied or transcoded.

## Disclaimer & responsible use

StreamVault is a **general-purpose media client** — like a web browser or BitTorrent client, it is neutral regarding what users choose to access. The repository does not include or publish copyrighted media or pre-configured lists of pirated material. The running application proxies or transcodes only the data requested by its operator and may buffer it temporarily for playback. All discovery and streaming is driven by the user's own choices and subscriptions.

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
StreamVault (Rails app)
  │
  ├──► Cinemeta / OMDB    →  provides metadata, artwork, and ratings
  │
  ├──► Torrentio / Comet  →  finds available streams
  │
  ├──► RealDebrid         →  resolves the selected stream to a direct link
  │
  └──► Playback layer
       ├── Direct proxy   →  passes compatible media to the browser
       └── FFmpeg         →  remuxes or transcodes incompatible media,
                             synchronises timestamps, and burns bitmap subtitles
```

1. **Search** — Type a title. StreamVault queries metadata catalogues (Cinemeta) and returns matching content with posters, ratings, and plots.
2. **Pick a stream** — Each title shows a list of available streams with quality (4K, 1080p, 720p), file size, and audio languages. Streams are sorted by your language preferences.
3. **Press play** — StreamVault resolves the selected stream through RealDebrid and probes its tracks. Compatible media plays directly; other sources are remuxed or transcoded into browser-friendly H.264/AAC fragmented MP4 or HLS. Audio timestamps are normalised, and bitmap subtitles are burned in when necessary.
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
- **Adaptive playback paths** — Uses native direct play when possible, low-cost video remuxing when safe, and full transcoding only when required.
- **Custom video player** — Built from scratch with seeking, volume control, playback speed, and full keyboard support.
- **Audio track selection** — Switch between audio languages when a stream has multiple tracks.
- **A/V timestamp synchronisation** — Corrects source timestamp gaps and keeps resumed, sought, and recovered streams aligned.
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
| **RealDebrid** | Resolves selected files and provides direct streaming links | **Yes** — streaming won't work without it | Sign up at [real-debrid.com](https://real-debrid.com), then get your API key at [real-debrid.com/apitoken](https://real-debrid.com/apitoken) |
| **Torrentio** | Finds available streams for a given title | Yes (default provider) | Works out of the box with the public instance. May need a proxy if your server IP is blocked (see below) |
| **Comet** | Alternative stream provider — self-hosted, independent of Torrentio | Optional (recommended) | Self-host via Docker — see [proxy/comet](proxy/comet) |
| **Cinemeta** | Provides content metadata (titles, posters, plots, episodes) | Yes (built-in) | No setup needed — uses the public Stremio metadata service |
| **OMDB** | Enriches content with IMDb, Rotten Tomatoes, and Metacritic ratings | Yes | Get a free API key at [omdbapi.com/apikey.aspx](https://www.omdbapi.com/apikey.aspx) |
| **TMDB** | Powers the "Recommended for You" feature using your watch history | Optional | Create an account at [themoviedb.org](https://www.themoviedb.org), then get a Read Access Token at [themoviedb.org/settings/api](https://www.themoviedb.org/settings/api) |
| **SubDL** | Provides external subtitles when embedded ones aren't available | Optional | Get a free API key at [subdl.com/panel/api](https://subdl.com/panel/api) |

### How the services work together

- **Torrentio and Comet** are both stream *providers*. They search torrent networks for available streams and return a list with quality, size, and language information. You can use either one or both — when both are configured (`STREAM_PROVIDER=auto`), StreamVault queries them in parallel and picks the best stream regardless of which provider found it. If one is down, the other fills in.

- **RealDebrid** is the *resolver*. Once you pick a stream, StreamVault sends its magnet link to RealDebrid, which retrieves or resolves the selected file and returns a direct HTTPS link. StreamVault does not add the source file to a persistent local media library, but its bytes pass through the server on demand and may be buffered temporarily during proxying or transcoding.

- **FFmpeg** is the *translator*. StreamVault bypasses it for sources the browser can play directly. Otherwise FFmpeg copies compatible video when safe, normalises audio to AAC with timestamp correction, or re-encodes incompatible/UHD video to browser-friendly 1080p H.264. It also produces HLS for iPhone playback and burns image-based subtitles that browsers cannot render.

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

> **Note on transcoding:** Compatible H.264/AAC MP4 sources can play directly without FFmpeg. At the beginning of a compatible source, StreamVault may copy the video while normalising audio; after a resume or seek, it may re-encode video to prevent keyframe pre-roll from putting audio and video on different timelines. The heaviest cases are 4K/UHD and incompatible codecs such as HEVC or AV1. VideoToolbox acceleration is used when StreamVault runs natively on supported macOS hardware; Docker does not expose it by default.

### Prerequisites

- A server or VPS with **Docker** and **Docker Compose** installed
- A **RealDebrid subscription** (starts at ~€3/month)
- API keys for **OMDB** (free) and optionally **TMDB** (free) and **SubDL** (free)

### Quick start

```bash
# Clone the repository
git clone https://github.com/vitobotta/streamvault.git
cd streamvault

# Create environment config
cp .env.example .env

# Generate secrets, then copy each result to the matching .env variable
openssl rand -hex 64  # SECRET_KEY_BASE
openssl rand -hex 32  # run separately for each encryption key and POSTGRES_PASSWORD

# Edit .env — see the configuration table below
${EDITOR:-nano} .env

# Build and start the container
docker compose up -d --build
```

At minimum, set `SECRET_KEY_BASE`, the three `ACTIVE_RECORD_ENCRYPTION_*` values, `POSTGRES_PASSWORD`, and `OMDB_API_KEY`. Set `APP_DOMAIN` for a public deployment. `RAILS_MASTER_KEY` is only needed if you add Rails encrypted credentials.

The app is available at `http://localhost:3000` unless you change `PORT`.

Assets are precompiled inside the image during build — no local Ruby or Node installation needed. The PostgreSQL database is persisted in a local `./data` directory and survives container rebuilds.

### Create your first user

Sign-ups are disabled by default for security. Create your user via the Rails console:

```bash
docker compose exec web bin/rails c
> password = SecureRandom.base58(24)
> User.create!(email: "you@example.com", password: password, password_confirmation: password)
> puts password
```

Store the generated password in your password manager, then sign in and change it from your profile if desired.

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
| `RAILS_MASTER_KEY` | Master key for Rails encrypted credentials; only required if you create an encrypted credentials file | Optional |
| `SECRET_KEY_BASE` | Session cookie secret (generate with `openssl rand -hex 64`) | Required |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | Encryption key for API keys (generate with `openssl rand -hex 32`) | Required |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | Deterministic encryption key (generate with `openssl rand -hex 32`) | Required |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | Key derivation salt (generate with `openssl rand -hex 32`) | Required |
| `APP_DOMAIN` | Domain the app is served from (recommended for Rails host authorisation in public deployments) | Optional |
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
| `HTTP_WRITE_TIMEOUT` | Thruster response write deadline in seconds; keep `0` for movie-length streams | `0` |
| `HTTP_IDLE_TIMEOUT` | Thruster keep-alive idle timeout in seconds; keep `0` to avoid interrupting reconnects | `0` |

## Troubleshooting

Start with the container status, application logs, and health endpoint:

```bash
docker compose ps
docker compose logs --tail=200 -f web
curl -I http://localhost:${PORT:-3000}/up
```

| Symptom | What to check |
|---|---|
| No streams, HTTP 403s, or intermittent provider failures | Your server IP may be blocked by Cloudflare. See the [proxy guide](#proxies-when-and-why-you-might-need-them). |
| Playback buffers during transcoding | Check CPU saturation and FFmpeg throughput in the web logs; try a 1080p/H.264 source before a 4K, HEVC, or AV1 source. |
| Direct play works but a resumed stream is CPU-heavy | Expected: non-zero seeks may re-encode video to keep audio and video timestamps aligned. |
| Subtitles appear slowly on a remote file | The first extraction may need to seek through a large container. StreamVault retries transient extraction timeouts automatically. |
| The site is reachable but sign-in does not persist behind a proxy | Confirm the public URL uses HTTPS and that the proxy forwards the original scheme and host. Production cookies are Secure. |

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
│  and bandwidth for streaming        │             │  Cloudflare; cheap to run        │
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

Local development uses Ruby 4.0.5. PostgreSQL and FFmpeg must be available; the JavaScript regression suite uses Node's built-in test runner and needs no npm install.

```bash
# Prepare Ruby dependencies and the test database
bundle install
bin/rails db:prepare

# Run the Rails suite
bundle exec rspec

# Run video-player controller regressions
node --test spec/javascript/video_player_controller_test.mjs

# Run Ruby style checks
bin/rubocop

# Run specific test types
bundle exec rspec spec/models/      # Model specs
bundle exec rspec spec/services/    # Service specs
bundle exec rspec spec/requests/    # Request specs
```

## Architecture

```
app/
├── controllers/     # HTML pages, playback orchestration, and signed media endpoints
├── models/          # User-owned state, HLS records, and immutable playback contracts
├── services/        # Catalog, stream resolution, playback, and media processing
├── javascript/      # Stimulus controllers and isolated player services
├── jobs/            # Recommendation refresh and HLS cleanup
└── views/           # Server-rendered dark-themed Tailwind views
```

### Services

| Boundary | Role |
|----------|------|
| **Catalog::CinemetaClient / Catalog::OmdbClient** | Fetch canonical metadata, catalogs, and ratings |
| **Streams::TorrentioProvider / CometService** | Fetch typed `StreamCandidate` values from configured providers |
| **AvailableStreamsService / Streams::Resolver** | Cache candidates, rank them, resolve a playback-safe RealDebrid source |
| **PlaybackStartService / PlaybackResumeService** | Build signed `PlaybackDescriptor` values and choose resume targets |
| **Playback::ProgressWriter / Playback::ContinueWatchingQuery** | Persist unified progress and build Continue Watching |
| **Media::Probe / Media::Subtitles / Media::Transcoder** | Probe tracks, extract subtitles, and produce fMP4 or HLS output |
| **HlsSessionManager** | Persist, monitor, expire, and clean up HLS processes |
| **RecommendationService / TmdbService** | Cache personalized TMDB recommendations outside user media state |
| **RealDebridService** | Verify user API keys |

### Authorisation

Every user-owned query is scoped through `current_user` associations. Playback and media URLs use signed, expiring, user-bound tokens; raw RealDebrid URLs never cross the server/browser boundary. API keys are encrypted at rest with Active Record Encryption.

## License

MIT
