# REQUIREMENTS — OwnTone Remote

**Status: v0.1 draft.** Seeded from the approved scope (PLAN.md §3–4) on
2026-10-08. Finalized in `spec-authoring` after the pruned capture inventory
exists; R-IDs are stable from now on — add, don't renumber.

Tests must cite the R-ID (AGENTS.md § Tests).

## Non-functional constraints

| ID | Constraint |
|---|---|
| N1 | Android: targetSdk 36, minSdk 26 (D11) |
| N2 | No Google Play Services dependency |
| N3 | Cleartext HTTP to the LAN server (N3: `usesCleartextTraffic`) |
| N4 | Must work on GrapheneOS (Phase 5): per-app Network permission, no GMS |
| N5 | The app never decodes or plays audio locally — it is a remote control (D1/D3) |
| N6 | UI in Material 3; mirrors ReTune's information architecture, not its pixels (D6) |
| N7 | Audio safety: no audible playback on the server without user presence + explicit confirmation (D16) |
| N8 | Open source: no decompiled ReTune code/assets, no ReTune branding (D12) |

## Functional requirements

### R-01 Connection — P0
Manual entry of server host + JSON port; websocket port discovered from
`GET /api/config`. Persisted across launches (auto-reconnect on start).
**Acceptance:**
- entering a valid host connects; a wrong host shows a specific error (DNS vs refused vs 401);
- server state (player/outputs) loads after connect;
- killing and relaunching the app reconnects without re-entering the host.

### R-02 Websocket sync — P0
Subscribe to `player, volume, outputs, queue, options, database, update`
events. Every event is an invalidation → refetch of the affected slice (D2).
**Acceptance:**
- a change made in the server web UI (e.g. pause, skip while paused, volume)
  appears in the app's UI + notification within ~2 s;
- on WS disconnect: exponential backoff reconnect (1 s → 30 s cap);
- on reconnect: full refetch of player + outputs + current queue item;
- WS failure never blocks REST control (controls work with degraded sync).

### R-03 Now playing display — P0
Artwork (with fallback), title, artist, album, progress bar (seekable via
`position_ms`), elapsed/total time.
**Acceptance:**
- all fields render from `GET /api/player` + `artwork_url` (relative URLs
  resolved against the web root; `maxwidth` param used; 404 → placeholder);
- progress tracks the server (WS + periodic refetch while playing);
- seek from the UI lands within ±1 s of the requested position;
- the screen never overflows the visible viewport: all controls are visible
  without scrolling — the artwork shrinks to make room, preserving its 1:1
  aspect ratio (added 2026-10-11, user requirement).

### R-04 Transport controls — P0
Play/pause (toggle), next, previous — in the app, in the notification, and on
the lock screen (MediaSession).
**Acceptance:**
- every control in every surface calls the right endpoint (`/api/player/…`);
- controls work while the app is backgrounded;
- the notification reflects server-side changes (WS-driven, R-02).

### R-05 Playback modes — P0
Shuffle toggle, repeat cycle (off → all → single), consume toggle.
**Acceptance:**
- current state shown accurately (from `/api/player`);
- each toggle sends the right `PUT` and the UI reflects the server's
  response state (not just the optimistic one);
- WS `options` events update the UI without a manual refresh.

### R-06 Master volume — P0
Volume slider in the app (0–100, `?volume=`) **and** hardware volume
rocker (`?step=`). **The rocker maps to the server's master volume only
while the app is in the foreground** (D20, user decision 2026-10-22).
When the app is backgrounded, the phone's volume keys perform their
normal function and the app must **not** control the server's volume —
including while the server is playing.
**Acceptance:**
- slider change verified via `GET /api/player` `volume`;
- with the app in the foreground, rocker up/down changes master volume
  by ±5 (default step — open item) (verified 2026-10-22 on a real
  Pixel 6, server stopped: 36→41→36);
- with the app backgrounded (any screen state, any server state —
   including server `play`), rocker presses leave the server volume
   unchanged (verified 2026-10-22 on the Pixel 6: backgrounded +
   screen-off with the server stopped, volume held 36; and supervised
   with the server `play` — rocker up *and* down, volume held 36);
- volume WS events keep slider and notification in sync.

### R-07 Persistent notification — P0
Always-present media notification while the app is connected: artwork,
metadata, transport controls. Survives app process death (FGS).
**Acceptance:**
- notification shows the current track + working controls;
- process death (or Android reclaim) while paused → notification + service
  recover on relaunch, or the gap is documented as a known limitation with
  a user-visible "reconnect" path (spike criterion 7 decides);
- no duplicate notifications after WS reconnect.

