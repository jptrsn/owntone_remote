# SCREENS — OwnTone Remote

**Status: partial.** The **now playing** screen + persistent notification
(unit 002) are specified below — **reviewed and approved by the user
2026-10-11, no changes requested** (decisions: no tap-to-fullscreen text
in v1; drag-state sliders; optimistic updates + rollback snackbar;
notification metadata title/artist/album with play/pause/next/previous
controls; stopped state keeps play enabled). All other screens
are the job of the `spec-authoring` intent (never run yet) — this file is
created early so remote-app units have a finish line, and each section is
added there.

Behaviour-based, Material 3 (D6): this documents *what* each screen shows
and does, mapped to JSON endpoints — not ReTune's pixels (D5 clean-room).
The UX *shape* mirrors ReTune's information architecture: a remote that is
always looking at the server's now-playing state, with the library
reachable one tap away.

| Screen | Spec | Required by |
|---|---|---|
| Settings (server host/port) | specified in unit 001 (see its Result) | R-01, R-14 |
| **Now playing** | below | R-03, R-04, R-05, R-07 |
| Notification (persistent) | below | R-07 |
| **Outputs / speakers** | below (unit 004) | R-09 |
| Library browse (playlists / artists / albums / genres) | TBD | R-10 |
| Queue | TBD | R-11 |
| Rating (stars on rows + now playing) | TBD | R-12 |
| Search | TBD | R-13 |

---

## Now playing (R-03, R-04, R-05, R-07)

The app's home screen and the live mirror of the server's player. Single
source of truth: `PlayerController` (REST refetch on every WS
invalidation, D2); the screen and the notification are both projections
of it.

### Layout (top → bottom, fixed, never scrolls)

All controls must be visible in the viewport without scrolling; the
artwork absorbs the slack and shrinks (1:1 preserved) — user requirement
2026-10-11, unit 001 criterion 8.

1. **App bar** — app name; `OwnTone <version>` (from `/api/config`);
   sync label derived from the WS phase (`sync: live` /
   `sync: reconnecting…` / `sync: off (server)`); settings action →
   Settings screen.
2. **Offline banner** (app-wide, unit 001) — shown whenever the
   connection is not `connected`; all controls below are disabled while
   it is up.
3. **Output line** — `Playing via: <selected output names>` (from
   `/api/outputs`); hidden when there are no outputs.
4. **Artwork** — square, `maxwidth=600` downscaled from the server
   (`/artwork/…`); centered in the remaining vertical space.
5. **Title** — headline, up to 2 lines, ellipsis.
6. **Artist · Album** — one line, ellipsis.
7. **Progress row** — elapsed time (left) · seek slider · total time
   (right).
8. **Transport row** — previous · play/pause (large) · next.
9. **Mode row** — shuffle · repeat · consume · stop.
10. **Volume row** — `volume_down` icon · slider 0–100 · numeric label
    (0–100) · `volume_up` icon.

### Data

- `/api/player` → state, repeat, consume, shuffle, volume,
  `item_id`, `item_length_ms`, `item_progress_ms`, `artwork_url`.
- `GET /api/queue?id=now_playing` → title/artist/album/length/artwork of
  the current item (null when stopped or queue empty).
- Artwork: relative URLs resolved against the web root; **404 or absent
  → placeholder** (music-note icon on a surface-container box).
- **Progress while playing:** OwnTone sends no periodic `player` events.
  The screen extrapolates locally between refetches (ticker, ~500 ms,
  clamped to track length); every WS invalidation refetches and the
  extrapolation re-bases on the fresh `item_progress_ms`. **No REST
  polling** (R-03: drift stays < 2 s over 10 min of playback).
