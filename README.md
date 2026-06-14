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

## Setup

### Prerequisites

- Ruby 4.0.5+
- SQLite3
- Bundler

### Installation

```bash
# Clone and install
cd StreamVault
bundle install

# Set up database
bin/rails db:create db:migrate

# Configure environment
cp .env.example .env
# Edit .env with your keys:
#   - ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
#   - ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
#   - ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
#   - OMDB_API_KEY (get from omdbapi.com)
#   - TORRENTIO_API_BASE_URL (default: https://torrentio.strem.fun)
#   - REALDEBRID_API_BASE_URL (default: https://api.real-debrid.com/rest/1.0)

# Build Tailwind CSS
bin/rails tailwindcss:build

# Start server
bin/dev
```

### Environment Variables

| Variable | Description | Default |
|---|---|---|
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | Encryption key for API keys | Required |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | Deterministic encryption key | Required |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | Key derivation salt | Required |
| `OMDB_API_KEY` | OMDB API key for search | Required |
| `TORRENTIO_API_BASE_URL` | Torrentio API base URL | `https://torrentio.strem.fun` |
| `REALDEBRID_API_BASE_URL` | RealDebrid API base URL | `https://api.real-debrid.com/rest/1.0` |

## Testing

```bash
# Run all tests
bundle exec rspec

# Run with coverage
bundle exec rspec
# Coverage report: coverage/index.html

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
