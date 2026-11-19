# ReTune 3.5.23 feature inventory (captured + static, 2026-11-19)

Status: **port** = already in new app (parity) · **variant** = both exist,
differ (diff-list row) · **gap** = new app lacks it (diff-list row) ·
**drop** = no JSON way / declined · **out** = itunes-only or scope.
Evidence: `NN-*/notes.md` (walk), `static-notes.md` (APK),
`docs/REQUIREMENTS.md` R-IDs for the new app.

## Global chrome
| Feature | JSON | Status |
|---|---|---|
| Persistent mini now-playing bar (2-line + 3 transport) on all browse/search | GET /api/player + ws | port (mini player, R-08) |
| Global drawer: Now Playing · Up Next · Views | — | variant (new app: bottom nav; D-07) |
| **Speakers action in every app bar** | GET/PUT /api/outputs | **gap (D-09)** — new app: outputs only from now-playing |
| Search action in every app bar | GET /api/search | variant (new app: search from Library home only — viewport decision unit 004) |
| Restore last-viewed screen on relaunch | — | drop (cold-start-home is fine; D-13) |
| Section index / alphabetical headers | cc= params | port (paged browse w/ headers where relevant) |

## Library home + browse
| Feature | JSON | Status |
|---|---|---|
| Views: Playlists/Artists/Albums/**Songs**/Genres (+Composers out) | /api/library/* | **gap (D-02)** — Songs (all-tracks) tab missing |
| Artist → **songs** (genre headers) | tracks?cc=artist | variant (new app: artist→albums→tracks — D-08) |
| Genre → **artists** | artists?cc=genre | variant (new app: genre→albums) |
| Playlist rows: **artwork + smart-playlist badge** | artwork_url, smart flag | **gap (D-05)** |
| **Grid display mode** w/ artwork + "N album, M songs" counts | counts in cc= responses | **gap (D-03)** |
| Row play accessory (replace queue + start) | POST /api/queue/items/add?clear=true&playback=start | port |
| Detail overflow: Play All / **Shuffle** / **Play Next** / **Add to Up Next** | add w/ shuffle / no-clear | **gap (D-06)** (playUris exists; add-only + shuffle-first missing) |
| Playlist Sort By (client cycling) | — | drop (server order is the contract; D-14) |
| Long-press rows | — | n/a (= tap; nothing to port) |

## Search
| Feature | JSON | Status |
|---|---|---|
| Live grouped results Albums→Artists→Songs (**no playlists**) | GET /api/search (incl. playlists) | port+ (new app superset, unit 007) |
| Clear-query action | — | port |

## Now playing
| Feature | JSON | Status |
|---|---|---|
| Transport + shuffle/repeat (icon-only state) | PUT /api/player/* + shuffle/repeat | port |
| Elapsed + **−remaining** (no total, no seek bar) | item_progress/length | variant (new app: elapsed/total + slider — strictly better; keep) |
| Visualizer / peak meter | dacp.visualizer | **drop** (visual flourish; JSON way = none; D-15) |
| Genius / Genius shuffle | — | out: itunes-only (removed 2026-11-19) |
| Stars on np + half-stars pref (ratings_dialog trigger unidentified) | rating 0–100 | variant (new app: 5-tap stars; half-star display = optional D-16) |
| Overflow: Go to Artist / Go to Album | library drilldowns | **gap (D-04)** |
| Live external-state sync (~2 s) | ws (instant) | port+ (websocket = beats polling) |
| Volume via rocker + toaster overlay | PUT volume?step | port (R-13/R-14 incl. step setting — exceeds) |

## Queue
| Feature | JSON | Status |
|---|---|---|
| Up Next = post-current only; drag-reorder w/ confirm dialog | GET /api/queue, PUT move | variant (new app: full queue incl. current; reorder port — R-11) |
| **History** ("Previously Played") | **no endpoint** | **drop (D-17)** — documented untestable via JSON |
| "Up Next from Music" library grouping | — | n/a (single library) |

## Outputs (Speakers)
| Feature | JSON | Status |
|---|---|---|
| Master slider + per-output checkbox+slider(when selected) | /api/outputs family | port (parity w/ R-09 + CLK-OFF fix) |
| Reachable globally | — | see D-09 |

## Settings
| Feature | JSON | Status |
|---|---|---|
| Run in Background (FGS + silent notification) | — | port (audio_service FGS always-on) |
| Screen-off disconnect (Immediately..Never) | — | **drop** (DAAP-session concept; JSON app idles clean; D-18) |
| Lockscreen controls | — | port (R-07 notification controls) |
| Pause on incoming calls | — | variant→verify (audio_service interruption handling — D-19) |
| Use volume buttons | — | port (R-14 + step setting exceeds) |
| Reorder w/ artwork pref | — | n/a |
| Default view upon connection / default library view | — | drop (D-13) |
| Theme Light/Dark | — | **gap-lite (D-10)** — new app follows system only |
| Show rating / half stars | — | see now-playing row |
| Screen lock (keep awake charging) | — | drop (system setting) |
| Donate/Licenses/Thanks/Version | — | variant (new app About screen w/ licenses — R-14b) |
| Multi-library switch | — | drop (single-library server; D-20) |

## Pairing
| Feature | JSON | Status |
|---|---|---|
| mDNS auto-discovery (_dacp._tcp) | OwnTone: **_owntone-server._tcp** (check /api/config advertising) | **approved improvement (D-01)** — add discovery to server-config |
| Manual pair code web-UI flow | — | out (new app: direct IP/port; no pairing ceremony in OwnTone JSON) |

## ITUNES-ONLY-LISTED (one line each, D12)
Radio · iTunes Radio · Movies · Rentals · TV Shows · Podcasts (+series) ·
iTunes U/Classes · Audiobooks · Genius/Genius Mixes · iTunes Match rows ·
Home-sharing browse — all `out: itunes-only`; zero JSON-equivalent
attempts per D5/D12.

## GAP-CANDIDATES (→ `diff-list.md`, user gate)
D-01 discovery (approved) · D-02 Songs tab · D-03 grid mode · D-04 Go to
Artist/Album · D-05 playlist artwork+smart badge · D-06 detail context
actions · D-07 drawer vs bottom-nav note · D-08 artist drill path ·
D-09 global outputs action · D-10 theme setting · D-16 half-stars ·
D-19 pause-on-call verify. Drops: history, visualizer, disconnect pref,
default-view prefs, screen lock, multi-library, sort-by, widgets.
