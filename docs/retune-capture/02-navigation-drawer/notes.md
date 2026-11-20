# 02 — Navigation drawer (LibraryViewActivity)

Opened by tapping the tab title in the app bar ([0,128][321,254]).

## Sections (top → bottom)
| Section | Items | Tap target | Notes |
|---|---|---|---|
| **Connected To** | `My Music on hp-server` (row [39,367][909,498]) | likely → library detail / disconnect? (NOT exercised — read-only reference; would risk unpairing) | server name from DAAP `CtlN` txt record |
| **Playing** | `Now Playing` | → now-playing screen (see 09) | |
| | `Up Next` | → queue screen (see 10) | ReTune calls the queue "Up Next" |
| **Libraries** | `My Music on hp-server` (state: selected) | pair/switch libraries — **not walked**; not captured as UX to replicate | **out: scope** — new app is single-server by design (user 2026-11-19): Settings already holds server IP/port |
| **Views** | `Playlists`, `Artists`, `Albums`, `Songs`, `Genres`, `Composers`, `Radio`, `Audiobooks` | switch current view (drawer closes) | |

## Views inventory vs new app
| ReTune view | JSON equivalent | Status |
|---|---|---|
| Playlists | `GET /api/library/playlists` | in-v1 (SCREENS R-10) |
| Artists | `GET /api/library/artists` | in-v1 (R-10) |
| Albums | `GET /api/library/albums` | in-v1 (R-10) |
| **Songs** (all songs, flat) | `GET /api/library/tracks?query=&cc=...` (library tracks listing, paginated) | **gap candidate** — new app has no all-songs view |
| Genres | `GET /api/library/genres` | in-v1 (R-10) |
| Composers | — | **out: scope** (user 2026-11-19: not used; no JSON browse anyway) |
| Radio | — | out: itunes-only |
| Audiobooks | — | out: itunes-only |

(No Movies/TV/Podcasts items offered against OwnTone despite their layouts
existing in the APK — static pass to reconcile: drawer hides non-advertised
media kinds.)

## Edges
- tap item → drawer closes, view swaps (same activity).
- back button → closes drawer (verify back-behaviour during re-pass if a
  drawer-open capture is needed; not separately captured).
