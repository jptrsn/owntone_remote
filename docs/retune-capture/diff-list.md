# Diff list — ReTune 3.5.23 vs OwnTone Remote (2026-11-19)

Every row: ReTune behaviour (evidence) → new-app state (code/file) →
proposal → effort (S/M/L) → recommendation → **user decision (blank =
awaiting gate)**. Rows are independent; pick any subset. Evidence dirs in
`docs/retune-capture/`, current-state refs are `lib/src/…` lines verified
today.

| ID | ReTune behaviour (evidence) | New-app today | Proposal | Effort | Rec | Decision |
|---|---|---|---|---|---|---|
| **D-01** | mDNS auto-discovery of servers (0.4 s, JmDNS `_dacp._tcp`) — `02`, unit-001 | Server config = manual IP/port only (`settings/`) | Add `_owntone-server._tcp` (verify real service type on server first) browse to connection setup; pre-fill dialog; manual entry stays fallback | M | **do** — approved in principle 2026-11-19 | **ACCEPTED** (2026-11-19) → issue (R-20) |
| **D-02** | **Songs tab** — whole library as one paged two-line list (`12-songs`) | No all-tracks view (`browse_screens.dart:36-42` = Search/Playlists/Artists/Albums/Genres) | Add 'Songs' section → `api.tracks()` (GET /api/library/tracks, paginated, TrackRow w/ artist-album + rate) | S | **do** — biggest coverage gap; trivial w/ PagedBrowseScreen | **ACCEPTED** (2026-11-19) → issue (R-15) |
| **D-03** | Grid display mode per view: artwork cards + "N album, M songs" (`07`) | List rows only, icon leading (`browse_rows.dart` — zero ArtworkBox use). **Corrected v1:** counts already exist (artist/genre/playlist rows `browse_rows.dart:129,163,228`) — the gap is artwork+grid only | Grid toggle for Artists/Albums (artwork; counts already present) | M | maybe — visual win, needs artwork probe reuse (unit 010) | deferred — taste call, not taken this pass |
| **D-04** | np overflow **Go to Artist / Go to Album** (`15`) | No navigation from np to browse context | Add np overflow: Go to Artist / Go to Album (reuse AlbumTracksScreen/ArtistAlbumsScreen) | S | **do** — cheap, genuinely useful | **ACCEPTED** (2026-11-19) → issue (R-17) |
| **D-05** | Playlist rows w/ **artwork + smart-playlist badge** (`01`) | PlaylistRow = static queue_music icon (`browse_rows.dart:108`) | ArtworkBox leading (probe-gated 204 per unit 010) + "smart" chip from `smart` flag | S | **do** | **ACCEPTED** (2026-11-19) → issue (R-16) |
| **D-06** | Detail overflow: **Play All · Shuffle · Play Next · Add to Up Next** (`09`, `18b`) | Row-accessory replace-and-play only; `QueueController.playUris` clear+start (`queue_controller.dart:162`); no add-only, no shuffle-first | Add app-bar overflow on Playlist/Album/Artist-Albums detail w/ the 4 actions (QueueController += `addUris`, shuffle-then-play); wire to POST /api/queue/items/add variants | M | **do** — core remote parity | **ACCEPTED** (2026-11-19) → issue (R-19) |
| **D-07** | Drawer hosts nav (`02`) | Bottom nav (R-05 era decision) | — no change; recorded difference only | — | skip | no change |
| **D-08** | Artist → songs (genre headers); Genre → artists (`04`, `11`) | Artist → albums → tracks; Genre → albums (`browse_screens.dart:170,305`) | Keep new-app paths (deeper structure is arguably better); optionally add "All songs" action to artist screen later | — | skip for now | skip (keep current drill paths) |
| **D-09** | **Speakers button in every app bar** (`14`) | Outputs reachable only from now-playing (`now_playing_screen.dart:329`) | Add outputs icon to BrowseScreenScaffold app bar (1-liner-ish; viewport check w/ 360 px — unit 004 lesson) | S | **do** | **ACCEPTED** (2026-11-19) → issue (R-18) |
| **D-10** | Theme pref Light/Dark (`17`) | System-follow only (M3 defaults) | Settings += theme mode selector (system/light/dark), persisted | S | maybe | deferred — taste call, not taken this pass |
| **D-11** | Home-screen widgets (4) — static manifest | None | — | — | **skip** (scope creep; user-call) | **DROPPED** (user 2026-11-19) |
| **D-12** | Visualizer + peak meter (`15`, `19`) | None | — | — | **drop** (visual flourish, no JSON semantics) | **DROPPED** (user 2026-11-19) |
| **D-13** | Default-view-on-launch / restore-last-screen (`17`, walk) | Fixed home cold-start | — | — | **drop** | **DROPPED** (user 2026-11-19) |
| **D-14** | Playlist Sort By client cycling (`18b`) | Server order (the JSON contract) | — | — | **drop** | **DROPPED** (user 2026-11-19) |
| **D-15** | Screen-off disconnect, Screen lock, pause-on-call prefs (`17`) | audio_service handles interruptions per platform default | — verify pause-on-call behaves right (audio focus abort) during next dv pass; other two drop | S (verify) | verify only | **DROPPED**, except pause-on-call verification (next dv pass) |
| **D-16** | Half-star ratings pref (`17`) | Integer 1–5 taps (unit 006) | — | — | **drop** (OwnTone rating is 0–100 int; halves add nothing) | **DROPPED** (user 2026-11-19) |
| **D-17** | Up-Next **History** (`16b`) | Full queue view incl. current | — | — | **drop** — no JSON endpoint (documented in RELEASE-NOTES-known-gaps) | **DROPPED** (user 2026-11-19) — documented in RELEASE-NOTES |
| **D-18** | Reorder drag-confirm onboarding dialog (`16`) | Direct drag | — | — | skip | skip |
| **D-19** | Notification NO_CLEAR FGS silent channel (`21`) | audio_service silent channel, FGS | already parity (dv-004 verified backgrounded) | — | done ✓ | parity confirmed |

