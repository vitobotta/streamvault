# Development

Everything needed to run StreamVault locally, change it, and ship a release.

## Requirements

| Tool | Version | Notes |
|---|---|---|
| Ruby | 4.0.9 | Pinned in `.ruby-version`. `mise` is the simplest way to get it |
| FFmpeg | Recent build with libx264 and AAC | Required only for transcoding, remuxing, subtitle extraction and HLS |
| Node | 20 or newer | Only for the player regression suite. No npm install is needed |
| Docker | Any recent version | Only for the production-style Compose stack |

Development and test run on SQLite, so no database server is required. The container uses PostgreSQL 17.

## Local setup

```bash
bundle install
bin/rails db:prepare
bin/dev
```

`bin/dev` runs Rails and the Tailwind watcher. If you prefer separate processes, `bin/rails server` works, but it does not rebuild the stylesheet: run `bin/rails tailwindcss:build` after every CSS change or the browser keeps serving the previous `app/assets/builds/tailwind.css`.

The dev database is `storage/development.sqlite3`. `db:prepare` may also create an empty `db/development.sqlite3`; that file is not used and can be deleted.

## Tests

Run only the specs covering the code you touched, serially:

```bash
bundle exec rspec spec/services/streams/resolver_spec.rb
bundle exec rspec spec/models/ spec/services/
```

Rules that matter:

- **Never run two suites at once.** Every suite opens the same `storage/test.sqlite3`. Two overlapping runs corrupt each other and produce dozens of failures in specs you never touched, with no deadlock message. If that happens, stop the extra run and repeat serially before reading a single failure.
- **WebMock blocks all network access.** Stub every external host a request path can reach: OMDB, TMDB, Cinemeta, Torrentio, Comet, RealDebrid. An unstubbed lookup inside a filter thread surfaces as a non-`StandardError` and fails the request. Stub fallback sources too, not only the primary.
- **SimpleCov enforces 85% line and 50% branch coverage on `app/`.** A focused subset therefore exits non-zero. Judge the run by its `N examples, 0 failures` line, not by the exit code.
- **Specs that toggle configuration** must blank and restore every key the production predicate reads, and must pass with the repository's real `.env`. Run such a file twice, once normally and once with the keys blanked:

```bash
OMDB_API_KEY= TMDB_READ_ACCESS_TOKEN= bundle exec rspec spec/requests/content_spec.rb
```

Dotenv never overwrites a key already present in the environment, which is what makes the blank-prefix form work without editing `.env`.

### Player JavaScript tests

```bash
node --test spec/javascript/*_test.mjs
```

Pass the glob, not the directory: `node --test spec/javascript/` fails with `MODULE_NOT_FOUND` on some Node builds and reports a single bogus failure.

The glob also loads the aggregate runner (`video_player_controller_test.mjs`), which imports every other file, so each example is counted twice. Judge the run by `fail 0` and by the delta against the previous baseline (`+N` new tests move the total by `2N`), never by a remembered total.

A new `spec/javascript/*_test.mjs` file only runs if the aggregate runner imports it.

### Style and static analysis

