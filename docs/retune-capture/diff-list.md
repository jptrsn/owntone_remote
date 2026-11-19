# Diff list — ReTune 3.5.23 vs OwnTone Remote (2026-11-19)

Every row: ReTune behaviour (evidence) → new-app state (code/file) →
proposal → effort (S/M/L) → recommendation → **user decision (blank =
awaiting gate)**. Rows are independent; pick any subset. Evidence dirs in
`docs/retune-capture/`, current-state refs are `lib/src/…` lines verified
today.

| ID | ReTune behaviour (evidence) | New-app today | Proposal | Effort | Rec | Decision |
|---|---|---|---|---|---|---|
| **D-01** | mDNS auto-discovery of servers (0.4 s, JmDNS `_dacp._tcp`) — `02`, unit-001 | Server config = manual IP/port only (`settings/`) | Add `_owntone-server._tcp` (verify real service type on server first) browse to connection setup; pre-fill dialog; manual entry stays fallback | M | **do** — approved in principle 2026-11-19 | ☐ |
| **D-02** | **Songs tab** — whole library as one paged two-line list (`12-songs`) | No all-tracks view (`browse_screens.dart:36-42` = Search/Playlists/Artists/Albums/Genres) | Add 'Songs' section → `api.tracks()` (GET /api/library/tracks, paginated, TrackRow w/ artist-album + rate) | S | **do** — biggest coverage gap; trivial w/ PagedBrowseScreen | ☐ |
| **D-03** | Grid display mode per view: artwork cards + "N album, M songs" (`07`) | List rows only, icon leading (`browse_rows.dart` — zero ArtworkBox use) | Grid toggle for Artists/Albums (artwork + counts). Skip Songs/Playlists grid | M | maybe — visual win, needs artwork probe reuse (unit 010) | ☐ |
| **D-04** | np overflow **Go to Artist / Go to Album** (`15`) | No navigation from np to browse context | Add np overflow: Go to Artist / Go to Album (reuse AlbumTracksScreen/ArtistAlbumsScreen) | S | **do** — cheap, genuinely useful | ☐ |
| **D-05** | Playlist rows w/ **artwork + smart-playlist badge** (`01`) | PlaylistRow = static queue_music icon (`browse_rows.dart:108`) | ArtworkBox leading (probe-gated 204 per unit 010) + "smart" chip from `smart` flag | S | **do** | ☐ |
| **D-06** | Detail overflow: **Play All · Shuffle · Play Next · Add to Up Next** (`09`, `18b`) | Row-accessory replace-and-play only; `QueueController.playUris` clear+start (`queue_controller.dart:162`); no add-only, no shuffle-first | Add app-bar overflow on Playlist/Album/Artist-Albums detail w/ the 4 actions (QueueController += `addUris`, shuffle-then-play); wire to POST /api/queue/items/add variants | M | **do** — core remote parity | ☐ |
| **D-07** | Drawer hosts nav (`02`) | Bottom nav (R-05 era decision) | — no change; recorded difference only | — | skip | ☐ |
| **D-08** | Artist → songs (genre headers); Genre → artists (`04`, `11`) | Artist → albums → tracks; Genre → albums (`browse_screens.dart:170,305`) | Keep new-app paths (deeper structure is arguably better); optionally add "All songs" action to artist screen later | — | skip for now | ☐ |
| **D-09** | **Speakers button in every app bar** (`14`) | Outputs reachable only from now-playing (`now_playing_screen.dart:329`) | Add outputs icon to BrowseScreenScaffold app bar (1-liner-ish; viewport check w/ 360 px — unit 004 lesson) | S | **do** | ☐ |
| **D-10** | Theme pref Light/Dark (`17`) | System-follow only (M3 defaults) | Settings += theme mode selector (system/light/dark), persisted | S | maybe | ☐ |
| **D-11** | Home-screen widgets (4) — static manifest | None | — | — | **skip** (scope creep; user-call) | ☐ |
| **D-12** | Visualizer + peak meter (`15`, `19`) | None | — | — | **drop** (visual flourish, no JSON semantics) | ☐ |
| **D-13** | Default-view-on-launch / restore-last-screen (`17`, walk) | Fixed home cold-start | — | — | **drop** | ☐ |
| **D-14** | Playlist Sort By client cycling (`18b`) | Server order (the JSON contract) | — | — | **drop** | ☐ |
| **D-15** | Screen-off disconnect, Screen lock, pause-on-call prefs (`17`) | audio_service handles interruptions per platform default | — verify pause-on-call behaves right (audio focus abort) during next dv pass; other two drop | S (verify) | verify only | ☐ |
| **D-16** | Half-star ratings pref (`17`) | Integer 1–5 taps (unit 006) | — | — | **drop** (OwnTone rating is 0–100 int; halves add nothing) | ☐ |
| **D-17** | Up-Next **History** (`16b`) | Full queue view incl. current | — | — | **drop** — no JSON endpoint (documented in RELEASE-NOTES-known-gaps) | ☐ |
| **D-18** | Reorder drag-confirm onboarding dialog (`16`) | Direct drag | — | — | skip | ☐ |
| **D-19** | Notification NO_CLEAR FGS silent channel (`21`) | audio_service silent channel, FGS | already parity (dv-004 verified backgrounded) | — | done ✓ | ☐ |

## Recommended shortlist (if picking a slice)
**D-02 + D-05 + D-04 + D-09** (all S, library-UX completeness) then
**D-06** (M, the remote-control parity one), **D-01** (M, approved),
D-03/D-10 as taste calls.

## Explicitly out (from the walk, restated)
iTunes-only catalogue (Radio/Movies/TV/Podcasts/iTunes U/Audiobooks/Genius) ·
pairing ceremony UI · multi-library switch · widgets · visualizer ·
history · sort-by · disconnect/screen-lock prefs.
