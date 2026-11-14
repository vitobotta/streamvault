# Jellyfin feature parity backlog

StreamVault is a debrid streaming client, not a local media server. "Parity with
Jellyfin" therefore splits into two tracks:

- **Client parity** — everything a viewer uses in Jellyfin's web client. This is
  the track that fits StreamVault's model and is the focus of this branch.
- **Server parity** — local media scanning, Live TV/DVR, plugins, and hardware
  transcoding. These are substantial new subsystems and should be separate
  product decisions, not smuggled into a playback PR.

Status: ✅ done · 🟡 partial · ⬜ missing

| # | Area | Jellyfin feature | Status | What remains |
|---|------|------------------|--------|--------------|
| 1 | Library | Movies and TV metadata | ✅ | Cinemeta metadata, posters, cast, ratings, episodes |
| 2 | Library | Local media scanning and file management | ⬜ | New media-source subsystem; only meaningful if StreamVault stops being debrid-only |
| 3 | Library | Music library | ⬜ | New media type, artist/album models, audio player |
| 4 | Library | Books and comics | ⬜ | New media type, reader UI |
| 5 | Library | Photos and home videos | ⬜ | New media type, gallery UI |
| 6 | Library | Collections | ⬜ | User-curated groups distinct from playlists; reuse playlist item shape |
| 7 | Library | Playlists | ✅ | Implemented in this branch: create, add, remove, reorder, delete |
| 8 | Library | Favourites | 🟡 | Wishlist covers "save for later"; add a distinct favourite flag and filter |
| 9 | Library | Mark played / unplayed | ⬜ | Manual progress toggle for movies and episodes |
| 10 | Library | Watched state and progress | ✅ | ProgressWriter, resume, continue watching, history |
| 11 | Library | Next Up | ✅ | Continue Watching and next-episode prompt |
| 12 | Library | Genres, studios, people pages | 🟡 | Metadata shows genres/cast; no browse-by-genre or person pages |
| 13 | Library | Trailers and theme media | ⬜ | Trailer provider and playback entry point |
| 14 | Discovery | Search | ✅ | Title search with metadata |
| 15 | Discovery | Search filters and sorting | 🟡 | Type filter exists in library; no year/genre/rating sort |
| 16 | Discovery | Recommendations | ✅ | TMDB recommendations from watch history |
| 17 | Discovery | Popular and trending rows | ✅ | Cinemeta catalogues |
| 18 | Playback | Direct play | ✅ | Native browser playback |
| 19 | Playback | Remux | ✅ | Compatible video copied into fMP4 |
| 20 | Playback | Transcoding | ✅ | FFmpeg fallback with audio normalisation |
| 21 | Playback | Hardware-accelerated transcoding | ⬜ | VAAPI/QSV/NVENC detection, encoder selection, fallback |
| 22 | Playback | Tone mapping | ⬜ | HDR→SDR filters in the transcode pipeline |
| 23 | Playback | Quality and bitrate selection | ⬜ | Per-stream cap that selects a source or transcodes within a budget |
| 24 | Playback | Audio track selection | ✅ | Track picker and remux/transcode handling |
| 25 | Playback | Subtitle track selection | ✅ | Embedded text and image tracks |
| 26 | Playback | External subtitle search and download | 🟡 | SubDL fallback; no search/preview/choose UI or multiple providers |
| 27 | Playback | Subtitle burn-in | ✅ | PGS/VobSub burned when the browser cannot render them |
| 28 | Playback | Chapter markers | 🟡 | Next-episode prompt uses credits chapters; no chapter list |
| 29 | Playback | Trickplay thumbnails | ⬜ | Seek-preview sprite generation and serving |
| 30 | Playback | Chapter images | ⬜ | Extract and display chapter thumbnails |
| 31 | Playback | Intro and credits detection | 🟡 | Near-end next-episode prompt; no fingerprint-based intro skip |
| 32 | Playback | Playback speed | ✅ | Speed menu, persistence across seeks |
| 33 | Playback | Keyboard shortcuts | ✅ | Play/pause, seek, mute, fullscreen, speed menu |
| 34 | Playback | Picture-in-picture | ⬜ | Native PiP button and state handling |
| 35 | Playback | Casting and remote control | ⬜ | Chromecast/AirPlay plus a remote-control channel |
| 36 | Playback | SyncPlay (watch together) | ⬜ | Realtime room protocol, host/guest state, drift correction |
| 37 | Live TV | Tuners and channel guide | ⬜ | Separate Live TV subsystem |
| 38 | Live TV | DVR and recordings | ⬜ | Recording scheduler, storage, retention rules |
| 39 | Users | Multiple profiles per account | ⬜ | Profile model above User, profile switcher, per-profile progress |
| 40 | Users | Avatars and display identities | 🟡 | Display name exists; no avatar upload/selection |
| 41 | Users | Per-library permissions | ⬜ | Permission model once local libraries exist |
| 42 | Users | Parental controls | ✅ | Child accounts, age caps, child lock, server-side filtering |
| 43 | Users | Quick Connect | ⬜ | Short-lived pairing code flow |
| 44 | Users | OIDC / LDAP sign-in | ⬜ | OmniAuth provider configuration alongside Devise |
| 45 | Users | API keys | ⬜ | User-issued tokens for third-party clients |
| 46 | Users | Active sessions and devices | ⬜ | Session inventory, last-seen, current device |
| 47 | Users | Remote sign-out | ⬜ | Revoke another session |
| 48 | Platform | Webhooks | ⬜ | Playback/library event delivery with signing and retries |
| 49 | Platform | Notifications | ⬜ | In-app and email notification preferences |
| 50 | Platform | Scheduled tasks UI | 🟡 | Solid Queue runs jobs; no admin schedule/status page |
| 51 | Platform | Plugin system | ⬜ | Extension boundary for providers and metadata sources |
| 52 | Platform | Backup and restore | ⬜ | Export/import of users, library state, and settings |
| 53 | Platform | Metrics and monitoring | ⬜ | Health, playback, and provider metrics endpoint |
| 54 | Platform | DLNA | ⬜ | Discovery and media serving protocol |
| 55 | Platform | Mobile apps | 🟡 | Installable PWA; no native clients |
| 56 | Platform | Themes and branding | 🟡 | One dark theme and accent token; no theme picker |
| 57 | Platform | Localisation and RTL | ⬜ | UI is English-only with no locale files for product copy |
| 58 | Platform | Accessibility audit | 🟡 | Focus states and labels exist; no full audit or reduced-motion mode |