```bash
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

## Architecture

```
app/
├── controllers/     # HTML pages, playback orchestration, signed media endpoints
├── models/          # User-owned state, HLS records, immutable playback contracts
├── services/        # Catalog, stream resolution, playback, media processing
├── javascript/      # Stimulus controllers and isolated player services
├── jobs/            # Recommendation refresh and HLS cleanup
└── views/           # Server-rendered Tailwind views
```

### Service boundaries

| Boundary | Role |
|---|---|
| `Catalog::CinemetaClient` / `Catalog::OmdbClient` | Fetch canonical metadata, catalogs, and ratings |
| `Streams::TorrentioProvider` / `CometService` | Fetch typed `StreamCandidate` values from configured providers |
| `AvailableStreamsService` / `Streams::Resolver` | Cache candidates, rank them, resolve a playback-safe RealDebrid source |
| `PlaybackStartService` / `PlaybackResumeService` | Build signed `PlaybackDescriptor` values and choose resume targets |
| `Playback::ProgressWriter` / `Playback::ContinueWatchingQuery` | Persist unified progress and build Continue Watching |
| `Media::Probe` / `Media::Subtitles` / `Media::Transcoder` | Probe tracks, extract subtitles, produce fMP4 or HLS output |
| `HlsSessionManager` | Persist, monitor, expire, and clean up HLS processes |
| `RecommendationService` / `TmdbService` | Cache personalised TMDB recommendations outside user media state |
| `RealDebridService` | Verify user API keys |

### Playback paths

| Path | Entry point | Behaviour |
|---|---|---|
| Direct play | `DirectStreamController` | Proxies the resolved source with Range passthrough. No ffmpeg |
| Remux | `TranscodeController` with `remux=1` | Copies video, normalises audio, corrects timestamps |
| Transcode | `TranscodeController` | Re-encodes to browser-ready H.264/AAC fragmented MP4 |
| HLS | `HlsController` / `HlsSessionManager` | Writes segments for iPhone Safari, which lacks MSE |

### Authorisation

Every user-owned query is scoped through `current_user` associations. Playback and media URLs use signed, expiring, user-bound tokens; raw RealDebrid URLs never cross the server/browser boundary. API keys are encrypted at rest with Active Record Encryption.

## CI

`.github/workflows/ci.yml` runs three jobs: `scan_ruby` (`bin/brakeman --no-pager`, then `bin/bundler-audit`), `scan_js` (`bin/importmap audit`) and `lint` (`bin/rubocop -f github`).

There is no test job. A green run says nothing about specs, so run the focused suite before claiming a change is good.

`bin/brakeman` prepends `--ensure-latest`, so it exits 5 with zero findings as soon as a newer Brakeman is published. When `scan_ruby` fails within seconds, read the real exit code (`bin/brakeman --no-pager > log 2>&1; echo exit=$?`), then `bundle update brakeman` and run `bin/bundler-audit` on its own.

## Releasing

1. Focused gates green and RuboCop clean.
2. Commit with explicit paths. Never `git add -A`: `.env` holds real credentials and must stay ignored.
3. Merge to `main`, then `git fetch` and read `git status -sb` before pushing. The owner commits directly on GitHub, so `main` may be behind.
4. Push `origin main`, then `git push dokku main`.
5. Verify the deploy: `GET /up` returns 200 on the public domain, the live asset contains the change, `dokku ps:report streamvault --deployed` reads `true`.
6. Publish a GitHub release with handwritten notes, and confirm the tag commit equals `HEAD`.
7. Update the marketing site in `../StreamVault-Website` if the release changes anything it claims.

Deploy writes and releases need explicit approval each time.

## Working conventions

- `.learnings/LEARNINGS.md` is the authoritative, dated, newest-first record of hard-won lessons. Read it before a non-trivial change and append to it after one.
- Plans live in `.hermes/plans/<date>_<slug>.md`. `.hermes/` is gitignored, so plan files stay local.
- There is no `AGENTS.md` or `CLAUDE.md`. Do not invent one.

## Reviewing a contributor PR

Review the PR head in an isolated worktree, not the author's checkout:

```bash
git fetch origin pull/<n>/head:pr-review --force
git worktree add --detach <scratch>/pr-review pr-review
```

Three setup steps are required in a fresh worktree or the gate lies about the code:

- Copy `.env`, `config/master.key` and `config/credentials/` from the main checkout without printing them. Without them every request spec fails with `Missing Active Record encryption credential`.
- `RAILS_ENV=test DISABLE_SPRING=1 bin/rails db:prepare` creates the worktree's own test database.
- `bundle exec rails tailwindcss:build` before any spec that renders a layout, or the request fails with `Propshaft::MissingAssetError`.

Check `git merge-base origin/main pr-review` equals the branch point before attributing behaviour to the branch. Delete the copied key material with the worktree.

## Configuration

Environment variables, provider modes and proxy setups are documented in [CONFIGURATION.md](CONFIGURATION.md).
