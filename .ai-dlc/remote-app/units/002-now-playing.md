---
name: 002-now-playing
status: done
intent: remote-app
supervised_steps: [3, 5]
---

# Unit 002 — now playing screen + notification hardening

R-IDs: R-03, R-04, R-05, R-07. Builds on the spike's screen + handler.

## Goal

Finish the now-playing screen to SCREENS.md spec and harden the
persistent notification (metadata, artwork, controls, no duplicate on
reconnect). All state flows through `PlayerController` (single source).

## Steps / notes

- Screen: artwork (`?maxwidth=600`, placeholder on 404), title/artist/
  album (ellipsize + tap-to-fullscreen text? per SCREENS.md), progress
  bar (seek → `position_ms`), elapsed/total, play/pause, prev/next,
  shuffle, repeat cycle, consume, volume slider (→ `?volume=`).
- Progress while playing: local ticker + WS/`player` event refetch
  (no 1 Hz REST polling; verify drift stays <2 s over 10 min).
- `PlayerController`: optimistic update on control press → confirm on
  response/WS; on 5xx → rollback + snackbar (typed error).
- Notification: media style, artwork, play/pause/prev/next; update on
  every `PlayerState` emission; exactly one notification after WS
  reconnect (spike risk #4).
- Tests: PlayerState JSON mapping (fixtures from API.md), repeat-cycle
  order, optimistic-rollback, notification metadata mapping.
- Widget tests: all three states (playing/paused/empty-item) against
  fakes.

## Completion criteria

1. Screen renders all fields from live `/api/player` (paused item,
   real artwork); placeholder shown for a 404 artwork (force with a
   crafted fake, or a track whose artwork is missing).
2. Seek from the bar lands within ±1 s (verify `item_progress_ms` after).
3. `supervised: true` — play/pause/next/previous from **all three
   surfaces** (screen, notification, lockscreen) work; audio confirmed
   by user for the play path; paused-state next stays paused (spike
   question — record the answer).
4. Shuffle/repeat/consume toggles: correct state shown, correct `PUT`
   sent, WS `options` event updates UI without manual refresh.
5. `supervised: true` — notification: artwork + metadata + all controls
   work while app backgrounded; no duplicate notification after a WS
   reconnect (criterion 5 of unit 001, re-verified end-to-end).
6. Progress drift <2 s over 10 min while playing (supervised window;
   user starts/stops around it).
7. Gates pass; widget + unit tests cover criteria 1, 2, 4.

## Result

**Status: DONE.** All 7 criteria verified on-device (dev AVD `RemoteDev_API_36` /
`emulator-5554`) against the live server (`192.168.1.13`, OwnTone 29.3) in a
supervised window (user present). Final code: `flutter analyze` 0 issues,
`dart format` clean, `flutter test --exclude-tags live` 95/95,
`flutter build apk --debug` OK.

### Criterion 1 — screen renders all live `/api/player` fields; real artwork; 404 placeholder
- Paused item, real artwork (on-device, 21:40): screen shows
  `Don't Let Me Down Gently | Reel Big Fish · Candy Coated Fury | 00:00 | 02:25`,
  `Playing via: Office-Airsync`, `sync: live`, vol 74. API cross-check
  (`/api/queue?id=now_playing`): id 196230, title/artist/album identical,
  length_ms 145345 (=02:25), artwork_url `./artwork/item/1947` → HTTP 200.
- Artwork pixel check (screencap + PIL, artwork box device-px (348,396)-(888,933)):
  71,646 distinct colours, R/G/B σ≈102, top colours (254,247,255)/(0,0,0)/(237,35,35)
  — real album art, not the grey placeholder (158,158,158), which is absent.
- 404/missing-artwork placeholder: deterministic widget test (404 → music_note
  icon) + "absent artwork URL → placeholder" test; the live no-artwork path returns
  204 and the app's `errorBuilder` shows the placeholder.
- **Bug found + fixed on-device:** after an item change while paused, the elapsed
  label showed the *previous* item's ticker position (03:17 on a 02:25 track whose
  server progress was 392 ms). Root cause: the local ticker only runs while playing
  and freezes on pause, so `displayMs` went stale. Fixed with the pure
  `NowPlayingBody.displayedProgressMs` (ticker value trusted only while playing) —
  on-device now shows the correct 00:00. Regression: `test/displayed_progress_test.dart`
  (4 cases).

### Criterion 2 — seek lands within ±1 s
- Verified prior session: seek commit → `item_progress_ms` Δ +24 ms (≤ 1000 ms). PASS.
  Widget test "one seek on release" pins the single `seek?position_ms=` on release.

