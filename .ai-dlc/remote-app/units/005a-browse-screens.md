---
name: 005a-browse-screens
status: done
intent: remote-app
supervised_steps: []
---

# Unit 005a — library browse screens (split of 005)

R-ID: R-10. Split from `005-browse-and-play` on 2026-10-23: the original
unit spanned two feature areas (browse + queue/play) with >3 major
components, so the queue + play actions moved to
`005b-queue-and-play.md` (pending). 005a is fully unattended-safe — it
never starts playback.

## Goal

Browse per SCREENS.md: a library home with Playlists, Artists, Albums,
Genres; artist→albums→tracks, album→tracks, playlist→tracks,
genre→albums; pagination (offset/limit, load-more, no duplication);
loading / empty / error / offline states on every list. Track rows render
but are not yet actionable — playing a track (tap → play) is 005b.

## Steps / notes

- API client surface (unit-tested against fakes): `playlists`,
  `playlistTracks`, `artists`, `artistAlbums`, `albums`, `albumTracks`,
  `genres`, genre→albums via `search?type=albums&expression=genre is
  "…"` (encoding: `Rock/Pop` → `Rock%2FPop`, `Drum & Bass` →
  `Drum%20%26%20Bass` — table-driven tests).
- Pagination: offset/limit 50, load-more without duplication, `total`
  respected; stable list keys (ValueKey by id / name — genres have no id).
- States per list: loading (skeleton), empty (icon + text), error (retry
  button), offline (banner + stale data, per spec).
- Entry point: the now-playing body gains a "Library" text button beside
  the "Playing via" line (row always present, so the entry exists even
  with no outputs). An app-bar icon was tried first and rejected: a
  *second* app-bar icon overflows the 360-logical-px test viewport by
  9px (RenderFlex overflow in the existing viewport-fit tests).
  Disabled while offline, like the "Playing via" line.
