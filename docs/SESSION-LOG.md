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