## Suggested one-feature-per-PR order

Each item below is intended to be its own PR, in this order, so a regression in
one area cannot block the rest:

1. **Playlists** — this branch.
2. **Watched/unplayed toggles** — small, high-use library control.
3. **Playback quality and bitrate cap** — settings plus source selection.
4. **Hardware transcoding and tone mapping** — feature-detected, with software fallback.
5. **Subtitle search and download** — provider abstraction around SubDL.
6. **Collections** — user-curated groups on top of the playlist item shape.
7. **Profiles, avatars, and per-library permissions** — account model work.
8. **API keys, sessions, and remote sign-out** — platform/security work.
9. **SyncPlay** — realtime watch-together.
10. **Trailers, chapter images, and trickplay** — media enrichment.
11. **Live TV/DVR** — separate product track.
12. **Local media library** — separate product track.
13. **Platform admin** — webhooks, notifications, scheduled-task UI, plugins, backup, metrics, OIDC/LDAP, DLNA.

## Playlist scope in this PR

- Per-account playlists with name and optional description.
- Add a movie or show from its detail page.
- Create a playlist and add the current title in one step.
- Reorder items, remove items, rename, and delete.
- Child accounts cannot add a title above their age cap, and items above the cap
  are hidden from the playlist view even if they were added before the cap changed.
- Playlists currently hold titles, not individual episodes. Episode-level
  playlists are a follow-up that needs an episode key in `playlist_items`.
- Playback is item-by-item: opening a playlist title goes to its detail page.
  A continuous play queue that auto-advances through playlist items is a
  follow-up; it needs the player to accept an ordered queue.