- **Refetch policy:** WS `player` / `volume` / `options` / `queue`
  events and every reconnect → refetch player + now-playing item;
  failures surface as a sync-error strip ("Sync failed — showing last
  known state"), not a blank screen.

### Actions → endpoints

| Control | Endpoint | Notes |
|---|---|---|
| Play/pause (toggle) | `PUT /api/player/play` / `pause` | **SUPERVISED** (audio) for play |
| Next / previous | `PUT /api/player/next` / `previous` | stays paused while paused |
| Stop | `PUT /api/player/stop` | |
| Seek | `PUT /api/player/seek?position_ms=N` | committed on **release** (below) |
| Shuffle | `PUT /api/player/shuffle?state=true|false` | |
| Repeat | `PUT /api/player/repeat?state=off|all|single` | UI cycle off → all → single → off |
| Consume | `PUT /api/player/consume?state=true|false` | |
| Volume | `PUT /api/player/volume?volume=N` | committed on **release** (below) |

Every action goes through `PlayerController` so the pause-origin tracker
(D9) and the notification stay consistent.

### Interaction design (decided here)

- **Drag-state sliders (spike Finding 14).** Both the seek slider and
  the volume slider use *local drag state*:
  - finger down → the slider shows the finger's position, independent of
    the server; incoming server updates (WS refetches, rocker, web UI)
    **do not move a slider that is being dragged**;
  - seek: while dragging, the local progress ticker is frozen on the
    dragged value; on release the app sends one `seek?position_ms=` and
    re-bases from the confirming refetch;
  - volume: while dragging, the label shows the local value; on release
    the app sends one `volume?volume=N`; the server's answer (refetch)
    is what the UI converges to — a failed send rolls the value back.
  - Rationale: today a remote update yanks the slider under the finger
    and a finger in contact fires a stray absolute write.
- **Optimistic updates with rollback (unit 002).** A control press
  updates the UI immediately (e.g. the play icon → pause, the repeat
  icon advances, the volume label moves); the confirming refetch
  reconciles. A failed call (5xx / network) **rolls the UI back** and
  shows a **snackbar** with the typed error (`PlayerController`
  surfaces the message; the screen renders it). The notification mirrors
  the same reconciled state.
- **Text:** title/artist/album ellipsize; **no tap-to-fullscreen text
  view in v1** (the unit's open question — decided out: the fields are
  short for this library, and a fullscreen reader is gold-plate without
  a spec). P2 candidate if it comes up.

### States

| State | Rendering |
|---|---|
| Connecting / first fetch | spinner (connected) or "Waiting for the server…" (not connected) |
| Playing | play icon = pause; progress ticking; previous/next/stop enabled |
| Paused | play icon = play; progress frozen; all transport enabled (next/previous stay paused) |
| Stopped (queue may still hold items) | title "Stopped"; progress 00:00 / 00:00; play **enabled** (restarts the current item); previous/next/stop disabled; seek disabled |
| Offline | banner up; every control disabled (stale data stays visible); WS reconnect restores without relaunch |
| Sync error | error strip on top of the stale mirror; controls stay enabled (REST may still work — R-02) |
| Artwork 404 / absent | placeholder box, everything else as normal |
| No item (stopped, empty queue) | title "Stopped", empty progress, artwork placeholder |

---

## Persistent notification (R-07)

Always present **while the app is connected** — the remote's shadow in
the shade / on the lock screen.

- **Style:** Android media style, channel "OwnTone Remote", transport
  category; `androidStopForegroundOnPause: false` so the `mediaPlayback`
  FGS (and with it the notification + media session) survives the server
  being paused or stopped (spike criterion 7: verified alive while
  paused + backgrounded).
- **Metadata** (mirrors `PlayerState` + now-playing item, updated on
  **every** controller emission):
  - large icon = current artwork (bitmap);
  - title = track title; subtext = artist; text = album;
  - duration + progress bar (1 s extrapolation ticker while the server
    plays — OwnTone sends no periodic events).
- **Controls:** play/pause toggle · next · previous → the same
  `PlayerController` methods as the screen (single path to the server).
- **No duplicates (spike risk #4):** the notification is the FGS
  notification; WS reconnects, refetches and state changes **update it
  in place** — the app must never post a second notification (verify:
  exactly one notification record for the app's package after a
  reconnect). A process kill removes it (FGS lifecycle); relaunch
  restores it with the correct state in < ~4 s (spike: verified).
- **Booted while the server is paused/stopped:** the one-shot "wake"
  (report `playing: true` for one frame, then the real state) forces
  audio_service to create the FGS + notification at all (its documented
  constraint: creation only on a playing false→true transition).
- **Known limitations (recorded, not spec violations):**
  - Android 16 may not *render* a LOW-importance transport notification
    in the shade (spike Finding 7 — record exists, never drawn).
    Lock-screen / media-session controls are the reliable surface;
    shade rendering is best-effort.
  - audio_service 0.18.19 one-shot media-button dispatch per app process
    (Finding 5) — affects repeated notification-button presses;
    resolved or accepted in unit 003.

---

## Outputs / speakers (R-09)

Specified in unit 004. Reached from the now-playing "Playing via: …" line
(tappable, cast icon — the remote's current-speaker indicator, ReTune IA
per D6); the app bar stays as specified in unit 001/002.

### Layout (top → bottom, scrolls)

1. **App bar** — "Outputs", back.
2. **Offline banner** (app-wide) / **sync-error strip** (same as now
   playing).
3. **Output rows**, one per `GET /api/outputs` entry, server order. Each
   row: checkbox (selected state) · name · type string · lock marker if
   `has_password`/`needs_auth_key` · numeric volume label · per-output
   volume slider (0–100).

- **Type rendering:** the string as-is (`Chromecast`, `AirPlay 1`,
  `ALSA`, …). No icons, no parsing — unknown types are display-only text
  (docs/API.md).
- Rows carry a compound semantics label
  (`<name>, <type>, selected|not selected, volume N`) so UI checks can
  read them deterministically.

### Data

- `/api/outputs` → the row list. WS `outputs` (and `volume`) events and
  reconnects refetch the whole list (D2). No per-output polling.

### Actions → endpoints

| Control | Endpoint | Notes |
|---|---|---|
| Checkbox (enable/disable) | `PUT /api/outputs/set` | **one** call with the **full** selected-id list — never N per-output toggles |
| Checkbox (protected output, enabling) | PIN dialog → `PUT /api/outputs/{id}` `selected: true, pin: …` | `/set` has no pin param; wrong PIN = server 4xx surfaced, output stays disabled |
| Volume slider (release) | `PUT /api/player/volume?volume=N&output_id=…` | commit on release |

### Interaction design (decided in unit 004)

- **Playing-guard dialog (user decision 2026-10-22):** while the server
  state is `play`, *any* selection change redirects live audio — a
  confirmation dialog ("Server is playing — moving outputs redirects
  live audio. Continue?") appears before the change. Paused/stopped: no
  dialog. Volume changes are never guarded (no audio redirect).
- **Optimistic updates with rollback** (same contract as now playing):
  the checkbox flips / volume label moves immediately; the confirming
  refetch reconciles; a failed call (5xx / network / 4xx) rolls back and
  shows a **snackbar** with the typed error.
- **Drag-state volume sliders** (spike Finding 14): while a finger is
  down, the slider + label follow the finger and ignore server updates;
  one REST call per release.
- **Empty set** is a legal selection (disables all outputs); the server's
  answer to `PUT /api/outputs/set` with `{"outputs": []}` is recorded in
  the unit's Result.

### States

| State | Rendering |
|---|---|
| First fetch | spinner (connected) / "Waiting for the server…" (not connected) |
| Loaded | rows, checkboxes + sliders enabled |
| Empty server | "No outputs on this server." |
| Offline | banner up; checkboxes + sliders disabled; stale rows stay visible |
| Sync error | error strip over the stale list; controls stay enabled (REST may still work — R-02) |

## Library browse (R-10)

Specified in unit 005a. Reached from the now-playing body's "Library" text
button, beside the "Playing via: …" line (unit 004/005a: a *second*
app-bar icon overflows the 360-logical-px viewport by 9px, so the entry
lives in the body; the row is always present so the entry exists even
with no outputs). All rows are disabled while offline, like the rest of
the app.

### Screens

One screen per list, all sharing `BrowseScreenScaffold` + `PagedBrowseList`
(app bar title + back, offline banner, paged body):

| Screen | Row fields (secondary) |
|---|---|
| Library home | Playlists / Artists / Albums / Genres (section rows, chevron) |
| Playlists | `smart playlist` / `playlist` / `folder` · `N items` |
| Artists | `N albums · M tracks` |
| Albums | `artist · year` (each omitted when absent/0) |
| Genres | `N tracks · M albums` |
| Artist → albums | album fields (as Albums) |
| Genre → albums | album fields (as Albums) |
| Album → tracks | `track N` · `M:SS` length |
| Playlist → tracks | `track` · artist · `M:SS` (no number — playlist order is not album order) |

Rows carry a compound semantics label
(`<name>, <kind>, <fields>`) for deterministic UI checks.

### Data

| List | Endpoint |
|---|---|
| Playlists | `GET /api/library/playlists` |
| Playlist tracks | `GET /api/library/playlists/{id}/tracks` |
| Artists | `GET /api/library/artists` |
| Artist albums | `GET /api/library/artists/{id}/albums` |
| Albums | `GET /api/library/albums` |
| Album tracks | `GET /api/library/albums/{id}/tracks` |
| Genres | `GET /api/library/genres` (server ignores `offset`/`limit` — none sent) |
| Genre albums | `GET /api/search?type=albums&expression=genre%20is%20%22<name>%22` |

- **Pagination:** `offset`/`limit=50`; a scroll position within
  `300px` of the end fetches the next page; items de-duplicate on stable
  keys (id, or name for id-less genres); `total` is respected (no fetch
  past it). Proven on-device: genres 79/79 and artists 217/217 unique.
- **Genre expression encoding (unit 005a finding):** the expression
  `genre is "<name>"` (inner `"` escaped to `\"`) is percent-encoded with
  `Uri.encodeComponent` and embedded **in the request path**, not in
  `queryParameters` — dio 5.11 percent-encodes string query values with
  `Uri.encodeQueryComponent`, which would (a) double-encode an
  already-encoded value and (b) emit `+` for spaces instead of the
  spec'd `%20`. On-device wire proof: `R&B / Soul & Funk` →
  `expression=genre%20is%20%22R%26B%20%2F%20Soul%20%26%20Funk%22`, which the
  server decoded and matched (1 album). A bare `/api/search`
  `queryParameters` value with an unencoded `&` would have split the
  query — the regression the encoding table guards.
- **Invalidation:** WS `database`/`update` events refetch the open list;
  a transition back to `connected` refetches too (R-02).

### States (every list)

| State | Rendering |
|---|---|
| First fetch | skeleton rows |
| Empty | icon + one-liner ("No albums in Rock.", "This playlist is empty.", …) |
| Error | retry button (retries the first page) |
| Offline | banner up; stale rows stay; rows disabled; reconnect refetches |
