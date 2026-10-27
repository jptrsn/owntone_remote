---
name: 007-search
status: done
intent: remote-app
supervised_steps: []
---

# Unit 007 — search (R-13)

R-IDs: R-13. Opened by device-verification unit 001: no search UI ever
existed (`SCREENS.md:28` — `Search | TBD | R-13`), so the R-13
acceptance rows were recorded FAIL there; this unit builds the feature
and those rows are re-run there afterwards.

## Goal

Search the OwnTone library: `GET /api/search?type=tracks,artists,albums,playlists&query=`,
results grouped by type, tap-through to the existing detail screens
(album tracks / artist albums / playlist tracks), "load more" per group.

## Steps / notes

- Entry point: search affordance on the library home (and/or app bar) —
  keep the 360-logical-px viewport rule from unit 004 (no overflow).
- Reuse the paged-browse row widgets (`browse_rows.dart`) so row visuals
  and semantics labels don't drift; track rows show rating stars per
  R-12 rules.
- Debounced query; empty-query state (no search yet) and no-results
  state are distinct; offline/error states like the other lists.
- Pagination per group (server `offset`/`limit`); no duplication across
  pages.
- Tests from REQUIREMENTS R-13 rows (not the impl): grouped parse,
  pagination, empty/no-results, tap-through routing; use `test/fakes/`
  for the HTTP layer. No `live`-tagged test needs the server.

## Completion criteria

