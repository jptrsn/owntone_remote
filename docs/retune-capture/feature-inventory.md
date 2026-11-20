# ReTune 3.5.23 feature inventory (2026-11-19) — **v2, code-verified**

> **Correction pass 2026-11-19:** v1's "new-app today" column was written
> from unit-doc memory and was wrong on at least five rows (no bottom
> nav exists; no mini-player; no queue drag-reorder; browse counts DO
> exist; smart playlists DO have a text marker). Every row below was
> re-derived by reading `lib/src` (file:line as of HEAD `1d2e99e`). The
> app's actual navigation model: **Now Playing is the root route;
> Library/Queue/Outputs/Settings are pushed on top; "switch to NP" =
> `popUntil(isFirst)`** (`root_screen.dart:11-20,34-42`).

Status: **port** = parity · **variant** = both exist, differ · **gap** =
lacks it (diff-list row) · **drop** = no JSON way / declined · **out** =
itunes-only or scope. Evidence: `NN-*/notes.md` (ReTune), cited code (new
app), `docs/REQUIREMENTS.md` R-IDs.

## Global chrome
| ReTune feature | New app (verified) | Status |
|---|---|---|
| Mini now-playing bar (metadata + 3 transport) on ALL browse/search screens | **Nothing persistent** — pushed screens have no player surface at all (`root_screen.dart`, `browse_screen_scaffold.dart`) | **gap (N-01)** |
| Drawer: Now Playing · Up Next · Views, everywhere | No drawer/nav widget; the 3 entry buttons (Playing via · Queue · Library) exist ONLY on Now Playing (`now_playing_screen.dart:321-366`) | **variant (N-02)** |
| Speakers action every app bar | Outputs entry on NP only (`now_playing_screen.dart:327`) | gap → **filed #40** (BrowseScreenScaffold already takes `actions:` — `queue_screen.dart:111`) |
| Search action every app bar | Search from LibraryHome only (`browse_screens.dart:37,66`) | variant — N-02 covers |
| Restore last screen on relaunch | Fixed: NP root (or Settings when disconnected) (`root_screen.dart:34-42`) | drop (D-13, user-confirmed) |
| Alphabetical section headers (artists/genres/queue) | None in paged browse (`paged_browse_list.dart` — plain ListView) | **gap (N-05)** |

## Library home + browse
| ReTune feature | New app (verified) | Status |
|---|---|---|
| Views: Playlists/Artists/Albums/Songs/Genres | LibraryHome has all but **Songs** (`browse_screens.dart:36-42`) | Songs gap → **filed #38** |
| Row counts | Artist "N albums · M tracks" (`browse_rows.dart:163`), genre counts (228), playlist "kind · N items" (129), album artist·year (no count in secondary) | port (album count = nit) |
| Smart-playlist marker | Text in secondary: "smart playlist · N items" (`browse_rows.dart:122-129`) — no chip/artwork | port-lite (D-05 declined by user) |
| Artwork on rows / grid mode | Icon leading everywhere (`browse_rows.dart` — zero ArtworkBox) | D-03 **deferred** (user); D-05 declined |
| Artist → songs · Genre → artists | Artist → **albums** → tracks; Genre → **albums** (`browse_screens.dart:170,305`) | variant (D-08, user: keep) |
| Row play accessory | `_PlayButton` = `playUris` clear+start (`browse_rows.dart:91-106`); TrackRow tap = play, stars separate (276-296) | port |
| Detail overflow Play All/Shuffle/Play Next/Add | Nothing (`paged_browse_screen.dart` full read) | gap → **filed #41** |
| Playlist Sort By | Server order | drop (D-14, user-confirmed) |
| TrackRow second line | `showArtist` → **artist only** (`browse_rows.dart:273-278`) — ReTune songs rows are "artist - album" | nit on **#38** (Songs rows should carry artist + album) |

## Search
| ReTune feature | New app (verified) | Status |
|---|---|---|
| Grouped live results, no playlists | 4 groups **incl. playlists**, per-group "Load more" paging, rows reused, tap→NP (`search_screen.dart:18-36,289-323`) | port+ (unit 007 + #24) |
| Clear-query action | `ValueKey('search-clear')` (210) | port |

## Now playing
| ReTune feature | New app (verified) | Status |
|---|---|---|
| Transport prev/play/next | filledTonal/filled buttons (`now_playing_screen.dart:481-502`) | port |
| shuffle/repeat modes | `_SelectableIconButton` w/ `Semantics(selected:)`, repeat_one variant (524-537) | port+ (a11y beats ReTune) |
| Stop + consume (ReTune lacks both) | (539-549) | exceeds ✓ |
| Progress: elapsed + −remaining, no slider | seek slider + elapsed/total (454) | variant (new app better; keep) |
| Volume rocker + toaster | rocker via platform channel + app-rendered level (#22 suppresses system panel) + step setting (`settings_screen.dart:191-214`) | port+ (step exceeds ReTune's fixed 5) |
| Artwork | ArtworkBox w/ probe verdict (unit 010) | port |
| Stars on np | own row below artist/album (#25; issue #39 adds Go-to context) | port |
| Go to Artist/Album | absent (`now_playing_screen.dart:122-152` app bar = settings icon only) | gap → **filed #39** |
| Peak meter/visualizer | none | drop (D-12, user-confirmed) |

## Queue
| ReTune feature | New app (verified) | Status |
|---|---|---|
| Post-current list / History | Full queue incl. current, highlight = primaryContainer + play icon + semantics (252-281); hide-played toggle (#23) | variant (R-11 as specified) |
| History tab | n/a — no endpoint | drop (D-17, user-confirmed) |
| **Drag-reorder** | **absent** (no move in `queue_controller.dart`; R-11 never required it — API PUT move exists, `docs/API.md:94` "if S8 queue-reorder is kept") | **gap (N-03)** |
| **Remove single item** | **absent** (only clear-all w/ confirm, `queue_screen.dart:124-129`; DELETE endpoint exists, `docs/API.md:95`) | **gap (N-04)** |
| Tap queued row = skip in place | `skipToQueueItem` (#21, `queue_screen.dart:137-140`) | port+ (matches web UI) |

## Outputs (Speakers)
| ReTune feature | New app (verified) | Status |
|---|---|---|
| Master + per-output sliders, checkboxes | per-output Slider(357) + Checkbox + PIN dialog + "no outputs left" guard; **no master slider on the screen** (master lives on NP) | port (master-on-outputs = nit) |
| Global reach | NP only | #40 |

## Settings / misc
| ReTune feature | New app (verified) | Status |
|---|---|---|
| Server host/port | Host + JSON port (`settings_screen.dart:145-159`) | port |
| mDNS discovery | absent | gap → **filed #42** |
| Rocker step | 1–10 stepper, persists (`settings_screen.dart:191-214`) | exceeds ✓ |
| Disconnect | **exists** — Settings → Disconnect (185-186) (location differs from ReTune overflow) | port |
| Theme Light/Dark | system-only (`main.dart:157` fromSeed, no themeMode) | D-10 **deferred** (user) |
| Notification/FGS | audio_service silent channel (dv-004 verified) | port (D-19 ✓) |
| Pause on incoming calls | **R-08 exists and specifies it** (REQUIREMENTS:100-102 — pause-on-call, resume-if-app-paused) — verify on device next dv pass (D-15 verify item stands) | port per spec |
| About w/ licenses | about_screen (R-14b) | port |