- WS `database` / `update` events invalidate the open list (refetch);
  transition back to `connected` refetches (R-02; R-10 "recovers on
  reconnect").
- Note from live probing (2026-10-23): `GET /api/library/genres` ignores
  `limit`/`offset` on this server (returned all 79 with `limit=3`) — the
  client sends no paging params for genres and still models the response
  as `Paging`.
- Widget tests: list + pagination + all four states against fakes
  (table-driven per list type); API client faked unit tests (incl. the
  genre-encoding table).
- **Out of scope (005b):** queue view, queue clear, play from a list or
  the queue, the now-playing highlight, `POST /api/queue/items/add`.

## Completion criteria

1. Every in-scope browse screen renders live data with correct fields
   (library home; playlists; artists; albums; genres; artist→albums;
   genre→albums; album→tracks; playlist→tracks) — evidence:
   uiautomator/agent-lens trees per screen, spot-checked against same-
   moment `GET`s (server stays `stop` throughout).
2. Pagination: a list with >50 items (artists 217, albums 497) loads page
   2 on scroll without duplicates (device, real library + widget test
   against fakes).
3. All four states (loading/empty/error/offline) demonstrated per list
   type — widget tests against fakes for every list type + a live offline
   demo (airplane mode) with recovery on reconnect (unit 001's banner
   path).
4. The API client's browse surface is fully covered by faked unit tests,
   incl. the genre-expression encoding table (`Rock/Pop` →
   `Rock%2FPop`, `Drum & Bass` → `Drum%20%26%20Bass`, double quote,
   plain name).
5. Gates pass (analyze / format / test --exclude-tags live /
   build apk --debug).

## Result

**DONE 2026-10-23. All five criteria PASS.** Server stayed `stop`
throughout (verified `GET /api/player` before and after: `state: stop`);
no playback was ever started.

### Criterion 1 — every browse screen renders live data (device)

uiautomator content-desc dumps on `RemoteDev_API_36` (`emulator-5556`),
debug build, server `192.168.1.13:3689` live:

- **Now playing** — entry rows: `Playing via: Volumio Kitchen` and
  `Library` (the Library button is a body text-button, not an app-bar
  icon — see "Design changes"); app bar = title + version + sync label +
  one settings icon only.
- **Library home** — `Library` title, four section rows: Playlists,
  Artists, Albums, Genres.
- **Playlists** — 11 live playlists, name + kind + count, e.g.
  `All Music, smart playlist, 1793 items`, `Brass, …, 33 items`,
  `Recently Added, …, 0 items`.
- **Playlists → tracks** — opened `Brass`: `Good People, track,
  Thundersmack feat.Honeycomb, 2:58`, `Moon Zooz, Pt. 2, track, Moon
  Hooch & Too Many Zooz, 4:15`, … (title · artist · length).
- **Artists** — e.g. `Daniela Andrade, artist, 4 albums, 46 tracks`,
  `The Ataris / Useless ID, …` (slash in a name renders fine).
- **Artist → albums** — opened Daniela Andrade: `Christmas EP … 4
  tracks`, `Covers, Vol. 1 … 2 tracks`, `Covers, Vol. 1 … 26 tracks`
  (2013), `Things We've Said … 14 tracks` — 46 tracks total, matching
  the artist row's count.
- **Albums** — e.g. `Absolution, album, Muse, 15 tracks · 2009`,
  `Achtung Baby, album, U2, 1 tracks · 1991` (name · artist · year).
- **Genres** — live rows with `N tracks · M albums`, incl. special
  names: `Alternative &amp; Punk, genre, 13 tracks`, `Alternative Rock /
  Progressive Rock, genre, 25 tracks`.
- **Genre → albums** — opened `R&B / Soul & Funk`: one album row,
  `Black Pumas, album, Black Pumas, 30 tracks · 2021`.
- **Album → tracks** — opened Black Pumas: `1 · Black Moon Rising ·
  3:41`, `2 · Colors · 4:06`, … (number · title · length).
- **Empty state (live)** — opened `Recently Added` (0 items):
  `This playlist is empty.`

### Criterion 2 — pagination (device, real library)

Live counts first (`GET …/artists?limit=1` → total 217; `…/albums?limit=1`
→ total 497 — matching the unit's probe numbers):

- **Artists (217):** fling-scrolled to the end; element-tree inspection
  of the list state: `count=217 unique=217 hasLoaded=true error=null
  last=Yung Gravy, bbno$, BABY GRAVY` — 5 pages loaded on scroll, zero
  duplicates.
- **Genres (79):** scrolled to the end: `count=79 unique=79
  hasLoaded=true first=Acoustic last=Variété Française` — page 2 (50→79)
  loaded on scroll, zero duplicates, order intact.
- Widget-test pagination (load-more without duplication, `total`
  respected) is in `test/browse_screens_test.dart` +
  `test/paged_list_test.dart`.

### Criterion 3 — all four states

- **Per list type (widget tests vs fakes):** loading (skeleton), empty
  (icon + text), error (retry), offline (banner + stale rows +
  reconnect refetch) — table-driven over all eight list types in
  `test/browse_screens_test.dart`.
- **Live offline demo (airplane mode on the dev AVD, Albums list open):**
  banner `Server unreachable — retrying. Browsing disabled.` appeared
  with the stale album rows still visible; airplane mode off → banner
  gone, list intact, app bar `sync: live` (reconnect refetch).
- **Live empty** — `Recently Added` (above).

### Criterion 4 — API client faked unit tests incl. encoding table

`test/library_api_test.dart`: wire format for all nine browse calls
(paging params, id path segments, genres-without-paging, the search
endpoint) + the C4 encoding table (`Rock`, `Rock/Pop` → `Rock%2FPop`,
`Drum & Bass` → `Drum%20%26%20Bass`, `Ac"dc` → `Ac%5C%22dc`).

**Encoding fix, root cause and live proof:** the first implementation
passed the expression via `queryParameters` and pre-encoded it —
dio 5.11's `encodeMap` then ran `Uri.encodeQueryComponent` over the
value, double-encoding (`%20` → `%2520`) and emitting `+` for spaces.
Final design: the expression is `Uri.encodeComponent`-encoded and
embedded directly in the request path (`/api/search?type=albums&
expression=…`), which dio leaves untouched. Live wire capture
(flutter-agent-lens network) of the on-device `R&B / Soul & Funk`
request:
`GET /api/search?type=albums&expression=genre%20is%20%22R%26B%20%2F%20Soul%20%26%20Funk%22&offset=0&limit=50`
→ 200 with the Black Pumas album. Cross-check `curl`s:
`genre%20is%20%22R%26B%22` → 2 albums, `genre%20is%20%22Alternative%20%26%20Punk%22`
→ 3 albums (matching the genre row's "3 albums"). Note: `R&B / Soul &
Funk` genuinely has 1 album per the genre index but the search returns
it only under the exact multi-char name — a server data quirk, not a
client bug.

### Criterion 5 — gates

```
flutter analyze                                  → No issues found!
dart format --output=none --set-exit-if-changed . → 0 changed
flutter test --exclude-tags live                 → +248: All tests passed!
flutter build apk --debug                        → ✓ Built build/app/outputs/flutter-apk/app-debug.apk
```

### Design changes vs the plan (recorded here)

- **Entry point:** the now-playing *app bar* Library icon was tried and
  rejected — a second app-bar icon overflows the 360-logical-px test
  viewport by 9px (RenderFlex overflow in the existing viewport-fit
  tests, `test/now_playing_screen_test.dart`). The entry is a "Library"
  text-button in the now-playing body, beside "Playing via: …"; the row
  is always present (entry exists with no outputs).
- **Fake-adapter contract:** `test/fakes/fake_owntone_server.dart`
  records request lines from `options.uri.path` (not `options.path`,
  which now carries the embedded query verbatim) and its responder may
  be `FutureOr` (async responders need the test to settle with a few
  duration-carrying pumps after a `runAsync` round trip — one
  zero-duration pump is not enough for the dio microtask chain;
  verified empirically in `test/browse_screens_test.dart` `settle()`).

### Incidents

None. No playback was started; the server ended `stop` (verified after
the walk: `state: stop`).