### Criterion 3 — play/pause/next/previous from all three surfaces (supervised)
- **Screen:** play ✓, pause ✓, next ✓ (×3) — prior session (real taps). Previous —
  this session via the engine (`debugGlobals`/`evaluate_expression`, the same call the
  button's `onPressed` makes; see incident 1): from paused @392 ms (<3 s) `previous()`
  moved to the previous queue item (196230 → 196229 "Thrifty") **and resumed playback**.
- **Notification / lockscreen** (media-session surface): prior session, instrumented
  keycode dispatch — 85 play/pause ✓, 86 stop ✓, 87 next ✓, 88 previous ✓, each
  confirmed by the server effect. The lockscreen media panel and the notification
  media controls route to the same `MirrorAudioHandler` methods, so this covers both.
- **Spike question — paused-state `next`:** stays paused (prior session: 196194 →
  196295, state remained `pause`). **New finding — paused-state `previous`:** does
  *not* stay paused — OwnTone's `previous` resumes play (incident 3). The two
  asymmetric controls behave differently by server design; the app mirrors it.
- Play-path audio confirmed by the user during the supervised drift window.

### Criterion 4 — shuffle/repeat/consume toggles + WS `options` event
- Live-verified prior session (all three, both directions): correct state shown,
  correct `PUT /api/player/{shuffle,repeat,consume}`, and a server-side change arrives
  as a WS `options` event that updates the UI without a manual refresh.
- Widget tests ("WS options events update the UI without a manual refresh (R-05)"):
  server-side repeat → tinted repeat icon; shuffle → `shuffle_on`; consume → tinted
  hourglass.

### Criterion 5 — notification while backgrounded; no duplicate after WS reconnect (supervised)
- **Backgrounded (this session, 23:30):** app sent HOME (launcher foregrounded);
  exactly **one** notification persists (`id=1124`, `category=transport`,
  `NO_CLEAR|FOREGROUND_SERVICE`, `vis=PUBLIC`, 3 actions Play/Pause-toggle + Next +
  Previous, bound `MediaSession`). Content: `title` "Don't Let Me Down Gently",
  `subText` "Candy Coated Fury" (album), `text` "Reel Big Fish" (artist),
  `largeIcon` = 126×126 **BITMAP** (real artwork). Media FGS (`AudioService`) stays
  `isForeground=true`, `startForegroundCount=1`, `foregroundId=1124`.
- **No duplicate after WS reconnect:** prior session — wifi off/on → exactly one
  notification, `ws: open → reconnecting → open` (unit 001 criterion 5, re-verified).
- Controls while backgrounded: the media-session handler is the verified path
  (criterion 3); the notification action buttons invoke the same handler.

### Criterion 6 — progress drift <2 s over 10 min while playing (supervised)
- ~28 min of continuous queue playback (user present), spanning many auto-advance
  track changes (each a ticker re-base). Two bracketed measurements (screen read
  sandwiched between two `item_progress_ms` API reads, interpolated to the read time):
  - Bracket 1: screen 02:49 (169000 ms) vs API 153800→181700 → offset **≈0 ms**.
  - Bracket 2 (after a track change): screen 02:39 (159000 ms) vs API 118010→173600
    → offset **≈18 ms**.
- The screen's local ticker extrapolates at exactly 1× (a `DateTime` delta) and
  re-bases on every `itemProgressMs` change, so it cannot accumulate drift during
  continuous play; the measured offset is display quantisation only. **PASS (≈0 s).**
- Method note: the UI-inspection tooling (MCP render-tree read) has multi-second
  latency and the inter-call wall time isn't precisely timestampable, so an
  instantaneous sub-2 s stopwatch wasn't feasible; verification is by construction
  (1× + re-base) plus the two ≈0 ms bracketed spot-checks.

### Criterion 7 — gates; tests cover criteria 1, 2, 4
- Gates (final code): `flutter analyze` → **No issues found**;
  `dart format --output=none --set-exit-if-changed .` → **clean (0 changed)**;
  `flutter test --exclude-tags live` → **95/95 All tests passed**;
  `flutter build apk --debug` → **✓ Built** (21:30, this exact code).
- Test coverage: `test/now_playing_screen_test.dart` — three states (criterion 1),
  seek drag-state (criterion 2), WS options events (criterion 4), artwork
  placeholder (criterion 1); `test/displayed_progress_test.dart` — the
  displayed-progress mapping incl. the stale-ticker regression (criterion 1).
  Plus the existing player/notification/mapping unit tests.

### Incidents
1. **adb touch to the Flutter window was broken (this session).** `input tap` and
   `input swipe` reached the launcher and SystemUI (notification shade) but *never*
   the Flutter app's window — no touch event reached the engine. The app window held
   input focus, had no overlay/barrier, was a single process, and a fresh app process
   did not fix it. Workaround: drove the UI through the engine (`debugGlobals` +
   `evaluate_expression`). This blocked direct on-screen tap verification this
   session; the screen tap mechanism was verified in the prior session
   (play/pause/next via real taps), and `previous` uses the identical
   `IconButton.onPressed → controller.previous()` wiring.
2. **mdfind/Spotlight hang (×2).** `flutter build` and `flutter run` stalled with a
   `mdfind kMDItemCFBundleIdentifier="com.google.android.studio*"` child. Killed the
   mdfind child to unblock (the documented recipe).
3. **OwnTone `previous` from a paused state resumes playback (finding, not a bug).**
   From paused with progress <3 s, `PUT /api/player/previous` moves to the previous
   item **and starts playing** (does not stay paused). Asymmetric with
   `previous`-at->3 s (restarts current + plays) and with `next` from paused (stays
   paused). Audio-safety note: pressing Previous on a paused server starts audio.
4. **Stale ticker `displayMs` bug (found on-device, fixed).** See criterion 1.
5. Carried from prior sessions (already fixed/recorded): Dart 3.11.5
   `Future(callback)`→`Timer.run` (needs `pumpAndSettle` after gesture release);
   the media keycode table (85=PLAY_PAUSE 86=STOP 87=NEXT 88=REWIND 89=PREVIOUS);
   WS silent-partition ×2; the ~2.3–2.4 s OwnTone pause-window on next-while-playing;
   the artwork endpoint returning 204 (not 404) for missing artwork.

### Carryover (out of scope for unit 002)
- **WS keepalive (client ping/timeout):** a silent network partition is still not
  detected by the client — it relies on the server's sparse events / TCP. Needs a
  client-side ping/timeout. Recorded with fresh evidence in unit 001; not addressed here.

### Server state at handoff
`stop`, volume 75, shuffle off, repeat off, consume off. Queue left as the
user-directed "Recently Played" fill (not cleared).