1. R-13 acceptance rows (REQUIREMENTS.md) verified on-device
   (own per-unit AVD or `RemoteDev_API_36` if free — never another
   session's emulator); evidence in `## Result`.
2. Gates green (`analyze`, `format`, `test --exclude-tags live`, debug
   build).
3. `SCREENS.md` Search row updated from TBD.
4. device-verification/001 table R-13 rows updated with the new evidence.
5. SESSION-LOG entry + commit `remote-app/007: ...`.

## Result

Run 2026-10-26, ~20:30–21:30 local (opencode). Read-only unit — **no
playback path was touched on-device**: track rows, play buttons and stars
were never tapped (row-tap = play, stars = supervised mutation); the
server's `GET /api/player` was `state: pause, volume: 0,
item_progress_ms: 183192` at session start and byte-identical
(183192 frozen +2 s) at session end. Only library GETs went out.

**Device:** own disposable AVD `OwnToneVerify_API_36` (android-36
google_apis_playstore arm64, `-d pixel_6`, `disk.dataPartition.size=8192M`),
created + booted by this unit per the per-unit AVD policy; serial resolved
at boot by `getprop ro.boot.qemu.avd_name` → `emulator-5554` (serials had
shifted — the remembered `emulator-5558` was gone, `5560` was another
session's `ZipCaptions_QA_API_36`, never touched); `flutter run --debug`
attached (VM service for lens). **Deleted at the end** (below).

### Gate rows

| Gate | Result | Evidence |
|---|---|---|
| `flutter analyze` | PASS | No issues found (final tree, post-diagnostic-removal) |
| `dart format --set-exit-if-changed .` | PASS | 74 files, 0 changed |
| `flutter test --exclude-tags live` | PASS | **341/341** (`00:21 +341: All tests passed!` — 321 prior + 20 new: 6 wire in `test/search_api_test.dart`, 14 widget in `test/search_screen_test.dart`; all cite R-13; fakes only, no network) |
| `flutter build apk --debug` | PASS | `build/app/outputs/flutter-apk/app-debug.apk` (151.5 MB) |
| AVD created by unit | PASS | `avdmanager create avd -n OwnToneVerify_API_36 -k "system-images;android-36;google_apis_playstore;arm64-v8a" -d pixel_6`; never an existing AVD; hands-off emulators untouched |
| AVD deleted, none attached | PASS | `adb -s emulator-5554 emu kill` → `avdmanager delete avd -n OwnToneVerify_API_36` → "AVD 'OwnToneVerify_API_36' deleted."; `avdmanager list avd \| grep -c OwnToneVerify` → **0**; `ls ~/.android/avd \| grep -ci verify` → 0; `adb devices -l` → only `emulator-5560` (other session) |
| `SCREENS.md` Search row | PASS | table row → `below (unit 007)`; new § "Search (R-13)" (group order, row-reuse contract incl. the no-`track N`/no-number rule, per-group paging, the four+two states, wire/encoding/invalidation table) |
| dv-001 table R-13 | PASS | single FAIL row replaced by the two acceptance rows, both PASS with this evidence (`.ai-dlc/device-verification/units/001-dev-avd-full-pass.md`) |

### R-13 acceptance rows, on-device

| Criterion | Result | Evidence (uiautomator dumps `/tmp/u007_*.xml` + screenshots `.png`, local time) |
|---|---|---|
| Entry point, 360-px rule intact | PASS | Library home row list now `Search⏎Search` / Playlists / Artists / Albums / Genres (`e1_home.xml` 21:0x); entry lives in the library home ListView (a vertical list — the unit-004 app-bar overflow trap untouched); now-playing entry row NOT changed. 360×640 viewport covered by the widget test (no RenderFlex overflow) |
| Empty-query state ≠ searched | PASS | field + `Type to search the library.` (`e2_idle.xml/png`, `h1_idle.xml` after Clear); **zero** `/api/search` requests (wire asserted in `search_screen_test.dart`; on-device idle shown twice) |
| Grouped results | PASS | `the` → headers `Tracks · 466` (`f1_top.xml`), `Artists · 32` (`g5.xml`), `Albums · 111` + `Load more (artists)` (`g7.xml`) — all == `curl /api/search?type=<t>&query=the` totals; `brass` → `Albums · 8`, `Playlists · 1` + `Brass, smart playlist, 33 items` (`h3_brass.xml`) == server |
| Rows reused, no label drift | PASS | track content-desc `The A Team, Daniela Andrade, 4:31, 5 stars⏎…`, artist `The Offspring, artist, 1 albums, 6 tracks⏎…` — the `browse_rows.dart` compounds verbatim; `grep 'track [0-9]'` over all 54 evidence dumps → **0 hits**; no leading-number rows (the one `0` desc is the now-playing volume slider, not a search row) |
| Pagination per group, no dupes | PASS | *Load more (tracks)* tap (540,2056, `g3.xml` row after `The Beast` = server page-1 last) → `g4_after.xml` shows `The Beast → The Beautiful People → The Becoming` (server page-2 head); built rows mapped to server page-index window **13→27 strictly increasing** (no dup, no gap); artists page 2 the same way (window 17→29, `g8.xml`); requests `offset=25&limit=25` asserted in tests; exhausted-group hides the button (test) |
| No-results state | PASS | `zzzqqq` → `No results for "zzzqqq".` (`h2_noresults.xml/png`, node key `search-no-results`); distinct from the idle hint (both shown on-device; test asserts neither appears with the other); all-groups-fail → `Could not load search results.` + Retry — never reads as no-results (test, 500 responder) |
| Tap-through — album | PASS | `brass` → tap album `Brass, album, Thundersmack, 3 tracks` (540,1281) → existing AlbumTracksScreen: `House Party, 3:31, 5 stars` / `Blues in the Attic, 1:46, 5 stars` / `Skunk, 6:01, 3 stars` (`h5_albumtracks.xml/png`) == server album 8442824499383327534 (3 tracks) |
| Tap-through — artist | PASS | tap `The Offspring, artist, …` (540,942) → existing ArtistAlbumsScreen: `Rise and Fall, Rage and Grace, album, The Offspring, 6 tracks` (`g9_artistalbums.xml`) == server (1 album) |
| Tap-through — playlist | PASS | tap `Brass, smart playlist, 33 items` (540,2284) → existing PlaylistTracksScreen: `Good People, Thundersmack feat.Honeycomb, 2:58, 5 stars` + (`h4_pltracks.xml`) — same rows the browse screen renders |
| Track tap = play (not on-device) | PASS-by-test | `track row tap → play that track uri` asserts `POST /api/queue/items/add?uris=library%3Atrack%3A101&clear=true&playback=start` against the fake adapter — on-device row taps deliberately avoided (AGENTS §1) |

### Harness notes (for the next on-device run)

- **Soft keyboard is a text injector.** `input swipe` across the open Gboard
  gesture-types garbage into the focused field (`the` → `the to to to to`)
  and the list never scrolls. SOP: after any `input text`, `keyevent 4`
  (BACK closes only the IME when open) and **verify
  `dumpsys input_method | grep mInputShown=false`** before swiping.
  `keyevent 111` (ESC) did NOT reliably close the IME.
- **uiautomator staleness**: a dump can silently return the previous frame
  (unit-001 note) — accept a dump only when its **md5 changed** *and* it
  contains an expected marker (`dump2` helper, `/tmp/u007_dump2.sh`);
  `pkill -9 -f uiautomator` between attempts.
- The `Clear` / row / button coordinates come from the dump bounds (tap
  computed from `bounds=`), never from scaled screenshot guesses.
- `search-no-results`'s quotes land in the dump as `&quot;` — grep
  accordingly.
- Artwork 204 (`artUri … /artwork/item/1193`) still logs on the now-playing
  screen — the known open follow-up, out of scope here.

### Process notes

- One mid-unit scare: the no-results dump appeared "stuck on skeleton" —
  instrumented diagnosis (`debugPrint` in `_runSearch`/`_results`/
  `PagedList._load`, added then fully removed — `git diff` on
  `paged_list.dart` empty at commit) showed the flow correct: all four
  groups `OK n=0` → no-results renders; the "stuck" dumps were the
  debounce/fetch race + stale-frame bridge (harness, not app).
- Server left exactly as found (pause/vol 0/progress 183192 unchanged);
  no library data touched; no queue/outputs/rating mutations; no
  notifications beyond the app's own (never foregrounded audio).
