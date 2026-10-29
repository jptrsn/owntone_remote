# SESSION LOG

Append-only handoff log. Newest entry last. Every session appends one entry
before finishing (see `docs/PLAN.md` §13).

---

## 2026-10-08 — Planning session (opencode)

**Did:**

- Gathered context: user's Obsidian vault (`spark/flutter-agent-lens-plan.md`
  — the `flutter_agent_lens` MCP tooling is deployed and verified; prior
  `owntone_sync` Flutter project as convention reference), docs-mcp
  (`ai-dlc` methodology, `owntone-server` JSON API reference), working
  directory (ReTune 3.5.23 APK), environment (Flutter 3.41.7, Dart 3.11.5,
  Android SDK images, existing AVDs, the other session's `emulator-5554`).
- Verified the OwnTone server live: `192.168.1.13:3689`, v29.3, websocket
  `:3688`, 10 outputs (8× Chromecast, AirPlay "Office-Airsync" + ALSA
  "Server" selected), `allow_modifying_stored_playlists: false`. Live
  responses recorded in `docs/API.md` § "Verified live".
- Inspected the ReTune APK read-only: 677 files, Holo-era, **pure Java
  (no native libs, single DEX)** — sideloadable on any arm64 AVD.
- Settled all open decisions with the user (D1–D19 in `docs/PLAN.md` §2),
  including: same UX in modern Material; OwnTone-only feature set (all
  iTunes-specific ReTune features dropped, e.g. radio); older AVD (API 33)
  for capture, modern AVD (API 36) for dev/test/QA; no DAAP/DACP — JSON API
  + websocket surface only, preferring the simpler JSON way where ReTune
  does something DAAP-specific; audio-safety rule for unattended operation
  (D16).
- Scaffolded the repo: `AGENTS.md`, `docs/{PLAN,REQUIREMENTS,ARCHITECTURE,API,SESSION-LOG}.md`,
  `docs/retune-capture/CAPTURE-PROTOCOL.md`, `.ai-dlc/` (5 intents, 15 units
  with completion criteria + quality gates), `tools/retune/`.

**State:** planning complete; nothing built; no AVDs created in this session
(per user instruction — build starts in the next session); APK moved to
`tools/retune/`.

**Next session — do this first:**

1. `audio-service-spike` unit 001: create `RemoteDev_API_36`, `flutter
   create`, build the spike. User needed present for the
   `supervised: true` criteria (play/notification-play/call-resume).
2. Optionally in parallel: `retune-ux-capture` unit 001: create
   `Retune_API_33` (download android-33 image), sideload ReTune, then hand
   to the user for pairing with 192.168.1.13.

**Incidents:** none.

---

## 2026-10-09 — Spike build session (opencode)

**Did (so far):**

- Device isolation verified: the other session's `Pixel_9_Pro_API_36`
  started mid-session on `emulator-5556`; this project's
  `RemoteDev_API_36` (created this session, Android 16) occupies
  `emulator-5554`. Tables in AGENTS.md / PLAN.md updated; **serials shift
  whenever other emulators start — always re-verify via the running-AVD
  ini files / `adb devices -l` before any adb work.**
- `flutter create`, android config (minSdk 26 / target 36, cleartext,
  FGS+mediaPlayback perms), spike implemented: dio API client, WS client
  (1→30 s backoff), `PlayerController` (WS → refetch, pause-origin
  tracker), `MirrorAudioHandler` (audio_service mirror, one-shot
  "wake" to force FGS/notification creation while the server is paused),
  Kotlin plugin (TelephonyCallback call state + runtime permissions),
  one now-playing screen.
- Gates green: `flutter analyze` 0 issues, `dart format` clean, 18 unit
  tests pass, `flutter build apk --debug` OK.
- Device verification (unattended parts **complete**, supervised parts
  pending user window):
  - Criterion 1 PASS: real title/artist/artwork on screen (render-tree
    walk: 1 RenderImage, 0 RenderErrorBox; artwork `/artwork/item/1463?maxwidth=600`).
  - Criterion 2: **stop** from app PASS (server pause→stop, UI
    "Stopped", FGS notification stays). Pause half deferred to the
    supervised window — the transport control is a play/pause toggle, so
    a real pause test needs prior playback.
  - Criterion 4 (paused): rocker does **not** change server volume
    while paused — Android routes volume keys only to PLAYING/BUFFERING
    media sessions (`MediaSessionService … session=null`). Play-state
    test → supervised.
  - Criterion 6 (negative half) PASS: simulated call while
    user-paused → app logs ringing/idle, server stays paused, no
    auto-resume (D9 pause-origin correct on device).
  - Criterion 7 PASS (survival): while paused + backgrounded the
    process stays `FGS (fg-service-act)`, notification + media session
    alive; `am force-stop` kills both (notification removed <10 s);
    relaunch restores correct server state in <4 s with WS reconnected.
- **WS root cause found & fixed:** the `notify` subprotocol is
  mandatory in the WS handshake — without it OwnTone accepts the
  connection but the client silently receives **no events**. This is
  why the app's state went stale during the incident (its WS was
  "open" but dead). Fix: `IOWebSocketChannel.connect(uri,
  protocols: ['notify'])`, subscription sent after `channel.ready`;
  regression-tested (`test/ws_client_test.dart`). After the fix the app
  tracks server changes live (measured: volume change → UI update <3 s
  incl. ~1.5 s dump overhead).
- Second audio_service plugin quirk documented: changed
  `RemoteAndroidPlaybackInfo.volume` is not propagated to the media
  session (provider recreated only on control-type/max change) —
  session `current=` goes stale; rocker routing unaffected. See unit
  `## Result` → Findings.

**Incident — unconfirmed playback started (audio-safety violation):**

- ~19:50, while the server was **paused**, I tapped the center transport
  button on the now-playing screen intending it as a no-op "pause" test
  (criterion 2a). In the paused state that button is the app's **play**
  control; the tap sent `PUT /api/player/play` and **"Killing Me Softly"
  (Fugees) started audible playback** on the real outputs.
- Duration: up to ~58 s of audible playback (item_progress_ms 26368 →
  84266 at the moment the user stopped it; the user paused it themselves
  shortly after the tap). I re-verified `state == pause` at 19:53.
- Cause: I misread my own UI — a play-capable control tapped while the
  server is paused IS the supervised action, and it was performed
  without the user's confirmation for that specific action. This
  violated AGENTS.md §1 and the session instructions.
- Correction in effect for the rest of this session: while the server is
  paused, only `stop`, `next`/`previous` (stay paused), toggles, seek and
  volume are unattended-safe. The center transport button and any
  play-capable control (app or notification) are only touched inside a
  supervised window with explicit per-action confirmation. The pause-half
  of criterion 2 will be verified inside the supervised play window
  (criterion 5).

**Incident 2 — extended playback during supervised window (12:16–12:25):**

- Supervised play test started (user present, play confirmed): ~12:16:55,
  track 195993 began playing. The plan was to pause within seconds.
- Pause via the media-button path failed: (a) explicit broadcast
  `android.intent.action.MEDIA_BUTTON` (KEYCODE extra) to
  `MediaButtonReceiver` — no effect; (b) `cmd media_session dispatch
  pause` — no effect (MediaSessionService did not route the key to the
  session). Root cause under investigation; the plugin's notification
  action PendingIntents carry a `KeyEvent` extra, which my adb
  broadcasts did not replicate.
- Meanwhile the OwnTone queue auto-advanced: 195993 (full, 1:54) →
  195995 (full) → 195997, paused at 12:25:30 via `PUT /api/player/pause`
  at 1:42 (item_progress_ms 102016). **~8.5 min of audible playback** —
  well beyond the approved brief. State verified `pause` immediately.
- Lesson: any play step in a supervised window must be bracketed by an
  API pause that is *verified* before moving on; media-button/UI pause
  paths are not a reliable kill switch until proven.

## 2026-10-10 — Supervised window + NO-GO (opencode)

**Did:** ran the user-confirmed supervised window (criteria 3/5/6 +
play-state halves of 2/4), then **declared NO-GO** per the unit's
clause. Full evidence in `.ai-dlc/audio-service-spike/units/001-spike-app.md`
→ `## Result`.

- **Criterion 4 (rocker → server volume): FAIL — the NO-GO trigger.**
  In every configuration (paused/playing × screen on/off, app
  backgrounded) the rocker never changed the server volume; it adjusted
  system STREAM_MUSIC (while playing) or STREAM_RING (otherwise).
  Framework logs prove the app's session was never selected for volume
  keys: `dispatchVolumeKeyEvent … session=null` and
  `dumpsys media_session: Media button session is null` — *even while
  the session was PLAYING*, active, with the media-button receiver and
  a REMOTE `VolumeProviderCompat` in place. This is AOSP
  `MediaSessionService` selection logic, not app-layer code.