## Gate outcome (user, 2026-11-19)
Verbatim: *"confirm drops, save everything to the project using the
ai-dlc approach, then we need to draft a series of github issues that
report each change that is required to the existing project."*
Accepted: D-01, D-02, D-04, D-05, D-06, D-09 (→ R-15…R-20 in
`docs/REQUIREMENTS.md`, issues drafted in `.ai-dlc/retune-ux-capture/issues/`).
Dropped (confirmed): D-11…D-18 set as tabled; D-03/D-10 deferred.

## Recommended shortlist (if picking a slice)
**D-02 + D-05 + D-04 + D-09** (all S, library-UX completeness) then
**D-06** (M, the remote-control parity one), **D-01** (M, approved),
D-03/D-10 as taste calls.

## Explicitly out (from the walk, restated)
iTunes-only catalogue (Radio/Movies/TV/Podcasts/iTunes U/Audiobooks/Genius) ·
pairing ceremony UI · multi-library switch · widgets · visualizer ·
history · sort-by · disconnect/screen-lock prefs.

## Navigation-family rows (added 2026-11-19 after the code-verification correction)
v1 of the inventory misdescribed the app (claimed bottom nav + mini
player + queue reorder as existing). Code-verified reality: **NP-root +
pushed screens, no persistent player surface anywhere, no reorder.**
| ID | ReTune behaviour (evidence) | New-app today (code) | Proposal | Effort | Rec | Decision |
|---|---|---|---|---|---|---|
| **N-01** | Mini now-playing bar (metadata + prev/play/next) on every browse/search screen; tap → now playing (`01`, `navigation.md`) | **Nothing** — pushed screens have no player surface (`browse_screen_scaffold.dart` full read) | Persistent mini bar on pushed screens (BrowseScreenScaffold + QueueScreen/OutputsScreen): 2-line metadata + transport via PlayerController; tap = `showNowPlaying` | M | **do** — the navigation-family gap you flagged | ☐ |
| **N-02** | Drawer: Now Playing / Up Next / Views from everywhere (`02`) | Entry row on NP only (321-366); pushed screens need back-to-root | Decide nav architecture: (a) NP-root + N-01 mini bar + #40 outputs-on-browse (recommended — keeps route model, ~all drawer utility), (b) add Drawer to BrowseScreenScaffold, (c) NavigationBar rework (large) | S (a) / M (b) | (a) once N-01 lands | ☐ |
| **N-03** | Queue drag-reorder (`16`) | Absent — no move call anywhere (`queue_controller.dart`); R-11 never required it; `PUT /api/queue/items/{id}?new_position=N` exists (`docs/API.md:94`) | ReorderableListView in QueueScreen + `moveItem()` on QueueController (single-flight per unit 011) | M | **do** | ☐ |
| **N-04** | Remove a single queue item (row accessory) (`16`) | Only clear-all w/ confirm (`queue_screen.dart:124-129`); `DELETE /api/queue/items/{id}` exists (`docs/API.md:95`) | Per-row remove (dismissible/swipe or overflow) + `removeItem()` | S | **do** | ☐ |
| **N-05** | Alphabetical section headers in long lists (`03`, `10`) | Plain ListView, no headers (`paged_browse_list.dart`) | Optional sticky headers for Artists/Genres (search already grouped) | S | nice-to-have | ☐ |