### R-08 Call handling — P0
Incoming call (ringing or off-hook) pauses server playback; on call end,
auto-resume (D9). Only resumes if *the app paused it for the call* —
a user-initiated pause is not resumed.
**Acceptance:**
- simulated call (emulator Extended Controls) → `GET /api/player` state
  `pause`;
- call ends → state `play` (supervised test);
- user pause before the call → still paused after the call.

### R-09 Outputs / speakers — P1
Screen listing all outputs (`GET /api/outputs`): name, type, selected state,
volume. Multi-select enable/disable via `PUT /api/outputs/set`. Per-output
volume (`PUT /api/player/volume?output_id=`). PIN dialog for
`has_password` / `needs_auth_key` outputs (`pin` body param).
**Acceptance:**
- list matches the server exactly;
- toggling one output sends the full selected-id set (not N toggle calls);
- per-output volume verified via `GET /api/outputs`;
- PIN prompted before enabling a protected output.
- volume control rendered **disabled (but visible)** for every output where
  `selected == false` (OwnTone web-UI parity — issue #19), and enablement
  follows the live `outputs` websocket update, not just the initial fetch;
- deselecting an output while **≥1 output stays selected** is **silent**
  even during playback — audio simply continues on the remaining outputs
  (OwnTone web-UI parity — issue #20); deselecting the **only** selected
  output confirms first, and on confirm, while the server plays, playback
  is **stopped** server-side (`PUT /api/player/stop`, not pause);
- *(Changing which output is active while playing is a supervised action —
  R-N7.)*

### R-10 Library browse — P1
Browse the library in ReTune's shape (final depth from pruned inventory):
at minimum Playlists, Artists, Albums, Genres; artist → albums → tracks;
album → tracks; playlist → tracks. Pagination (offset/limit, load-more).
Loading / empty / error / offline states on every list.
**Acceptance:**
- each screen's data comes from the documented endpoint (API.md);
- pagination continues past page 1 without duplication;
- empty library slice shows the empty state, not a blank list;
- server unreachable shows the offline state and recovers on reconnect.

### R-11 Queue — P1
View current queue (`GET /api/queue`, now-playing highlighted via
`item_id`), play an item (supervised), clear queue.
**Acceptance:**
- queue list matches the server; now-playing row is identifiable;
- tapping a **queued** row advances the queue **in place** — same items,
  tapped entry becomes the current track (`PUT /api/player/play?item_id=…`,
  OwnTone web-UI parity — issue #21); the queue-replacing
  `POST /api/queue/items/add?…&clear=true&playback=start` belongs to
  browse/search "play this" only; both supervised (audible);
- clear works; WS `queue` events refresh the list.

### R-12 Rating — P1
Show rating (0–100 → 5 stars) on track rows and now playing; tap to set
(`PUT /api/library/tracks/{id}?rating=`); `database` WS event refreshes.
**Acceptance:**
- displayed star value == server value (mapping 0/20/40/60/80/100);
- setting a rating persists (visible in the server web UI);
- supervised mutation protocol: record original → set → verify → restore →
  verify restore (AGENTS.md §4).

### R-13 Search — P1 (confirm against inventory)
`GET /api/search?type=tracks,artists,albums,playlists&query=`; results
grouped by type; tap-through to the corresponding detail screen.
**Acceptance:**
- a query returns grouped results with correct pagination;
- empty query / no-results states handled.

### R-14 Settings — P2
Server host/port (R-01), volume-rocker step size, (later) discovery,
multi-server. About screen with server version.
**Acceptance:**
- settings persist; changes apply without restart where sensible.

## v1.1 additions — retune-ux-capture gate (accepted 2026-11-19)

Derived from `docs/retune-capture/diff-list.md` (ReTune 3.5.23 reference);
issues drafted in `.ai-dlc/retune-ux-capture/issues/`.

### R-15 Songs (all-tracks) browse — P1
Library home gains a **Songs** section listing every library track as a
paged two-line list (`title` / `artist - album`) via
~~`GET /api/library/tracks`~~ **`GET /api/search?type=tracks&query=`**
(paginated — spec corrected 2026-11-20: `GET /api/library/tracks` has no
collection route on OwnTone 29.3, source-checked + live 400; the
empty-query search branch is the proven equivalent, cf. `docs/API.md`);
rows use `TrackRow` semantics (rate + play accessory per R-12/R-10).
**Acceptance:** list pages correctly and survives reconnect refetch
(same contract as other browse screens); row play replaces the queue and
starts; row rating flow works.

### ~~R-16 Playlist row artwork + smart badge~~ — WITHDRAWN
*(user declined at issue review 2026-11-19 — "skip it, I don't care about this one"; issue draft not posted; diff-list D-05 marked SKIPPED)*

<details>
<summary>original text</summary>
`PlaylistRow` leads with the playlist artwork (through `ArtworkProbe` —
one-GET-per-URL verdict, 204 → normal no-image branch, per unit 010) with
the current `queue_music` icon as fallback; smart playlists show a
"smart" chip from the API `smart` flag.
**Acceptance:** artwork shown when the server has one; no 204 errors
logged; icon fallback otherwise; badge matches server flag.

</details>

### R-17 Now-playing context navigation — P2
Now-playing overflow gains **Go to Artist** and **Go to Album** opening
the corresponding browse detail screens (`ArtistAlbumsScreen` /
`AlbumTracksScreen`) for the current track.
**Acceptance:** both navigate to the right screen; disabled/inert when no
track is loaded.

### R-18 Global outputs access — P2
Browse screens (library home + all paged browse lists) carry the outputs
action in the app bar (same destination as now-playing's), respecting the
360-logical-px viewport finding (unit 004 — no overflow).
**Acceptance:** one tap from any browse screen to Outputs; no app-bar
overflow at 360 dp.

### R-19 Browse-detail context actions — P1
Playlist/album (and artist-albums) detail screens gain an overflow with
**Play All · Shuffle · Play Next · Add to Up Next**. `QueueController`
gains add-only (`POST /api/queue/items/add` without `clear`,
`playback=` per `docs/API.md` — verify the exact param live) and a
shuffle-then-play path.
**Acceptance:** Play All replaces+plays (supervised); Shuffle plays the
set shuffled without toggling global shuffle mode (verify against
server — if server-side shuffle-first needs `?random`, use it, else
client-side pre-shuffle); Play Next inserts ahead of the current next
item; Add to Up Next appends without playback change; all four keep
queue events refreshing the UI (unit 011 single-flight).

### R-20 Server auto-discovery — P2
Connection setup browses `_http._tcp`… **exact OwnTone service type to be
verified live** (`dns-sd -B` against the server; OwnTone advertises via
Avahi — check `/api/config` + avahi publish type) and lists discoverable
servers for one-tap selection; manual host/port entry remains the
fallback and default. No pairing ceremony (OwnTone JSON has none).
**Acceptance:** on a LAN with the server running, the server appears
without typing an IP; picking it connects (R-01 flow); discovery timeout
never blocks manual entry.

### R-21 Drawer navigation — P1 (user decision 2026-11-19, N-02 option B)
Add a Material 3 **NavigationDrawer**, ReTune-style (`23-playing-audit`
A1 evidence): header **Connected To — <server name from /api/config>**;
sections **Playing** (Now Playing · Queue), **Library** (Library home —
then the Views list Playlists/Artists/Albums/Songs(+Genres/Composers as
R-15 lands, deep-linkable), and **Settings** (server + rocker step) +
**Outputs**. A **hamburger opens the drawer on every screen** (Now Playing
root and every pushed screen; ReTune's UpNext-activity gap is NOT copied).
Selecting an item from a pushed screen **must not stack duplicates**:
`popUntil(isFirst)` then push the target (follow the `showNowPlaying`
warning at `root_screen.dart:9-20`). Selected destination gets
`Semantics(selected:)` (ReTune exposes none — do better, unit-009 pattern).
Drawer state must not leak focus/scroll weirdness (back closes drawer
first).
**Acceptance:** hamburger present on all main screens; each destination
lands exactly once (no duplicate routes in the stack — assert route
count); offline: drawer opens but library/queue items inert (banner
contract); semantics labels assert the selected state.

### R-22 Persistent mini transport bar — P1 (N-01; user: "bottom bar when
a track is playing")
A pinned **bottom mini player** on every screen except Now Playing itself:
2-line metadata (title / `artist - album`) + prev/play-pause/next,
driven by `PlayerController` (same icon-state mapping as
`mirror_handler.controlsFor`), tap on the metadata zone →
`showNowPlaying`. **Visible whenever a current item exists** (playing or
paused — ReTune keeps the bar through pause, verified `12`/`lib-playing`);
**hidden when stopped/no current item** (ReTune keeps dead transport
buttons then — deliberate simplification, recorded). Play/pause press
routes to `PlayerController` (never `playUris`). Transport buttons get
tooltips + semantics (ReTune has none — a11y gap not copied). Must coexist
with the offline banner (banner above the bar) and not steal taps from
list rows behind it (bar is its own layer, not a list footer). Auto-hide
details: none (the bar persists — contrast the volume toast, which is
transient by design, `22-volume-toaster`).
**Acceptance:** bar present while playing/paused on Library/Queue/
Outputs/Search/Settings routes, absent when stopped; play/pause toggles
server state (supervised once); prev/next change item; tap → Now Playing
and **exactly one** NP route exists; row taps still work while bar shown.

### R-23 Queue drag-reorder — P1 (N-03)
`QueueScreen` supports **tap-and-hold drag reorder** (ReTune gesture,
`16`/A3) committing on drop via `PUT /api/queue/items/{id}?new_position=N`
(`docs/API.md:94`); `QueueController.moveItem(item, newIndex)` follows the
existing `_action` pattern (optimistic move, rollback + typed snackbar
error, trailing post-commit refresh — single-flight per unit 011). With
**hide-played ON** the drag indices map through `visibleQueue`'s cut to
absolute positions (or drag is disabled while ON — implementer picks the
simpler correct option; assert behavior either way). Reordering the
now-playing entry: disallow (drag its row = no-op) — OwnTone semantics
keep current fixed; verify live. WS `queue` event during a drag: the
drag keeps local order, refetch lands on drop-commit reconciliation.
**Acceptance:** unit tests for index mapping (incl. hide-cut) on pure
fns; widget test drives a drag and asserts the exact PUT (captured
request) — no network; live/manual supervised once on device; gates green.

### R-24 Queue per-row actions: Remove + Play Next — P1 (N-04)
Queue rows gain ReTune's per-row menu (A3 evidence — accessory popup
**Play Next · Remove**): `QueueController.removeItem(item)` →
`DELETE /api/queue/items/{id}` (`docs/API.md:95`) and `addUris`-based
play-next = `POST /api/queue/items/add?uris=…&position=<after current>`
(verify position param semantics live against `docs/API.md`); both through
the `_action` pattern. Swipe-to-dismiss may implement Remove **instead of
a visible accessory** if it matches the visual language — must stay
undoable-feeling (rollback on failure) and must **never** remove the
now-playing row (disable for it).
**Acceptance:** unit tests capture the exact endpoints/params; removing a
row optimistic-removes + rolls back on failure (fake 500); now-playing row
cannot be removed; hide-played interplay covered; supervised manual once.

### R-25 Browse section headers — P2 (N-05)
Artists/Genres/Songs (R-15) paged lists render **alphabetical section
headers** (ReTune `basic_header` pattern, `03`/`10` evidence): computed
client-side from the loaded pages (server returns sorted lists — verify
sort with `cc=` + `order` params live), header row = group divider
(disabled, non-clickable, semantics-excluded like ReTune's disabled rows;
"sticky-ish" dropped at implementation 2026-11-20 — plain scrolling row,
adjudicated in the frozen issue copy, do not "restore" stickiness);
paging across a letter boundary must not duplicate the
header.
**Acceptance:** widget test: fake pages [A…A, B…] → headers rendered
once each; rows unchanged (reuse `BrowseRow`); gates green.

### R-26 Theme preference (Light · Dark · Follow system) — P1
*(direct user request 2026-11-19, issue #43 — not a ReTune diff-list row;
numbered R-26 because R-21..R-25 are claimed by the retune-ux-capture
intent)*
Settings (next to the rocker step) gains a three-way theme picker —
**Light / Dark / System**. `Light`/`Dark` force the scheme; `System` (the
default) follows `platformBrightness`, **including live while the app is
open** (a system toggle mid-session re-skins with no restart). The dark
scheme is `ColorScheme.fromSeed` with the **same seed** (`0xFF7C5CBF`,
`brightness: dark`) — no bespoke palette in v1. The choice persists via
`SettingsStore` (key `theme.mode`, same pattern as `rockerStep`:
read-validate fallback — corrupt/legacy value → `system`) and applies on
the next screen without an app restart. No hardcoded colors on the affected
paths (now-playing's no-artwork placeholders become scheme-derived).
Behavior change to call out: once `darkTheme` exists, `System` (default)
actually follows the system — users on a dark phone see the app flip
(accepted — that is the point of the issue).
**Acceptance:** three modes render the correct brightness; default is
`System`; selection survives app kill/relaunch; `System` follows a platform
brightness change while running; corrupt persisted value degrades to
`System`, never a crash; dark scheme derives from the existing seed.

## Explicitly out of scope

See PLAN.md §4. In particular: **all iTunes-specific ReTune features
(radio, movies/TV, iTunes U, podcasts, audiobooks, courses, classes,
Genius), widgets, multi-server, playlist editing, offline playback,
DAAP/DACP.**
Dropped at the 2026-11-19 capture gate (user-confirmed): play-**history**
view (no JSON endpoint), visualizer/peak-meter, playlist client sort,
screen-off-disconnect, screen-lock, default-view prefs, half-star
ratings, home-screen widgets, multi-library switching. **mDNS discovery
moved INTO scope** 2026-11-19 (R-20) — the earlier exclusion predates the
capture gate.