- **Criterion 5: PASS (with caveats).** The notification's exact action
  path (dispatched via debug-only `DebugMediaButtonReceiver` — A16 does
  not render this app's transport notification in the shade, and the
  shell can't build a KeyEvent) started real playback
  (`pause → play`, progress advancing 1x, user-confirmed audible; app
  log `HDLR play` 14 ms after the MediaBrowser connect). Next-while-
  paused advanced the item with no audio. Caveat: only the *first*
  media-button action per app process works — later presses stall in
  the plugin's MediaBrowser re-bind (Finding 5).
- **Criterion 2 pause: PASS** (UI center toggle paused a playing
  server; frozen 2.5 s before track end).
- **Criterion 3:** WS mechanism already proven (<3 s incl. dump
  overhead); the literal web-UI form is **BLOCKED** (AVD shut down).
- **Criterion 6:** negative half already PASS; the auto-resume half is
  **BLOCKED** (AVD shut down) — the one unverified call-safety behavior.
- **New findings:** (5) one-shot media-button dispatch per process
  (audio_service 0.18.19 + API 36; affects real notification buttons);
  (6) media session never selected for volume keys (above); (7) A16
  shade hides this transport notification; (8) the AVD GUI failed
  twice (frozen/black screen → clean reboot; then dead sidebar
  controls → user shut it down); (9) OwnTone auto-advance drifts the
  queue during any playback (195997 → 196001 in this window).
- **Environment restored:** `state=pause`, `volume=75` (had drifted to
  28), `consume=false`. Queue position not restored (needs supervised
  queue ops). AVD shut down by user; adbd was left as root on it
  before shutdown (resets on next boot).
- Gates re-verified after removing a temporary log probe: analyze 0,
  format clean, 25/25 tests.

**NO-GO declared:** criterion 4 failed after reasonable effort → per
the unit's GO/NO-GO clause, **stop building on Flutter + audio_service;
stack re-decision is the user's.** Fallback sketch (Kotlin+Media3) is
in the unit file. Hedges before re-deciding: (1) the "media button
session is null" behavior may be emulator-specific — the same debug
APK on the Pixel 10 (not yet connected) is the cheapest decisive
test; (2) Media3 uses the same framework session API, so it is not
guaranteed to fix volume routing, but it removes the one-shot
 media-button bug and the plugin volume-staleness quirk. Criterion 6's
 auto-resume half should be re-tested on whichever device/stack is
 chosen before the call-safety property is trusted.

## 2026-10-10 (late) — Real-device re-test + NO-GO retracted (opencode)

**Did:** user connected a **Pixel 6** (`25071FDF600953`, oriole,
Android 16, no SIM) and requested re-testing there. The NO-GO's
emulator-vs-device hedge is now settled: **the rocker works on the
real device; NO-GO retracted; GO stands; unit 001 done.** Full
evidence in `.ai-dlc/audio-service-spike/units/001-spike-app.md`.

- **Rocker (criterion 4, re-scoped):** on the Pixel 6 the session IS
  selected and volume keys route to the app — the emulator's "Media
  button session is null" is an **emulator artifact** (Finding 11).
  One foreground UP press → exactly one `dir=1` call, 75→80, stable.
  Found + fixed a real app bug: the key-*release* sends
  `AndroidVolumeDirection.same`, which the old code mapped to
  "lower" — every press was +5/−5 with a downward-drift race
  (Finding 10). `same` is now a no-op.
- **Criterion 4 re-scoped by the user:** the backgrounded+screen-off
  rocker form is dropped — "if the app is in the background, volume
  control should work without interference." Verified: 3-min
  backgrounded+locked watch, zero server-volume drift.
- **Criterion 3: PASS (literal web-UI form)** on the Pixel 6 — user
  dragged the volume slider in the OwnTone web UI under a lockstep
  monitor; every value (83→21→3→27→69→100→100→17) reached the app UI
  in the same ~3.2 s cycle, one cycle caught mid-drag values on both
  sides (sub-second WS push). Also: a web-UI change while the device
  was dozing still propagated.
- **Criterion 6: PASS (both halves, app backgrounded)** on the
  rebooted `RemoteDev_API_36`: guest `IDLE→INCOMING` 21:13:04.526 →
  app `call state: ringing` .652 → server paused t+4 s; `gsm cancel
  5551234567` → guest `INCOMING→DISCONNECTED` .540 → app `idle` .590 →
  server playing t+6 s. (Bare `gsm cancel` is a console error — the
  number is required.)
- **Emulator hung headless** ~20:47 (call registered, ringer never
  started, no `ringing` event reached the app; app engine later
  stalled at boot) → user suggested reboot; windowed re-boot fixed
  everything (Finding 12). During that window the user observed
  **Apple Music opening on the Mac host** when the ringing "ended";
  nothing in the test script targets the host — unexplained, not
  reproduced, logged once here.
- **Unexplained 80→100 server-volume jump** on the Pixel 6
  (~19:10, app backgrounded, user reports no key presses): not
  reproduced (3-min zero-drift watch), no system-side volume events
  in the window, app buffer rotated. Leading candidate: a
  server-side change (web-UI tab). Finding 13.
- **Queue ran empty** mid-window (playlist finished, `state: stop`,
  `item_id: 0`); user asked for a re-enqueue → "Recently Played"
  (id 19, 168 tracks, no auto-start).
- docs-mcp: `audio_service` 0.18.19 index had only changelogs →
  re-scraped `pub.dev/documentation/audio_service/0.18.19/` (API
  reference now searchable; confirmed `same` semantics). Also indexed
  `android-emulator` console docs (source of the `gsm cancel <num>`
  syntax).
- **Environment restored:** `state=pause`, `volume=75`,
  `consume=false`. Pixel 6: app installed, permissions granted,
  `screen_off_timeout` restored to 1800000. `RemoteDev_API_36` left
  running (windowed, `emulator-5554`). Probes removed from
  `mirror_handler.dart`; gates green (analyze 0 / format clean /
  25/25 / build OK).
- **GO/NO-GO: NO-GO retracted — GO for Flutter + audio_service.**
  The NO-GO's root-cause claim ("AOSP session selection never picks
  our session") was an emulator artifact. Open items for
  `remote-app`: Finding 5 (one-shot media-button dispatch — untested
  on the real device), 14 (slider drag-state design), 13 (volume-jump
  monitor). Volume-key routing checks must run on a real device.
- **Next session:** start `.ai-dlc/remote-app` (intent `planned` →
  first unit 001 connection-settings, R-01/R-02; 6 units total).
  Build on the spike codebase per the intent: keep
  provider/client/handler/call-channel, delete the hardcoding. Spike
  intent + unit 001 are both `done`; its `## Result` is the reference
  for every audio/volume/call assumption (findings 1–14).

## 2026-10-11 — remote-app unit 001 done (opencode)

- **Unit 001 (connection-settings, R-01/R-02) is `done`** — all 8
  criteria (7 original + 1 added mid-unit) verified with evidence in
  the unit's `## Result`. New code: `ServerConfig`, typed
  `ConnectionError` (DNS/refused/timeout/401), `SettingsStore`
  (shared_preferences), `ConnectionController` (idle|connecting|
  connected|offline|error + WsPhase, REST probe per reconnect
  attempt, full refetch on every open after the first),
  `OutputsController`, app-wide `ConnectionBanner`, settings +
  now-playing + error screens, audio init on first connect, mirror
  wake guard.
- **User requirement added mid-unit (recorded in R-03 + unit
  criterion 8):** now-playing must not overflow the viewport — the
  artwork shrinks (1:1 preserved) so all controls are visible
  without scrolling. Implemented as `Column` +
  `Expanded(Center(ArtworkBox))` (AspectRatio takes
  `min(availW, availH)`); widget-tested at three surface sizes and
  verified on-device (volume row y≤1857 on a 1920-tall screen).
- **Device verification on `RemoteDev_API_36` (emulator-5554):**
  relaunch auto-connect; typed errors captured verbatim on-device by
  prefs-surgery relaunch (`FlutterSharedPreferences.xml` edited with
  adb root — `input text` is unreliable here, see findings); WS
  volume propagation <2 s both ways; **supervised OwnTone
  disable/re-enable (user)** — app went offline (banner, witnessed
  by the user), backoff-reconnected in <1 s of server return,
  post-reconnect state matched the server exactly (stop, 75,
  Office-Airsync).
- **Key finding — no WS keepalive:** a silent network partition
  (route removed, socket not torn down) is *not* detected; the app
  stays `sync: live`. Socket-teardown drops are detected. Needs a
  client ping/no-activity timeout → force reconnect. Candidate for
  unit 002 hardening.
- **SDK/harness quirks documented in the unit Result** (Dart
  3.11.5: SocketException prints the *local* port, no
  `InternetAddress.port`; uiautomator single-quotes content-desc
  containing `"`; `flutter run` auto-restarts the app on
  force-stop; MinuteMaid gms dialogs steal focus and can kill the
  Flutter a11y bridge; `adb input text` needs the IME hidden).
- **Gates green:** analyze 0 / format clean / 60/60 unit+widget /
  4/4 live / `flutter build apk --debug` OK.
- **Environment:** server left at `state=stop, volume=75` (the
  supervised restart returned it to stop; queue was cleared by the
  server itself — no library data touched). No playback occurred at
  any point. Dev AVD still running windowed (emulator-5554);
  `flutter run` session ended.
- **Next:** `.ai-dlc/remote-app` unit 002 (now-playing: screen +
  notification hardening, R-03/R-04/R-05/R-07) — before building it,
  read spike finding 14 (slider drag-state design) **and** unit
  001's no-keepalive finding (WS partition detection). Unit 003
   (volume-rocker + call-handling) will additionally need spike
   findings 5, 10, 11 (one-shot media-button dispatch; volume-key
   release = `same` no-op; volume-key routing needs the real Pixel 6
   `25071FDF600953`).

---

## 2026-10-13 — remote-app unit 002 done (opencode)

Session ran 2026-10-12 19:56 → 2026-10-13 00:42 (crossed midnight).
Supervised window open, user present.

**Did:** Finished unit 002 (now-playing screen + notification
hardening, R-03/R-04/R-05/R-07). Completed the drag-state slider
tests, optimistic-update + rollback, and the notification-mapping /
controller-actions / screen / live test files (prior session), then
root-caused and fixed the 5 failing widget tests (Dart 3.11.5
`Future(callback)`→`Timer.run` needs `pumpAndSettle` after gesture
release). All gates green. Did the on-device verification: criterion
1 (paused item + real artwork, pixel-verified), criterion 3
(screen previous via engine; notification/lockscreen media-session
surface from prior session), criterion 5 (backgrounded notification,
exactly one, metadata + 126×126 artwork + 3 controls + FGS alive),
criterion 6 (~28 min supervised play, two bracketed drift samples
≈0 ms). Wrote the unit `## Result` (all 7 criteria + incidents).

**Bug found + fixed on-device (criterion 1):** after an item change
while paused, the elapsed label showed the *previous* item's ticker
position (03:17 on a 02:25 track, server progress 392 ms). Root cause:
the screen's local ticker only runs while playing and freezes on pause,
so `displayMs` went stale. Fixed with a pure
`NowPlayingBody.displayedProgressMs` (ticker value trusted only while
playing) + `test/displayed_progress_test.dart` (4 cases). On-device now
shows the correct 00:00.

**Key findings:**
- **OwnTone `previous` from a paused state resumes playback.** From
  paused with progress <3 s, `PUT /api/player/previous` moves to the
  previous item **and starts playing** (does not stay paused).
  Asymmetric with `next` from paused (stays paused — the unit-002
  spike question, now answered) and with `previous`-at->3 s (restarts
  current + plays). Audio-safety note: pressing Previous on a paused
  server starts audio. The app mirrors this faithfully.
- **adb touch to the Flutter window was broken this session.**
  `input tap`/`input swipe` reached the launcher and SystemUI
  (notification shade) but never the Flutter app's window (no touch
  event reached the engine; window had input focus, no overlay, single
  process; a fresh app process didn't fix it). Worked around by
  driving the UI through the engine (`debugGlobals` +
  `evaluate_expression`). Blocked direct on-screen tap verification;
  the screen tap mechanism was already verified in the prior session
  (play/pause/next via real taps) and `previous` uses the identical
  `onPressed → controller.previous()` wiring.
- **mdfind/Spotlight hang (×2):** `flutter build`/`flutter run` stalled
  on a `mdfind kMDItemCFBundleIdentifier="com.google.android.studio*"`
  child; killed the mdfind child to unblock (documented recipe).

**Drift (criterion 6):** ~28 min continuous queue playback with many
auto-advance rebases; two bracketed screen-vs-API measurements
(screen read sandwiched between two `item_progress_ms` reads,
interpolated) → offset ≈0 ms and ≈18 ms (across a track change). The
ticker is 1× by construction and re-bases on every `itemProgressMs`
change, so it cannot accumulate drift during continuous play. PASS
(<2 s). Method caveat: the MCP render-tree read has multi-second
latency and inter-call wall time isn't precisely timestampable, so an
instantaneous sub-2 s stopwatch wasn't feasible — verification is by
construction + the ≈0 ms spot-checks.

**Gates green (final code):** analyze 0 / format clean /
`flutter test --exclude-tags live` 95/95 / `flutter build apk --debug`
OK (21:30). TEMP `MEDIA-CMD` instrumentation removed before the build;
`DebugMediaButtonReceiver.kt` keeps the corrected keycode doc comment
+ a debug keycode log line (intentional, debug-only component).

**Environment:** server restored to `stop`, volume 75, shuffle off,
repeat off, consume off. Queue left as the user-directed "Recently
Played" fill (not cleared). No library data touched. Audio only played
during the supervised window (user present); paused/stopped before any
unattended work. Dev AVD `emulator-5554` to be killed. `flutter run`
session ended.

**Carryover (out of unit 002 scope):** WS keepalive — a silent network
partition is still not detected by the client (relies on the server's
sparse events / TCP); needs a client ping/no-activity timeout. Unit 001
recorded it with fresh evidence; not addressed here.

**Next:** `.ai-dlc/remote-app` unit 003 (volume-rocker +
call-handling) — read spike findings 5, 10, 11 (one-shot media-button
dispatch; volume-key release = `same` no-op; volume-key routing needs
the real Pixel 6 `25071FDF600953`).

---

## 2026-10-13 (late) — remote-app unit 003 in progress (opencode, orchestrator)

Session scope: unit 003 (volume rocker + call handling, R-06/R-08).
User constraints: Pixel 6 `25071FDF600953` in use by another session —
no adb against it until granted; supervised window "later today".
Orchestrated: design + controller wiring kept in the main session; the
state machine + all 36 new tests delegated to sub-agents against exact
contracts and reviewed line-by-line (one self-inflicted compile error
fixed in review — see below).

**Did:**

- **New 500 ms flap filter + pause-in-flight tracking (the unit's edge
  cases).** The spike's pause-on-ringing had two races: a short
  ringing→idle flap would pause for nothing; a call ending before the
  pause acked left origin `call` lingering (a later call would
  auto-resume a stale pause). New pure, synchronous
  `CallPauseTracker` (`lib/src/player/call_pause.dart`, composes the
  unchanged `PauseOriginTracker`): flap filter (controller owns the real
  `Timer`, machine is timer-free → unit-testable without FakeAsync),
  `pauseInFlight`, `resumeAfterAck` (ended-before-ack → resume when the
  ack lands, origin cleared). OFFHOOK (`active`) confirms immediately,
  even without a preceding RINGING; `main.dart` now routes `active`
  (was ignored). Rocker mapping extracted to pure `rockerStepFor`
  (`same` no-op per Finding 10, now test-pinned); `rockerStep = 5`
  hardcoded + TODO(R-14) (P2, out of scope).
- **36 new tests, all green** (131/131 total): 15
  `call_pause_tracker_test` (flap, call-while-paused, stop,
  ended-before-ack ×2, failed pause ×2, claim conflicts, double idle),
  8 `player_controller_call_test` (controller integration vs.
  `StatefulServer`, real-time flap timer; incl. a 900 ms-slow-pause
  adapter proving "no resume before the ack"), 4 `rocker_step_test`,
  9 `call_state_channel_test` (mock MethodChannel mapping +
  permissions round-trip).
- **Gates green on final code:** analyze 0 / format clean (42 files) /
  131/131 / `flutter build apk --debug` OK.
- **On-device (dev AVD `emulator-5554`, server `stop` throughout —
  safe):** adb touch works again this session (unit-002 symptom did not
  recur). C2 slider half: real slider drag → server 75→62 (state
  stayed stopped); server-side `?volume=80` → app slider `80%` within
  the next dump (WS push); restored 75. Call-safety no-op: `gsm call`
  → app `ringing` (05:10:47.740) → confirmed (3.8 s > 500 ms) → server
  stopped so no pause → `gsm cancel` → app `idle` (05:10:51.522) →
  server byte-identical (`stop,75,196174`). Permissions persisted from
  the spike.
- **Unit `## Result` written** (evidence above + exact procedures for
  the blocked criteria). Frontmatter `in_progress`; **no commit** (unit
  not done).

**Blocked (user-gated):**

- **C1** — volume-key routing: BLOCKED-PENDING-DEVICE. Pixel 6 belongs
  to another session; the AVD provably never routes volume keys to the
  session (Finding 11). Procedure in the unit Result, incl. the routing
  caveat: while the server is stopped/paused stock Android may not
  route keys to the session at all (Finding 4) — fallback is the
  user-re-scoped form (supervised play) + non-interference watch.
- **C3/C4** — call pause/auto-resume + user-pause no-resume:
  BLOCKED-PENDING-SUPERVISION (user: "later today"). Procedures in the
  unit Result (windowed AVD, `gsm call`, pause + verify after every
  step). Note: with the new debounce the auto-pause lands ~500 ms after
  ringing (spike: ~4 s).

**Incidents:** mdfind/Spotlight hang (3rd) killed the build once —
killed the `mdfind kMDItemCFBundleIdentifier="com.google.android.studio*"`
child, build completed. Self-inflicted: `rockerStepFor` first written
as a switch expression over `AndroidVolumeDirection` values —
audio_service 0.18.19 defines that type as a class with `static final`
instances, not an enum → `constant_pattern_with_non_constant_expression`
→ rewrote with `==` checks (cost one build cycle).

**Environment at handoff:** server `stop, volume=75, item_id=196174`
(queue untouched). `RemoteDev_API_36` left **running, windowed**
(emulator-5554), app installed + connected — ready for the supervised
window. Pixel 6 untouched. No playback occurred.

**Next (to close unit 003 — one window + one device grant):**

1. Supervised window (user present): C4 first (play → user pause →
   call → still paused), then C3 (play → call → auto-pause → call ends
   → auto-resume → immediate pause), per the unit Result procedures;
   pause + verify after every step; restore `stop`, `volume=75`.
2. Pixel 6 grant: C1 — install this APK, rocker up/down with server
   stopped → `GET /api/player` before/after, timestamped; if the system
   doesn't route keys to the stopped session, run the re-scoped form
   (supervised play) + document the routing limitation.
3. Paste the C1/C3/C4 transcripts into the unit `## Result`, flip the
   blocked sections to PASS, re-run the 4 gates, append this log, set
   frontmatter `status: done`, commit `remote-app/003: <why>`, kill the
   dev AVD.

## 2026-10-22 — Supervised window: C3/C4 PASS; C1 blocked by Pixel 6 device network (opencode)

Session scope: close out unit 003's two user-gated criteria. The user
granted the Pixel 6 (lock screen removed per their instruction:
`settings put secure lockscreen_disabled 1`) and gave a supervised
playback window "now".

**Did:**

- **C4 PASS, then C3 PASS** on `RemoteDev_API_36` (emulator-5554,
  windowed, app under `flutter run`, `phase=connected, ws=open`).
  One window, C4 first per the unit order; `GET /api/player` verified
  after every step. C4: play 12:53:41 → user pause 12:54:02 → `gsm
  call` 12:54:20 (app `ringing`) → still paused 12:54:23 → `gsm
  cancel` 12:55:06 after **46 s of ringing** (unambiguously past the
  500 ms flap window) → **still paused** 12:55:09. C3: play 12:56:09 →
  `gsm call` 12:56:25 → **auto-pause** 12:56:29 → `gsm cancel`
  12:56:47 → **auto-resume** (`state: play`) 12:56:50 → immediate
  `player.pause()` 12:57:00.9 → verified 12:57:10. Restore: `stop`
  12:57:23, verified **byte-identical** to the pre-window baseline
  (`stop, volume=36, item_id=196174`) 12:57:33. Full transcripts in
  the unit `## Result`.
- **Gates re-verified on final code** after removing a temporary
  `debugProbe` diagnostic added to `main.dart` during the C1
  investigation (and its `dart:io`/`dio` imports): analyze 0 / format
  42 files 0 changed / 131/131 / (build not re-run — the Oct 13 debug
  APK is byte-current for this code).
- **C1 blocked — the Pixel 6 cannot carry app traffic.** The device is
  on the LAN (Wi-Fi "Glyphyx", 192.168.1.148, ping 0% loss; `adb
  shell nc 192.168.1.13 3689` connects), but every TCP connection from
  *inside the app* to any non-loopback destination (server 3689, a
  controlled HTTP server on the Mac, 8.8.8.8:53) times out (errno 110)
  with **no kernel socket ever created** (watched
  `/proc/<pid>/net/tcp{,6}` at ~0.4 s through the whole window), while
  loopback works. A clean reinstall (new uid 10310) fails identically;
  GMS holds established internet connections; AppOps/VPN/proxy/SELinux
  all clean; `device_provisioned=1`. The device went through the
  **setup wizard today ~09:24** (fresh reset, user's Google account
  provisioned) — root-cause needs root or the user/other-session device
  history. Also flaky: SystemUI wedged (notification shade persistently
  open, stealing focus, empty `uiautomator` dumps) + USB dropouts; a
  Chrome cross-check could not be completed. Findings in the unit's
  Criterion 1 section.
- **AVD incident:** guest→LAN hung completely (ping hangs) while
  Mac↔server stayed fine — survived an emulator restart, so the wedge
  was in the **shared `netsimd`** (started the same second as the other
  session's emulator at ~10:28). `emu kill` clogged the adb server;
  `adb kill-server`/`start-server` recovered it (Pixel 6 + the other
  session's `emulator-5556` reattached). Post-restart, guest→LAN worked
  immediately. If the AVD loses its LAN again: suspect the shared
  netsimd first.

**Environment at handoff:** server `stop, volume=36, item_id=196174`
(byte-identical to pre-window). Dev AVD killed. Pixel 6: lock screen
off, debug APK installed, config saved (`192.168.1.13:3689`),
POST_NOTIFICATIONS + READ_PHONE_STATE granted — ready for C1 the
moment its third-party-app network works. Other session's emulator
running untouched. No playback after 12:57:33; total supervised-play
exposure ≈ 16 s across both criteria.

**Update 17:15 (same day):** the user unplugged/re-plugged the Pixel 6
and its app egress worked immediately (the 17:02 mis-typed-port attempt
got a clean `refused`). Mid-test the user **rescoped the rocker
contract (D20):** server-volume mapping only while the app is
foregrounded; backgrounded, phone volume keys do their normal thing and
the app must never touch the server volume — including while the server
plays. Docs updated (REQUIREMENTS R-06, PLAN S4 + D20, unit criterion 1
+ Result). On the Pixel 6, server stopped: **foreground rocker
36→41→36 PASS** (17:14–17:15); **backgrounded rocker left the server
at 36** (17:08). Open item: the current handler would still send
`PUT volume` backgrounded while the server is `play` (the session is
selected then) — needs a foreground guard + unit tests, then the
supervised backgrounded-`play` non-interference test on the device,
re-run the 4 gates, set frontmatter `status: done`, commit
`remote-app/003: <why>`. Then unit 004 (outputs/speakers).

## 2026-10-22 (evening) — remote-app unit 003 DONE (opencode)

The D20 open item is closed; **all six criteria PASS, unit 003 is done
and committed.**

- **D20 foreground guard** (`mirror_handler.dart` + `main.dart`): the
  handler's rocker/`setRemoteVolume` overrides no-op while the app is
  not foregrounded, and the session publishes
  `AndroidVolumeControlType.absolute` (foreground) / `fixed`
  (backgrounded) via the pure `volumeControlTypeFor`. `main.dart`
  forwards `didChangeAppLifecycleState` (resumed ⇔ foregrounded) through
  a `WidgetsBindingObserver`, seeding the flag at handler creation.
  `test/rocker_foreground_test.dart` (9) pins both layers.
- **C1 on the Pixel 6, final build (supervised, user present):**
  backgrounded + screen-off with the server **`play`** — rocker up
  *and* down left server volume at 36; foregrounded rocker 36→41;
  paused immediately; restored `stop, volume=36, item_id=196174`
  (byte-identical). Transcripts in the unit's Criterion 1 section.
- **Gates (final code):** analyze 0 / format 43 files 0 changed /
  140/140 / `flutter build apk --debug` ✓.

**Environment at handoff:** server `stop, volume=36, item_id=196174`
(byte-identical to the pre-window baseline). Pixel 6: final debug build
running under `flutter run`, connected, config + permissions persisted.
Dev AVD `RemoteDev_API_36` killed. Other session's emulator
(`emulator-5556`) untouched. Next: **unit 004 (outputs/speakers)**.

## 2026-10-22 (night) — remote-app unit 004 in progress: safe criteria done, C3 pending supervision (opencode)

Session scope: unit 004 (outputs/speakers, R-09). User stepped away for
the night after a clarification round (decisions: no commit while the
unit is in_progress; write the Outputs section into SCREENS.md; add an
in-app confirmation before output changes while the server plays;
pre-approved temp dir instead of /tmp). Server baseline verified first:
`stop, volume=36, item_id=196174`; live output set = 10 outputs with
**Volumio Kitchen (AirPlay 1) selected only** — the user had unplugged
the office AirPlay output that day, so the unit's remembered set was
stale (live `GET /api/outputs` treated as authoritative; restored
byte-identical after every change).

**Environment discovery (serials shifted again):** `emulator-5554` is
now the **other session's** `Pixel_9_Pro_API_36` (verified via
`ro.boot.qemu.avd_name` + an active `flutter run` there — hands off).
`RemoteDev_API_36` booted headless onto `emulator-5556` (verified by
avd_name). AGENTS.md device table updated (both serials + a note that
`getprop ro.boot.qemu.avd_name` is the re-verification method).

**Did:**

- **Code:** `OwntoneApi` gained `setOutputs` (one `PUT /api/outputs/set`,
  JSON body = full id list), `setOutput` (`PUT /api/outputs/{id}` —
  selected/pin/volume; the PIN path), `setOutputVolume`
  (`PUT /api/player/volume?volume=N&output_id=`). `OutputsController`:
  pure `selectedIdsAfterToggle` (server order), `toggle` /
  `enableWithPin` / `setOutputVolume` with the unit-002 contract
  (optimistic → confirming refetch → rollback + typed
  `actionError`/`actionErrorSeq`), `syncError`, no-op while
  disconnected. `OutputsScreen` (new): checkbox row (name · type
  string as-is · lock marker · volume label · commit-on-release
  per-output slider, drag-state per Finding 14), compound semantics
  labels, empty/loading/offline/sync-error states, snackbar on failure,
  **playing-guard dialog** before any selection change while the server
  is `play` (user decision). Entry point = the now-playing "Playing
  via: …" line made tappable (cast icon; "none" when nothing selected)
  — a third app-bar icon overflowed the 360-logical viewport by 9 px,
  so the app bar stays as unit 001/002 specified it. SCREENS.md gained
  the Outputs section.
- **Tests 140 → 174, all green** (+34): set math (6), controller
  one-PUT/rollback/PIN-4xx/volume/WS-refetch (13), API wire format (6),
  screen rendering/PIN/guard/offline/empty (8). One real bug caught by
  the PIN widget test: the Unlock button's enabled state was
  build-time-only (typing never re-enabled it) — fixed with
  `onChanged → setState` (+ `onSubmitted`).
- **Gates (final code):** analyze 0 / format 48 files 0 changed /
  174/174 / `flutter build apk --debug` ✓.
- **On-device (dev AVD `emulator-5556`, app under `flutter run`, server
  `stop` throughout):**
  - **C1 PASS** — Outputs screen rows (uiautomator semantics, list
    scrolled across two dumps) vs same-moment `GET /api/outputs`:
    10/10, all fields, server order (`True` in the programmatic
    diff; transcript in the unit Result).
  - **C2 PASS** — mock OwnTone on the Mac (`192.168.1.85:3690`,
    pure `dart:io`, logs method+path+body; app pointed at it via the
    persisted-config file — run-as edit + relaunch, since adb
    `input text` mangled the host field; config restored to
    `192.168.1.13:3689` after, reconnect verified). Capture: one
    `PUT /api/outputs/set body={"outputs":["m1","m2"]}` per toggle,
    no per-output selection PUTs; armed-500 → checkbox rolled back +
    snackbar `Outputs failed — server answered HTTP 500.`; un-armed
    retry → selected. Bonus stray tap proved the per-output volume
    endpoint shape on-device.
  - **C4 PASS** — Bathroom display volume 50 → 64 → 50 via the
    row slider (server `stop`); each commit verified by
    `GET /api/outputs`; final outputs JSON **byte-identical** to the
    pre-test baseline.
  - **Empty-set probe (unit step note)** — `PUT /api/outputs/set
    {"outputs": []}` → 204, **all outputs deselected** (app reflected
    it live via WS); restored with the single-id set → byte-identical.
  - **C5** — PASS via the fake-output widget/controller tests (PIN
    dialog, selected+pin body, 4xx stays disabled). Live gap: no
    protected outputs on this server.
- **C3 BLOCKED-PENDING-SUPERVISION** — user absent; never played.
  Procedure written into the unit Result (guard dialog = the
  in-product confirmation; play→toggle→verify→toggle-back→pause→stop;
  final `/api/outputs` must be byte-identical; paste transcript,
  re-run gates, flip frontmatter `done`, commit `remote-app/004: <why>`).

**Incident addendum (late night):** a transient adb blip killed the
first `flutter run` ("Lost connection to device") while the app process
survived; a second `flutter run` re-attached cleanly (app auto-
connected, `sync: live`, `Playing via: Volumio Kitchen` — verified).
Also: one full-suite re-run showed a single flaky failure
(+152 -1, name not captured); two subsequent full runs were 174/174
green. The gate command is green; the flake is noted for the C3 window
(re-run the gate; if it recurs, name it and fix it before the commit).

**Environment at handoff:** server `stop, volume=36, item_id=196174`,
`/api/outputs` byte-identical to the session baseline. Dev AVD
`emulator-5556` **left running (headless)** with the app under
`flutter run` (second launch after the adb blip) connected to the real
server — ready for the C3 window. Mock server killed. Other session's
emulator (`emulator-5554`) and the Pixel 6 untouched. **No commit**
(unit in_progress — user decision).

**Next (C3 window, user present):** run the unit-Result procedure
(play → guarded toggle → audio-follow check → restore → pause/stop →
byte-identical verify), transcript into the unit Result, re-run the 4
gates, set frontmatter `status: done`, append this log, commit
`remote-app/004: <why>`. Then unit 005 (browse + queue + play).

## 2026-10-23 (morning) — remote-app unit 004 DONE: C3 supervised PASS, guard hardening (opencode)

**Unit 004 (outputs/speakers, R-09) is done — all six criteria PASS.**
C3 (the supervised audio move) ran with the user present this morning.

**User decisions this window:**
- **Restrict remote-output testing to Volumio Kitchen only.** All
  Chromecast-type remote outputs **fail server-side when selected**
  (user observation; confirmed live — a toggle to Kitchen display never
  flipped `selected`). So the A→B second output was the local
  **`Server` (ALSA)** output, per user instruction. (Note for later
  units: Volumio Kitchen + Server are the two reliable outputs.)
- The in-app **playing-guard dialog** is the in-product confirmation
  (user decision 2026-10-22, carried into C3).

**C3 PASS** — transcript in the unit Result. Summary:
- 09:27:10 app play → `state: play` (audio on Volumio Kitchen).
- 09:28:20 enable `Server` → guard dialog (`state=play`) → Continue →
  `selected: [Volumio Kitchen, Server]`; user heard audio on both.
- 09:53:18 disable Volumio Kitchen → dialog → Continue →
  `selected: [Server]`; **user: "Server output only — move worked"**
  (the A→B core evidence).
- 10:07–10:15 re-enable Volumio, disable Server (both dialog-guarded)
  → `selected: [Volumio Kitchen]`; user: "Volumio Kitchen only —
  original state".
- 10:19:45 app pause → `pause`; 10:22:35 app stop →
  `stop, volume=36, item=196174`.
- Final `GET /api/outputs` **byte-identical** to the pre-test baseline.

**Guard anomaly found + fixed during C3.** The first two guard taps on
the long-lived instance skipped the dialog — the guard read a **stale
non-playing cached player state** while the server was playing. A fresh
instance behaved correctly, isolating it to the cached-slice read. Fix:
the guard now calls a new `PlayerController.refreshState()` (one-shot
refetch, cache fallback only when the refetch is impossible) before
deciding. Regression test `outputs_screen_test.dart` "stale cache (…):
refetch forces the dialog" drives the fixture to `play` with no WS
event (cache stays `pause`) and asserts the dialog appears — **verified
to fail without the fix** (reverted → red; restored → green).

**Incidents (all resolved, server left `stop`):**
- **Incidental playback ~40 s**: a restore-step tap hit the play arrow
  and resumed Volumio Kitchen for ~40 s before I paused via the API and
  verified `pause`. User present; recorded per the accidental-playback
  rule.
- **OwnTone volume-sync side-effect**: deselecting Volumio Kitchen made
  the server rewrite its stored per-output volume `36 → 8` (the ALSA
  value). Server behaviour, not an app bug (app sent only
  `/outputs/set` in the C3 window). Restored to 36 via a direct
  `PUT /api/player/volume?…&output_id=` for the byte-identical final.

**Gates re-run green on final code** (after C3 + guard fix):
`analyze` 0 · `format` 0 changed · `flutter test --exclude-tags live`
**+175** (140→175, +35) · `build apk --debug` ✓.

**Commit:** `remote-app/004` — unit done (user decision: commit only
when C3 passes). **No push** (not requested).

**Environment at handoff:** server `stop, volume=36, item_id=196174`,
`/api/outputs` byte-identical to baseline. Dev AVD `emulator-5556` still
running (headless), app under `flutter run` (debug), connected. Other
session's emulator + Pixel 6 untouched.

 **Next:** unit 005 (browse + queue + play).

## 2026-10-23 (afternoon) — remote-app unit 005a DONE: browse screens (opencode)

**Unit 005 (browse + queue + play) was split** into `005a` (browse
screens, R-10) and `005b` (queue + play, R-10/R-11): the original unit
spanned two feature areas with >3 major components. **005a is now DONE
— all five criteria PASS.** Fully unattended-safe; no playback was
started and the server stayed `stop` the whole time (verified before
and after the device walk).

**What shipped:** the whole browse section — library home (Playlists /
Artists / Albums / Genres), the eight paged list screens, pagination
(offset/limit 50, load-more within 300px of the end, de-dupe on stable
keys, `total` respected), four states per list (skeleton / empty /
error-retry / offline-stale), WS `database`/`update` invalidation, and
the API-client browse surface.

**The notable find — dio 5.11 genre-encoding (C4).** The first approach
passed the `genre is "…"` expression via `queryParameters` pre-encoded,
and dio's `encodeMap` ran `Uri.encodeQueryComponent` over it: double
encoding (`%20`→`%2520`) and `+` for spaces. Fix: percent-encode the
expression and embed it **in the request path** (`/api/search?type=
albums&expression=…`), which dio leaves untouched. On-device wire
capture of `R&B / Soul & Funk` shows
`expression=genre%20is%20%22R%26B%20%2F%20Soul%20%26%20Funk%22` → 200 with
the Black Pumas album; `curl` cross-checks confirm `&`/`/` decode
server-side. An unencoded `&` in a `queryParameters` value would have
split the query — the regression the encoding table guards.

**Design change (recorded in the unit):** the Library entry is a
text-button in the now-playing *body* beside "Playing via: …", not an
app-bar icon — a second app-bar icon overflows the 360-logical-px test
viewport by 9px (RenderFlex overflow in the existing viewport-fit
tests).

**Device evidence (dev AVD `emulator-5556`, live library):** all nine
screens render live data (11 playlists; Daniela Andrade's 4 albums
summing to 46 tracks as the artist row claims; Brass playlist tracks;
Black Pumas album tracks; `R&B / Soul & Funk` → 1 album); live empty
state (`Recently Added` → "This playlist is empty."); pagination proven
by element-tree inspection — **artists 217/217 unique** and **genres
79/79 unique**, `hasLoaded=true`, `error=null`; live offline demo
(airplane mode) → banner + stale rows, reconnect → `sync: live` +
refetch.

**Gates green on final code:** `analyze` 0 · `format` 0 changed ·
`flutter test --exclude-tags live` **+248** (175→248, +73) · `build apk
--debug` ✓.

**Commit:** `remote-app/005a` — unit done. **No push** (not requested).

**Environment at handoff:** server `stop, volume=36, item_id=196174`.
Dev AVD `emulator-5556` running (headless), app under `flutter run`
(debug), `sync: live`. Other session's emulator + Pixel 6 untouched.

**Next:** unit 005b (queue view + play-from-list/queue, R-11) — the
`supervised_steps: [1]` (first live play) needs a supervised window.

## 2026-10-26 — remote-app unit 005b DONE: queue + play actions, supervised window (opencode)

**Unit 005b DONE** (all three criteria, evidence in the unit file). All
code shipped in 005b commit; 273/273 tests, gates green incl. `build apk`.

**Supervised window (user present, explicit consent):** track-row tap on
Thundersmack "Brass" → audible (user-confirmed) via Volumio Kitchen,
queue=1 item, now-playing row highlighted (`primaryContainer` vs
baseline, render-tree colours), pause via the app's own control button
→ verified `pause`. Album row play → album order (3 tracks); artist row
play → 11-track discography (`library:artist` expansion confirmed
server-side). Full 185-item queue restored byte-identical from snapshot
after every destructive step; server ended `stop`.

**Environment incidents / findings (important for future sessions):**

1. **The OwnTone server is shared with another active session** — items
   advanced and the player paused itself twice mid-unit without agent
   action. Play-action observations were contaminated once (queue-row tap
   appeared not to start playback; direct `playUris` call proved the app
   path correct — `add?…&playback=start` from *paused* can leave the
   server paused; from *stop* it always plays). Retest that nuance on a
   private server.
2. **Pixel 6 blocks the app uid's network when the screen is off** (per-
   uid background firewall, uid 10310 → `deny`; no FGS until first
   playback). Symptom: every app socket times out (errno 110) while
   shell `nc` works. Fix for test sessions: keep the screen awake
   (`settings put system screen_off_timeout 1800000` + wake). The earlier
   `restrict-background-whitelist` was a red herring.
3. **Over-popping routes exits the app.** A blind ×5 `KEYCODE_BACK` loop
   exited the app; the next "in-app" taps hit the launcher and opened
   Calendar while the VM-service tree still showed the (backgrounded)
   app's UI — route checks must confirm `mCurrentFocus`, not just the
   widget tree. App was relaunched; no state lost.
4. `GET /artwork/item/<id>` → **204** (no artwork) makes
   flutter_cache_manager throw `Invalid statusCode: 204` (caught, benign).
   Follow-up: filter 204 → no-image.
5. **Device table update:** `emulator-5554` = `Pixel_9_Pro_API_36` (other
   session, verified via `ro.boot.qemu.avd_name` 2026-10-26);
   `emulator-5556` = `OwnTone_U2_API_36` (other session — the
   `RemoteDev_API_36` dev AVD is no longer running; unit 005b verified
   entirely on the physical Pixel 6 `25071FDF600953` per user instruction
   "physical device only" for this session).

**Gates green on final code:** `analyze` 0 · `format` 0 changed ·
`flutter test --exclude-tags live` **273/273** · `build apk --debug` ✓.
Clean APK installed on Pixel 6; boot log `connected` + `ws: open` in ~1s.

**Commit:** `remote-app/005b` — unit done. **No push** (not requested).

**Environment at handoff:** server `stop` (master volume read 0 at final
check — the value moves under the shared session), queue 185
byte-identical to snapshot; Volumio Kitchen was the selected output.
Pixel 6 awake (30-min timeout), app foregrounded (clean APK). Emulators
untouched.

**Next:** unit 006 (rating, R-12) — the rating flow needs its own
supervised window (library data mutation: record original rating first,
restore afterwards, confirm via API — AGENTS.md hard rule 4).

## 2026-10-26 (evening) — remote-app unit 006 DONE: rating display + edit (opencode)

**Unit 006 (R-12) DONE — all five criteria PASS**, incl. the supervised
library-mutation window. Stars (0–100↔0–5, `floor ~/ 20` display, `n*20`
writes, re-tap→0) on track rows + now playing; `PUT
/api/library/tracks/{id}?rating=`; WS `database` refresh. Code:
`lib/src/library/rating.dart`, `rating/rating_controller.dart`,
`ui/rating_stars.dart`, `getTrack`/`setRating` on `OwntoneApi`, wiring in
browse rows/screens + now playing + `main.dart`. 48 new tests (mapping
table pins 19/21/39/41; optimistic-rollback; WS-refetch) → **321/321**.
SCREENS.md §Rating added.

**Supervised mutations (AGENTS.md §4 protocol, all restores API-verified):**
track 1195 'Skunk' 60→100 (app)→60 ✓; track 1764 'Crown' 20→60 (app,
album-row star tap)→20 ✓ with row live-updating both ways via WS; track
1765 'Love Again' 20→80 (external curl)→row refreshed untouched→20 ✓.
Web-UI check documented as API-equivalence (SPA reads the same track GET;
user waived browser observation this session).

**Incidents (all audio-safe):** shared session self-resumed playback ~4 s
mid-window (volume 0, inaudible — re-paused; every tap now re-checks
`GET /api/player` immediately before). Screen Dozed once → firewall
blackout; `svc power stayon true` set (left on for this project's device).
Back-over-pop exited the app once (Calendar) — `mCurrentFocus` checked
after every nav batch since. Tap scale is ×2.625 (420 dpi), not ×3.0.
**uiautomator's a11y bridge died** mid-session and never recovered
(hot-restart/settings/relaunch no help) — worked around by walking the
`Semantics` widget tree from the VM (`evaluate_expression` + print →
console logs); this yielded label+bounds text evidence better than
uiautomator ever did. Track-row bodies were never tapped (row tap =
playback); star controls consume their own taps.

**Gates green on final code:** `analyze` 0 · `format` 0 changed ·
`test --exclude-tags live` **321/321** · `build apk --debug` ✓.

**Environment at handoff:** server `stop`, queue 185 byte-identical to
snapshot v1739 (first 'Skunk'), Volumio Kitchen selected; ratings 1764=20,
1195=60, 1765=20 all original. Pixel 6 awake, app foregrounded.
flutter-run debug session still attached (VM
`127.0.0.1:52014/qY9-21uw1D8=`). Emulators untouched.

**Next:** `remote-app` units 001–006 are **complete** → Phase 5
`device-verification` (full REQUIREMENTS pass on `RemoteDev_API_36`,
reconnect robustness coordinated with user, release APK on Pixel 10
GrapheneOS with the user). Follow-up still open: artwork 204-filter.

## 2026-10-26 (evening, follow-up) — rows: track/queue numbers removed from the UI (opencode)

User call: numbers rendered before the title (album rows' leading
track number, queue rows' leading position) are noise — removed
everywhere. `BrowseRow.leadingText`, `TrackRow.trackNumber`, the queue
row's 28 px number column, and the number fragments of the compound
semantics labels (`track N` / `queue item N`) are gone; the now-playing
queue row keeps its leading play-arrow icon only. `Track.trackNumber`
stays in the model (server data, parsed — just not shown). SCREENS.md
row tables updated. Tests updated (queue row finder loses the position
arg; rating screen labels) — 321/321, analyze/format/build green.
Verified live on the Pixel 6: album rows now "Crown, 3:45, 1 stars";
queue rows "Skunk, now playing, Thundersmack · Brass" (17 rendered
rows, none starting with a digit).

Tooling note: after an app relaunch, lens `console_logs` stopped
buffering prints and `hot_reload` via lens fails (needs flutter_tools'
compiler state — use `flutter run`'s own `r`); the working UI oracle is
`evaluate_expression` returning chunked strings (128-char cap). Server
untouched this follow-up: `stop`, queue snapshot-intact, all ratings at
originals.

## 2026-10-26 (late evening) — device-verification unit 001 DONE: full R-ID pass on dedicated AVD (opencode)

Full v1 requirements pass on a unit-created AVD (`OwnToneVerify_API_36`,
android-36 playstore arm64, pixel_6 — `disk.dataPartition.size=8192M`
needed for host free-disk), serial resolved by `ro.boot.qemu.avd_name`
(→ `emulator-5558`), never an existing emulator; **deleted at the end**
(`avdmanager delete avd` + empty `adb devices`). Gates green (analyze 0 /
format 0 / 321 tests); debug 189.9 MB + release 52.6 MB APKs built
(release held for unit 003 — not shipped).

Outcome: **every R-ID row has evidence** (table in the unit file).
Highlights: R-01 errors verbatim (DNS/refused; 401 N/A — unauthenticated
server); R-02 external-change sync 1.55–1.74 s, backoff + full-refetch
("WS never blocks REST" = harness-limited, accepted); R-03 seek Δ24 ms,
artwork webroot+`maxwidth=600`, 204→placeholder; R-04 app/notification/
MediaSession (media-key path) all audible-confirmed, backgrounded
controls proven during a call; R-06 foreground ±5 (Pixel 6) + backgrounded
rocker inert while playing (AVD re-run after Pixel 6 dropped off adb);
R-07 process-death (`run-as kill -9` while paused) → full recovery on
relaunch, single notification — documented `START_NOT_STICKY` (no
spontaneous revival; relaunch is the recovery path); R-08 call → pause →
resume audible + user-pause suppression, both confirmed by the user;
R-09 guard dialog + audible A→B move Kitchen→Server, restored; R-10/R-11
full (clear + WS refresh + 185-item restore twice, content-identical);
R-12 mutation 20→60→20 UI↔API verified. **FAILs:** R-13 (no search UI —
never built) → **remote-app/007 opened**; R-14 rocker-step const + no
About → **remote-app/008 opened** (user decision: FAIL + fix units,
release gate 003 not blocked). R-09 PIN N/A (no protected outputs).

Incidents: ×3 external player manipulations by the **other session
sharing 192.168.1.13** (resumes/skips/stops) — re-paused + verified each
time, seconds of audible audio with the user present; no app-caused
playback. Server exit state: `pause` frozen, volume 0, outputs [Kitchen]
(0/8 baseline), queue 185 content-match, ratings originals — all pasted
in the unit Result (harness notes there too: uiautomator revive loop,
collapse shade before dumps, outputs-checkbox tap zone, queue-restore
POST quirks, `gsm cancel`).

Staged before this entry: `handoff.md` → `handoff-2026-10-26.md`
(rename). Next: remote-app/007 + 008 fix units (re-run failed rows),
then device-verification 002 (ReTune parity diff) / 003 (release
candidate on Pixel 10).

## 2026-10-26 (night) — remote-app unit 007 DONE: search (R-13), R-13 rows re-run PASS (opencode)

Search built and verified: `OwntoneApi.searchTracks/Artists/Albums/Playlists`
(one `paging` per requested type — shape verified live; query pre-encoded in
the path, the unit-005a dio trap) + `SearchScreen` (debounced field, groups
Tracks→Artists→Albums→Playlists with `Type · total` headers, per-group
Load-more via `PagedList`, rows = the shared `browse_rows.dart` widgets,
tap-through to the existing detail screens, track tap = play) entered from
a new **Search** row at the top of the library home (app bar untouched —
unit 004 overflow rule). Empty-query idle vs no-results vs
all-groups-failed vs per-group-failed vs waiting-while-offline: distinct
states, all tested. 20 new tests (6 wire + 14 widget) cite R-13, use
`test/fakes/` only → **341/341**; analyze 0 / format 0 / debug APK 151.5 MB.

Device pass on a fresh disposable AVD `OwnToneVerify_API_36` (created by the
unit, serial resolved via `ro.boot.qemu.avd_name` → `emulator-5554` —
**serials had shifted**; **deleted at the end**, `adb devices` shows only
another session's `5560`): grouped headers == server totals (`the`: 466/32/111,
`brass`: Albums·8/Playlists·1), Load-more pagination proven against the
server across the page boundary (built rows = server page-index window
13→27 strictly increasing — no dupes/gaps), no-results `No results for
"zzzqqq".` ≠ idle hint ≠ error state, tap-through album/artist/playlist all
landed on the existing screens with server-matching rows. `track N` audit
over all 54 evidence dumps: 0 hits; no leading numbers. dv-001 table:
R-13 FAIL row replaced by the two acceptance rows, both PASS.

**Audio safety:** read-only unit — track rows / play buttons / stars never
tapped on-device; server `pause`/vol 0/progress 183192 identical at start
and end (frozen +2 s verified). No library/queue/outputs mutations.

New harness notes (in the unit file): `input swipe` across an open Gboard
gesture-types into the focused field — always `keyevent 4` +
`mInputShown=false` verify before swiping (ESC/111 unreliable); accept a
uiautomator dump only when its md5 changed AND it contains an expected
marker. The "stuck skeleton" scare was diagnosed (temp debugPrints, fully
removed) as a dump race, not an app bug.

Next: remote-app **008** (rocker-step setting + About screen — re-runs the
R-14 FAIL rows), then device-verification 002 (ReTune parity diff) /
003 (release candidate on Pixel 10). Artwork-204 follow-up still open.

## 2026-10-27 — remote-app unit 008 DONE: rocker-step setting + About (R-14), R-14 rows re-run PASS (opencode)

R-14 closed — the last R-ID gap before device-verification 002/003.
**Rocker step** (was `mirror_handler.dart:90` `static const rockerStep =
5`, `TODO(R-14)`): now a persisted `SettingsStore` pref (`rocker.step`,
1–10, default 5, clamped on read *and* write), read by the mirror handler
**at keypress time** → a Settings change applies to the *next* press, no
restart; exposed in Settings as `Volume rocker step` −/+ row (disabled at
the bounds). **About** (`lib/src/ui/about_screen.dart`, from a Settings
row): app name/version from compile-time consts (no `package_info_plus`
— a test asserts `kAppVersion` mirrors pubspec.yaml) + server
version/buildoptions from `GET /api/config`, server-version row tap
re-fetches, unreachable → `Could not reach the server.` + Retry (never
stale). R-06/D20 invariants preserved exactly (foreground flag still
gates both volume overrides; backgrounded inert at any step — new
regression test at step 10).

Gates: analyze 0 · format 0 · **362/362** (341 + 21 new: store clamping,
handler applied-immediately-on-next-press + backgrounded-inert guard,
About render/offline/re-fetch, Settings/About 360-px) · debug APK ✓.

Device pass on a fresh disposable `OwnToneVerify_API_36` (created +
**deleted** by the unit; serial via `ro.boot.qemu.avd_name` → `emulator-
5554` — the foreign `ZipCaptions_QA_API_36` was attached at `emulator-
5560` throughout and never touched). **Volume-only, zero playback
exposure**: `state=pause` re-verified before every keypress; no
transport/track-row taps. step=1 → ±1/press (vol 30→31/32/33→32),
step=10 **same session** (immediate effect) → 32→42→32; step restored 5
(+ one default-active press 0→5, then vol 0) and both step and volume
verified via API; settings persisted across `am force-stop`+relaunch
(step 3, and restored 5 over a second restart). R-06 guard re-checked
backgrounded at step 3: keyevents inert, vol 0 unchanged. About showed
`0.1.0+1` + `OwnTone 29.3` + the full live buildoptions list. Server
**byte-identical** to found (`pause`, vol 0, item 196947, progress
183192); AVD deleted, `adb devices` shows only foreign devices.
Evidence + harness notes in the unit Result; dv-001 R-14 rows replaced
with the two PASS rows (About-tap re-fetch proven by the widget-test
request-count assert — LAN re-fetch settles sub-frame: harness limit).

**Next:** device-verification **002** (ReTune parity diff) / **003**
(release candidate on Pixel 10, with the user). Artwork-204 follow-up
still open.

## 2026-10-27 — device-verification unit 002 DONE: reconnect robustness (R-01/R-02), 4/4 scenarios (opencode)

Live disruption pass on a fresh disposable `OwnToneVerify_API_36` (created +
**deleted** by the unit; serial resolved via `ro.boot.qemu.avd_name` →
`emulator-5554`; foreign `ZipCaptions_QA_API_36`/`emulator-5560` untouched —
final `adb devices` shows only foreign). Debug app on HEAD `6642bb4` via
`flutter run` → `flutter attach` (reattach after the setup force-stop killed
the run; SIGUSR1 hot reload used to inject + remove the temporary backoff
`print()` — tree and installed build stayed pure HEAD, unit-007 precedent).

**Scenarios:** (1) wifi off → `connected → offline` in **1.4 s**, banner +
stale mirror + controls-disabled, enable → reconnect +16 s + full refetch;
(2) **supervised, user present** — server restart (7 s outage): detection
+0.5 s, REST recovers +0.8 s, WS +7 s, app showed the fresh state exactly;
(3) 11 min 02 s offline → backoff **quoted from logcat**:
1000→2000→4000→8000→16000→30000 (cap) ms, attempt timestamps match the
printed delays, 27 attempts / 37 total log lines (bounded), PSS 269 MB,
reconnect +19.7 s; (4) 5× rapid flapping → single offline transition (no
phase thrash), one clean converge +12 s, **1** notification (`id=1124`,
title = current track), pid 8340 stable throughout, crash buffer +
`E/flutter` 0 at every assertion. After every scenario: `GET /api/player`
== app labels, outputs == [Kitchen], single notification — all green.

**Key harness finding:** the emulator routes on **MOBILE/`eth0`** — `svc
wifi disable` alone does not disconnect the app (WS re-established over
eth0; banner never appeared). Real isolation = `svc wifi disable` +
`svc data disable`. Related **R-02 hardening observation** (out-of-scenario,
not a FAIL): a *silent* interface-down leaves the WS socket `ESTAB` in the
kernel with zero Dart events — no `pingInterval` and no ConnectivityManager
listener means a silent middlebox drop would keep the app falsely `sync:
live`; a small follow-up (WS app-level ping or periodic REST probe while
connected) is worth a unit later.

**Incident (audio-safe, user-present):** the supervised restart lost the
server's player session (`stop`, vol 15, queue 0 — OwnTone did not persist
it). Restored with explicit user approval of the *specific* silent sequence:
185-item queue re-add (`clear=true`, no playback param), master+Kitchen
volume → 0, then play→next×2→seek 183144→pause with the only-selected output
at volume 0 = inaudible (~1 s silent stream, zero audible audio). Final
server = as found except `item_id` regenerated 196947→197132 (queue ids are
per-instance) and Δ48 ms seek precision — documented in the unit Result.
No library/rating/output-selection mutations; no external-session
interference this unit.

Gates: analyze 0 · format 0 · **362/362** · debug APK ✓ · `git diff` empty
(temp print reverted + verified before gates). dv-001 R-01/R-02 rows:
nothing shifted, both stand (backoff now evidenced live for the first time).
Harness notes in the unit file (avdmanager duplicate-partition-line gotcha,
attach/USR1 delta rule, dump md5-gate false-reject on identical screens,
wake-screen before convergence dumps, pause-from-stop 500, no
`items/play` endpoint).

**Next:** device-verification **003** (release candidate on Pixel 10, with
the user). Artwork-204 follow-up + the R-02 WS-ping hardening candidate
still open. (Earlier "002 = ReTune parity diff" mentions in this log are
stale — the unit file is reconnect robustness.)

## 2026-10-27 — device-verification unit 003 BLOCKED (not today) + release gate fully pre-staged (opencode)

Pixel 10 (GrapheneOS) release pass could not run: agent pre-flight was
complete and the user was asked to connect the device; answer **"Not
today"** (~16:03 EDT). Unit status → **blocked**; steps 1–3 recorded
`BLOCKED-PENDING-SUPERVISION`, steps 4–5 (device-bound, unsupervised)
`BLOCKED — no device`. No device touched, server read-only.

**Banked for the window (all green on clean HEAD `e765dcb`):** analyze 0 ·
format 0 · **362/362** · `app-release.apk` **52.9 MB** + debug 189.9 MB
(supersedes dv-001's 52.6 MB row — same lineage, HEAD moved). GrapheneOS
checklist done to the extent static: manifest FGS `mediaPlayback` + exact
permission set, startup runtime prompts (POST_NOTIFICATIONS +
READ_PHONE_STATE, `main.dart:46`), **zero** google/firebase/play artifacts
in Gradle + resolved lockfile (GMS-free dependency graph proven
statically); the four on-device items (Network-perm behaviour, FGS
acceptance, no-GMS crash observation, battery behaviour) explicitly
pending. **`docs/RELEASE-NOTES.md` written** (new): what-works by R-ID,
GrapheneOS setup incl. the per-app Network grant (no legacy auto-grant),
known limitations (debug-signed release APK, Chromecast server-side
selection bug, silent-drop blind spot, 204-artwork log noise,
START_NOT_STICKY relaunch-recovery, untested 401/PIN paths), and a
"GrapheneOS gate pending" banner so the notes can't be misread as a
finished device pass.

**Server left byte-identical to found** (GETs only, start == 16:05:38
curl in the unit Result): pause, vol 0, item 197132, progress 183144,
queue 185 first 'Skunk', Kitchen selected vol 0 / Server unselected vol 8.
No AVD created (none needed) — final `adb devices` only foreign
`emulator-5560`. Pixel 10 serial still unrecorded (AGENTS.md row stands).

**Next:** when the user is present — run the unit's "Prepared for the
device window" checklist (connect → record serial → install release APK →
Network perm → **verify release-build semantics export before trusting
dumps** → steps 2–5; baseline restore block is in the unit Result).
Follow-ups open (not units): artwork-204 log noise; dv-002 R-02 WS-ping
hardening.

## 2026-10-28 — remote-app unit 009 DONE: WS silent-drop hardening (opencode, unattended overnight)

TDD build of the dv-002 hardening candidate (R-02 blind spot: a silent
interface/middlebox drop left the WS `ESTAB` in the kernel with zero Dart
events → app falsely `sync: live`). Implementation is the spec's minimal
shape: `kWsPingInterval = 10 s` passed as `pingInterval:` to
`IOWebSocketChannel.connect` in the default factory of `ws_client.dart` —
dart:io fails an unponged socket (`goingAway`, pong must land within one
interval, api.dart.dev/stable/3.11.5/dart-io/WebSocket/pingInterval.html)
into the existing `onDone`/`onError` → Backoff reconnect; `notify`
subprotocol, backoff sequence, re-subscribe and REST-probe-decides-offline
untouched, no new packages. Executable contract at `05811ff` drove it:
the 3 liveness tests RED→GREEN, all pre-green guards (c1b/1d/c2) held,
kill-check performed (delete `pingInterval:` → 3/3 red, restored).
`git diff 05811ff..HEAD -- test/` empty.

On-device on a fresh disposable `OwnToneNight_009_API_36` (created +
**deleted** by the unit; serial via `getprop ro.boot.qemu.avd_name` →
`emulator-5554`; nothing else attached): iptables DROP of :3688 both ways
(REST :3689 alive, curl 200) → socket `ESTAB` confirmed pre-detection
(`ss -tp`) → **`ws: open → reconnecting` 18.4 s after the rule** (≤ 45 s,
quoted from `logcat -v epoch`), no offline/banner while REST answered
(degraded-sync live-confirmed); rules flushed → reconnect + `WS reconnected
— full refetch`, app == server (`01:51/02:06` == 111908/126516 ms, 42 %,
Kitchen selected). Healthy idle **130 s: 0** spurious reconnecting
transitions, same socket port throughout (OwnTone's libwebsockets pongs
land — the spec's live proof). Paused volume event: `pause` re-verified →
`PUT volume=55` → app `55%` ≤ ~3 s → restored 42 (204, verified). Full
isolation (`svc wifi disable` + `svc data disable`) → offline banner **+1.2 s**
(≤ 60 s) with probe `errno 101`, re-enable → converge +13.9 s. pid stable,
crash buffer 0. Server **byte-identical** start↔end (cmp of
player/outputs/queue snapshots; volume probe self-restored). External-
session deltas documented in the unit Result (queue churn 0→1514→0 by the
other session; app chip last-dumped at 1514, server baseline restored) —
not restored over. Harness notes in the unit file (logcat pipe vs `adb
root`; device-clock bracketing for drop latency; IME re-tap trap re-
confirmed).

Gates (final tree): analyze **0 issues** · format **0 changed** (82 files)
· `flutter test --exclude-tags live` **370/370** (362 + 8 unit-009) ·
debug APK ✓. Commits `05811ff` (contract) → `e039649` (impl) +
docs/result commit, pushed `origin/remote-app/009-ws-silent-drop-hardening`.

**Next:** orchestrator merges 009 (cross-ref dv-002's hardening note closed);
device-verification 003 (Pixel 10 release pass) still user-gated; artwork-204
(unit 010) untouched by this run.

## 2026-10-28 — remote-app unit 010 DONE: artwork 204 demoted to the no-image branch (opencode, unattended overnight)

TDD build per `test/artwork_204_test.dart` (contract 67d45eb): c1a RED at
baseline (400+1, the failure exactly c1a) → **401/401 GREEN**; every
pre-green guard (200→RawImage, 404/500/garbage→errorBuilder placeholder,
null-URL→placeholder, `maxwidth=600` fetch contract) held;
`git diff 67d45eb..HEAD -- test/` empty. Implementation: shared
`ArtworkProbe` (one cached dart:io GET per URL for the process lifetime,
in-flight dedup, error entries evicted, 3 s timeout — **only a probed 204**
maps to "no image"; everything else answers false so errorBuilder stays
the decider for real failures), `ArtworkBox` → StatefulWidget unmounting
the Image on a probed 204 (placeholder comes from the null-URL branch —
the branch-identity oracle), and `MirrorAudioHandler._sync` publishing
`artUri: null` (new optional `hideArtwork` on the pure `mediaItemFor`)
when the artUri URL answers 204, so audio_service's flutter_cache_manager
never fetches it. No new packages (`pubspec.yaml` byte-identical).

On-device (`OwnToneNight_010_API_36`, created + **deleted** by the unit,
serial verified via `ro.boot.qemu.avd_name` every phase): BEFORE-fix the
adjudicated line was captured verbatim — `Error loading artUri:
HttpException: Invalid statusCode: 204` + `WebHelper._manageResponse
(flutter_cache_manager …)` at 1793244632.426 with the ~20 s cache_manager
retry storm, both fetch sites logged (Image `?maxwidth=600` 204 +
cache_manager plain 204). AFTER-fix: 76 s clean window (spans the old
retry points) with **zero** 204/cache_manager/exception lines, exactly 3
launch GETs then total silence (probe cache; artUri suppressed),
placeholder renders, and an item WITH artwork still renders (mock 200 +
real-server `Invincible`, pixel-verified 217 k distinct colours). The
shared server's paused current item (track 2660 → 200) was provably
immovable without transport (now_playing is item-id anchored — insert
probe; artwork_url is server-regenerated — edit probe; both self-restored
field-identical), so the 204 rows ran against a loopback mock via
`adb reverse` serving the real snapshots and **proxying every /artwork
request byte-for-byte to the real 192.168.1.13** — OwnTone's own 204s,
both fetch sites unmodified, zero audio risk. Player + outputs
**byte-identical** start↔end; queue items field-identical (version
self-delta documented); zero transport actions; crash buffer 0. Harness
notes in the unit Result (Connect-tap-hits-Disconnect under open IME,
`pm clear` re-config trick, mock WS masked-frame parsing = fake
silent-drop, zsh `===` abort).

Gates (final tree): analyze **0** · format **0 changed** (89 files) ·
test **401/401** · debug APK ✓. Commits `620bb69` (impl) + docs/result,
pushed `origin/remote-app/010-artwork-204-filter`.

**Next:** device-verification 003 (Pixel 10 release pass, user-gated);
dv-002's WS-ping hardening is closed (unit 009, merged). Artwork-204
follow-up from 005a: **closed** by this unit.
