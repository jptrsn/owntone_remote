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
- tapping a track plays it (`POST /api/queue/items/add?uris=…&playback=start`
  — supervised);
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

## Explicitly out of scope

See PLAN.md §4. In particular: **all iTunes-specific ReTune features
(radio, movies/TV, iTunes U, podcasts, audiobooks, courses, classes,
Genius), widgets, mDNS, multi-server, playlist editing, offline playback,
DAAP/DACP.**
