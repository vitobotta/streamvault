# StreamVault

A personal media streaming platform built with Rails 8. Search content via Torrentio, stream through RealDebrid, and manage your library, watch history, and wishlist.

## Features

- **Search** — Find movies and TV shows via OMDB/Torrentio
- **Library Management** — Add, remove, and track watch status
- **Wishlist** — Save content for later, move to library when ready
- **Streaming** — Start streams via RealDebrid with automatic torrent management
- **Watch History** — Track progress across movies and TV episodes
- **Continue Watching** — Resume where you left off
- **TV Show Episodes** — Browse seasons, track episode progress
- **Settings** — Configure RealDebrid API key, manage profile
- **Dark Theme** — Indigo-violet accent on dark neutral surfaces
- **Responsive** — Sidebar navigation on desktop, bottom nav on mobile

## Tech Stack

- **Framework**: Rails 8.1.3, Ruby 4.0.5
- **Database**: SQLite3
- **CSS**: Tailwind CSS v4 (via tailwindcss-rails)
- **JS**: importmap-rails, Turbo, Stimulus
- **Auth**: Devise
- **Authorization**: ActionPolicy
- **Background Jobs**: Solid Queue
- **Encryption**: Active Record Encryption (for API keys)
- **Testing**: RSpec, FactoryBot, WebMock, Cuprite, SimpleCov

## Deployment

### Prerequisites

- Docker with Docker Compose

### Steps

```bash
# Clone the repository
git clone https://github.com/vitobotta/StreamVault.git
cd StreamVault

# Create environment config
cp .env.example .env

# Edit .env and fill in all values — see the table below for details
nano .env

# Build and start the container
docker compose up -d --build
```

The app is available at `http://localhost:${PORT:-3000}`.

Assets are precompiled inside the image during build — no local Ruby or Node installation needed. The SQLite database is persisted in a Docker volume (`storage_data`) and survives container rebuilds.

### Create an Admin User

```bash
docker compose exec web bin/rails c
> User.create!(email: "you@example.com", password: "password", password_confirmation: "password")
```

### Auto-start on Boot

Containers restart automatically after crashes and system reboots (`restart: unless-stopped`). Ensure the Docker daemon is enabled at boot.

### Updates

```bash
git pull
docker compose up -d --build
```

### Environment Variables

| Variable | Description | Default |
|---|---|---|
| `RAILS_MASTER_KEY` | Master key for credentials decryption (from `config/master.key`) | Required |
| `SECRET_KEY_BASE` | Session cookie secret (generate with `bin/rails secret`) | Required |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | Encryption key for API keys (generate with `openssl rand -hex 32`) | Required |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | Deterministic encryption key (generate with `openssl rand -hex 32`) | Required |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | Key derivation salt (generate with `openssl rand -hex 32`) | Required |
| `APP_DOMAIN` | Domain the app is served from (for Rails host authorization) | Required |
| `POSTGRES_USER` | Postgres database user | `streamvault` |
| `POSTGRES_PASSWORD` | Postgres database password (generate with `openssl rand -hex 16`) | Required |
| `POSTGRES_DB` | Postgres database name | `streamvault` |
| `PORT` | Host port to expose the app on | `3000` |
| `TORRENTIO_API_BASE_URL` | Torrentio API base URL | `https://torrentio.strem.fun` |
| `REALDEBRID_API_BASE_URL` | RealDebrid API base URL | `https://api.real-debrid.com/rest/1.0` |
| `OMDB_API_KEY` | OMDB API key for ratings metadata | Required |
| `SUBDL_API_KEY` | SubDL API key for external subtitle fallback ([create one](https://subdl.com/panel/api)) | Optional |

> **Torrentio note**: The public `torrentio.strem.fun` instance is behind Cloudflare and may block your server's IP. If you get 403 errors, run a self-hosted proxy (see the `proxy/torrentio` directory) and set `TORRENTIO_API_BASE_URL` to your proxy URL.

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
├── controllers/     # 9 controllers (home, search, content, library, wishlist, etc.)
├── models/          # 5 models (User, LibraryEntry, WatchHistoryEntry, WishlistEntry, EpisodeProgress)
├── services/        # 4 services (TorrentioService, RealDebridService, ContentStreamingService, ProgressTrackingService)
├── policies/        # 5 policies (ApplicationPolicy + 4 resource policies)
└── views/           # Dark-themed views with Tailwind CSS
```

### Services

- **TorrentioService** — Searches content via OMDB and fetches streams from Torrentio
- **RealDebridService** — Manages RealDebrid API interactions (add magnets, unrestrict links, track torrents)
- **ContentStreamingService** — Orchestrates the streaming flow (search → magnet → RealDebrid → streaming URL)
- **ProgressTrackingService** — Tracks watch progress, auto-advances episodes, provides continue-watching list

### Authorization

All resources are scoped to the current user via ActionPolicy. Users can only access their own library entries, watch history, wishlist, and episode progress.

## API Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/` | Dashboard |
| GET | `/search?q=` | Search content |
| GET | `/content/:type/:imdb_id` | Content detail |
| GET/POST/PATCH/DELETE | `/library` | Library CRUD |
| GET/POST/DELETE | `/wishlist` | Wishlist CRUD |
| POST | `/wishlist/:id/move_to_library` | Move to library |
| GET | `/watch_history` | Watch history |
| DELETE | `/watch_history/clear_all` | Clear history |
| GET | `/episodes/:show_imdb_id` | Episode browser |
| POST | `/streaming` | Start stream |
| GET | `/streaming/:id` | Get streaming URL |
| PATCH | `/streaming/:id/progress` | Save progress |
| GET/PATCH | `/settings` | Settings |

## License

MIT
