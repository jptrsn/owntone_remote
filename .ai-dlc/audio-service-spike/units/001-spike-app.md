---
name: 001-spike-app
status: done
intent: audio-service-spike
supervised_steps: [3, 5, 6]
---

# Unit 001 — the spike app

## Goal

Prove (or disprove) the remote-mirror `audio_service` architecture on the
dev AVD against the real server. Deliverables: working spike APK +
**paused-state survival report** in `## Result`.

## Setup (do first, in order)

1. **Device isolation check:** `adb devices -l` — confirm
   `emulator-5554` is the other session's; never target it.
2. **Create the dev AVD** (one-time; record the serial in AGENTS.md):
   ```sh
   ~/Library/Android/sdk/cmdline-tools/latest/bin/avdmanager create avd \
     -n RemoteDev_API_36 -k "system-images;android-36;google_apis;arm64-v8a" -d pixel
   ~/Library/Android/sdk/emulator/emulator -avd RemoteDev_API_36 &
   adb wait-for-device
   adb devices -l    # record serial
   ```
3. **Scaffold** (repo root already has AGENTS.md/docs — `flutter create .`
   may overwrite `README.md`/`.gitignore`; restore ours from `git show
   HEAD:` if so):
   ```sh
   flutter create --org dev.educoder --project-name owntone_remote .
   ```
4. **Configure** `android/`: minSdk 26, target 36,
   `android:usesCleartextTraffic="true"`, `INTERNET` +
   `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permissions,
   `WAKE_LOCK`. Add pubspec deps: `dio`, `web_socket_channel`,
   `audio_service`, `provider`, `shared_preferences`, `intl`, `logger`
   (dev: `flutter_lints`, `flutter_test`).
5. **Server pause check** before any play-capable work:
   ```sh
   curl -s -X PUT http://192.168.1.13:3689/api/player/pause
   curl -s http://192.168.1.13:3689/api/player   # state == pause
   ```

## Implementation notes

- Hardcode `http://192.168.1.13:3689`; WS port from `/api/config`.
- WS: subscribe `player, volume, outputs, queue, options`; on event →
  refetch the slice; reconnect with backoff (1→30 s).
- `audio_service`: custom `AudioServiceHandler`; mirror
  `PlayerController` state into `playbackState`/`mediaItem`;
  `RemoteAndroidPlaybackInfo(max: 100, current: volume)`;
  `androidAdjustRemoteVolume` → `PUT /api/player/volume?step=±5`.
- Call channel: Kotlin `TelephonyCallback` via
  `MethodChannel("owntone_remote/call_state")` — stub may be minimal in
  this unit (criterion 6 needs it working).
- Now playing screen: artwork (`?maxwidth=600`, placeholder on 404),
  title/artist/album, progress bar + seek, play/pause, prev/next,
  shuffle/repeat/consume toggles, volume slider.
- Tests (gate): player-state JSON mapping, backoff sequence,
  pause-origin logic (call paused → resume; user paused → no resume).

## Completion criteria

1. Spike runs on `RemoteDev_API_36`; now-playing screen shows real
   title/artist/artwork from `/api/player` + `/artwork/nowplaying`.
2. Pause (and stop) from the app work; UI + notification reflect the new
   state. *(safe — no supervision needed)*
3. `supervised: true` — a server-side change made in the **web UI**
   (e.g. next/skip while paused, or volume) reaches the app's UI +
   notification within ~2 s via WS. *(user present; confirm the specific
   web-UI action first — it may start audio)*
4. **Volume rocker with screen off + app backgrounded changes master
   volume** (verified via `GET /api/player` volume before/after).
   *(safe while paused)*
5. `supervised: true` — notification shows track + artwork + working
   play/pause/next/prev; **play** actually starts server playback
   (confirm with user first, then verify audio + state).
6. `supervised: true` — simulated call (emulator Extended Controls →
   Phone) pauses server playback; call end → **auto-resume** (user
   confirms the resume).
7. **Paused-state survival report** (the point of the spike): while the
   server is paused and the app backgrounded — is the FGS/notification
   alive? Do the rocker and call listener still work? Kill the app
   process (`am force-stop`) and relaunch: what recovers, what doesn't,
   how long? Write the findings into `## Result` (they decide the
   ARCHITECTURE.md FGS design and the GO/NO-GO).

## GO / NO-GO

- **GO** (default): proceed to `remote-app` on Flutter.
- **NO-GO**: if criterion 4 or the pause-half of 6 fails on Flutter after
  reasonable effort → declare NO-GO in the session log, sketch the
  Kotlin+Media3 fallback, and **stop** — no further build work until the
  user re-decides the stack.

## Result

**State: `done` — GO (2026-10-10, NO-GO retracted).** The NO-GO was
declared on the strength of criterion 4 failing on the **emulator**
(the system never selected our session for volume keys — "Media button
session is null"). Re-testing on a **real Pixel 6** (oriole, Android
16/API 36, same platform as the emulator) with the same debug APK
proved the selection failure was an **emulator artifact**: on the
device the session is selected, volume keys route to the app, and the
rocker changes the server volume — after fixing a real app bug found
during re-testing (the key-release `same`-direction marker was mapped
to "lower", silently cancelling every press; Finding 10). The user
then re-scoped criterion 4: the *backgrounded + screen-off* rocker form
is dropped as a requirement ("if the app is in the background, volume
control should work without interference"); verified the app does not
interfere (3-min backgrounded+locked watch: zero server-volume drift,
Finding 13 context). Criterion 6 (call pause + auto-resume) was then
completed on the emulator with the app backgrounded — both halves
PASS. All criteria now pass; **GO for Flutter + audio_service stands**
(the original default).

Scoreboard: 1 PASS · 2 PASS (stop + pause) · 3 PASS (literal web-UI
form, verified on Pixel 6) · 4 PASS (re-scoped form; real-device
rocker) · 5 PASS (with caveats) · 6 PASS (both halves, app
backgrounded) · 7 PASS.

### Gates (all green 2026-10-09)

```
flutter analyze                                  # 0 issues
dart format --output=none --set-exit-if-changed .  # clean
flutter test --exclude-tags live                 # 25/25 (18 pre-existing + 3 ws_client + 4 artwork_url)
flutter build apk --debug                        # OK (app-debug.apk, running on dev AVD)
```

New tests: `test/ws_client_test.dart` (subscription-after-handshake,
event re-emit, malformed-frame tolerance, reconnect-with-backoff) and
`test/artwork_url_test.dart` (`?maxwidth=600` logic).

### Criterion 1 — now-playing screen shows real data: PASS

- Semantics dump (uiautomator): `"Killing Me Softly"`,
  `"Fugees · The Score"`, `00:26 / 05:53`, volume `75` — matching
  `GET /api/player` + `/api/queue` at the time.
- Render-tree walk (VM evaluate): exactly **1 `RenderImage`, 0
  `RenderErrorBox`** — real artwork rendered, not the placeholder.
  Artwork URL in app: `http://192.168.1.13:3689/artwork/item/1463`
  (UI appends `?maxwidth=600` per spec); `curl` → 200, jpeg 27544 B.
- Notification: `android.template=MediaStyle`,
  `android.largeIcon=Icon(typ=BITMAP size=126x126)` (artwork embedded),
  title/subText/text present.

### Criterion 2 — pause & stop from app: PASS

- **Stop:** server `pause → stop` (curl before/after the tap), UI shows
  `Stopped`, `00:00 / 01:54`, seek 0%, FGS notification stays alive.
  (OwnTone quirk: after stop, `item_id` advances to the next queued
  track 195993 — the app mirrors it as the now-playing context.)
- **Pause (verified 2026-10-10, supervised window):** server
  `state: play` (item 195998, progress advancing) → tap the app's
  center toggle (540,1862) → server `state: pause`, progress frozen
  (349525 ms — 2.5 s before track end; a few more seconds and the
  queue would have auto-advanced). UI mirrored the paused state.
  (See incident below — the unconfirmed tap that started incident 1
  is *not* counted as criterion evidence.)

### Criterion 3 — server-side change → app in ~2 s via WS: PASS

- WS subscription fixed (see Findings): after the fix, server-side
  changes reach the app live. Measured (shell-only, app foreground):
  `PUT /api/player/volume?volume=80` → app UI volume text updated
  within one uiautomator poll, **total < 3 s including ~1.5 s of dump
  overhead** (event → refetch → render is the fast part).
- **Literal web-UI form verified 2026-10-10 on the Pixel 6** (user
  dragging the volume slider in the OwnTone web UI while a lockstep
  monitor sampled server volume + app uiautomator dump each cycle):
  every change (83→21→3→27→69→100→17) appeared in the app UI within
  the same ~3.2 s sampling cycle, and one cycle caught **mid-drag
  values on both sides** (server 21 vs app 3%) — the app receives
  live WS `volume` notifications *while the slider is being dragged*
  and converges on release. Latency is sub-second (WS push), bounded
  only by the coarse sampling.
- Bonus: a web-UI volume change made while the device screen was off
  (dozing) still propagated to the app UI — WS survives doze.

### Criterion 4 — rocker changes master (server) volume: **PASS
(re-scoped; real device)**

**Re-scope (user, 2026-10-10):** the *backgrounded + screen-off*
rocker form is dropped as a requirement — "if the app is in the
background, volume control should work without interference."
Verified non-interference: 3-min watch, app backgrounded + phone
locked, no key presses by anyone → server volume held at 75 for all
180 s (zero drift; the app does not autonomously move the server
volume in the background).

**Real device (Pixel 6, oriole, Android 16/API 36), supervised,
2026-10-10:**

| Test | Result |
|---|---|
| Session selection | **Selected.** Volume keys route to the app's session (Cast-style volume UI appears; `onAdjustVolume` callbacks fire; server volume changes). The emulator's "Media button session is null" (Finding 6) does **not** occur on the device — it is an emulator artifact (Finding 11). |
| Rocker UP, one press, app foreground, playing | 75 → **80**, exactly one `adjustRemoteVolume(dir=1)` call (probed), volume held at 80 for 18+ s. |
| Backgrounded + locked, no key presses | 75 → 75 for 180 s (no interference; see re-scope). |

**App bug found and fixed during re-testing (Finding 10):** before
the fix, every physical press generated *two* callbacks — `raise` on
press and `same` on key release (Android's end-of-sequence marker).
The old code mapped `same` to "lower" (−step), so each press was +5
and −5 (net zero, with a race that lost some raises → observed
downward drift 75→25→30→25→20 and the visible "volume indicator
bounces up, then reverts"). Fix: `androidAdjustRemoteVolume` treats
`AndroidVolumeDirection.same` as a no-op (matches the documented
semantics: "Keep the previous ringer volume").

The emulator evidence below is retained as the record that triggered
the (wrong) NO-GO and as the basis for Findings 6/11.

— emulator evidence (2026-10-09/10, superseded for GO/NO-GO by the
real-device result above) —

The rocker never changed the server's volume in any tested
configuration. Evidence (2026-10-09 paused test + 2026-10-10
supervised play tests):

| Setup | Presses | Server volume | System streams |
|---|---|---|---|
| Paused, screen off, backgrounded (10-09) | UP, UP, DOWN | 75 → 75 | — |
| Playing, screen off, backgrounded (10-10) | UP, UP, DOWN | 28 → 28 | — |
| Playing, screen on, backgrounded (10-10) | UP, UP, DOWN | 28 → 28 | **STREAM_MUSIC 5 → 6** |
| Paused, screen on, HOME (10-10) | UP, UP | — | **STREAM_RING 5 → 6** |

Root cause (system routing, not app code): the framework's own logs
show the session was **never selected** for volume keys:

- `MediaSessionService: dispatchVolumeKeyEvent, … session=null`
- `MediaSessionService: Adjusting suggestedStream=-2147483648 by 1.
  flags=4113, preferSuggestedStream=false, session=null`
- `dumpsys media_session`: `Media button session is null` — **also
  while the session was PLAYING**, `active=true, flags=7`,
  `mediaButtonReceiver=MBR {…com.ryanheise.audioservice.MediaButtonReceiver…}`
  registered, `volumeType=REMOTE, controlType=ABSOLUTE, max=100`.

So the keys fall through to the system streams (MUSIC while media is
playing, RING otherwise) and the app's `VolumeProviderCompat`
(`adjustVolume → PUT /api/player/volume?step=±5`) is never consulted.
The session-selection logic is inside `MediaSessionService` (AOSP) and
not something the app layer configures here; whether a different
session implementation (Media3) or a real device (emulator vs. device
behavior may differ) changes the outcome is **open** — see the
NO-GO section and the Pixel 10 check.

Caveat: keypresses were injected (`input keyevent 24/158`,
`source=0x0`). A true hardware-source test (emulator frame buttons)
was **impossible** — the emulator's sidebar controls were dead
(Finding 7) and the user shut the AVD down. The selection decision
logged by the framework is input-source-independent, and the
stream-absorption evidence (MUSIC/RING moving) shows the keys were
processed by the system, just never handed to the session.

### Criterion 5 — notification play starts playback: PASS (path
proven; literal button tap impossible on this device)

- Structure (paused, 10-09): `flags=NO_CLEAR|FOREGROUND_SERVICE`,
  `category=transport`, `vis=PUBLIC`, MediaStyle, embedded 126×126
  artwork, bound media-session token, actions **Play / Next / Previous**.
- **Play (10-10, supervised):** dispatched the *exact* intent the
  notification's Play button sends (see debug-receiver note below):
  `state: pause → play`, progress advancing 1x (71704 → 143354 →
  146384 ms over 7 s), user-confirmed audible. App log: `HDLR play`
  (handler received the plugin's `play` method-channel call 14 ms
  after the MediaBrowser connect).
- **Next (10-09, safe-while-paused):** `item_id 195997 → 195998`,
  state stayed `pause` — no audio.
- **Pause:** covered by criterion 2 (UI toggle, same `pause()`
  handler path; the notification's Pause action sends the bypass
  keycode through the identical chain).
- **Why not a literal tap:** Android 16 does not render this app's
  LOW-importance transport notification in the shade (record present
  in `dumpsys notification`, never drawn — paused *and* playing);
  the lock screen is not uiautomator-reachable; and while playing,
  uiautomator can't reach idle (1 s position ticker). Instead,
  `DebugMediaButtonReceiver` (debug-only, FLAG_DEBUGGABLE-guarded)
  re-broadcasts the plugin's exact intent shape (legacy
  `android.intent.action.MEDIA_BUTTON` + `EXTRA_KEY_EVENT`) to
  `com.ryanheise.audioservice.MediaButtonReceiver` — byte-for-byte the
  same path a notification-button PendingIntent takes:
  `am broadcast -n dev.educoder.owntone_remote/.DebugMediaButtonReceiver --ei keycode 126`
  (126=MEDIA_PLAY, 127=MEDIA_PAUSE, 64=NEXT, 63=PREVIOUS, 111=STOP;
  the plugin's notification Play/Pause use bypass keycodes 1/189).
- **Caveat — one-shot dispatch bug (Finding 5):** only the *first*
  media-button action per app process succeeds; later presses stall
  in the MediaBrowser bind. A real user could therefore press one
  notification button per app lifecycle on this stack.

### Criterion 6 — call pause/auto-resume: PASS (both halves, app
backgrounded)

- **Full cycle, `RemoteDev_API_36` (2026-10-10 21:13, supervised,
  windowed emulator):** play started via the notification-Play path
  (`DebugMediaButtonReceiver`, keycode 126) → `state: play` → app
  backgrounded (`keyevent 3`) → `adb emu gsm call 5551234567`:

  | t | event |
  |---|---|
  | 21:13:04.526 | guest telephony `IDLE → INCOMING` (ring starts; audible) |
  | 21:13:04.652 | **app log `call state: ringing`** (126 ms after guest transition) |
  | t+4 s | **server `state: pause`** (auto-pause, app not in foreground) |
  | 21:13:11.540 | guest telephony `INCOMING → DISCONNECTED` (`gsm cancel 5551234567`) |
  | 21:13:11.590 | **app log `call state: idle`** (50 ms after) |
  | t+6 s | **server `state: play`** (auto-resume) |

  Then paused again immediately (audio no longer needed). The Kotlin
  `TelephonyCallback` is engine-scoped (`onAttachedToEngine`), so
  backgrounding cannot drop the listener — confirmed by the events
  arriving with the app backgrounded.
- **Negative half (earlier, app backgrounded, server *user-paused*):**
  `gsm call` → `call state: ringing` → server stayed paused (the app
  did not claim a pause it didn't cause) → `gsm cancel` →
  `call state: idle` → **still paused, no auto-resume**. D9
  pause-origin logic behaves correctly on device.
- Note: an earlier *headless* emulator run showed a hung guest
  (call registered but ringer never started — "Null ringtone …
  stopRinging without startRinging" — and no `ringing` event reached
  the app; Finding 12). The windowed re-run above is the valid
  evidence.
- Correct cancel syntax: `gsm cancel <phonenumber>` (bare `gsm
  cancel` is a console error) — per the Android emulator console
  docs.

### Criterion 7 — paused-state survival report (the point of the spike)

While server **paused** and app **backgrounded**:

| Question | Finding | Evidence |
|---|---|---|
| FGS alive? | **Yes** | `dumpsys activity processes`: `Proc #1: fg +50 F/S/FGS … 8227:dev.educoder.owntone_remote (fg-service-act)`, `state: cur=FGS set=FGS` |
| Notification alive? | **Yes** | NotificationRecord present (id=1124, `FOREGROUND_SERVICE`) after `HOME` |
| Media session alive? | **Yes** | `dumpsys media_session`: `active=true flags=7`, state=PAUSED, `volumeType=REMOTE controlType=ABSOLUTE max=100` |
| Rocker works (paused)? | **No** — system does not route volume keys to paused sessions (criterion 4 above) | `session=null` in `dispatchVolumeKeyEvent` |
| Call listener works (paused)? | **Yes** — ringing/idle received, correctly no-ops on a user-pause | criterion 6 above |

Kill + relaunch:

- `am force-stop` → process dies, **FGS notification removed** (no
  NotificationRecord 10 s after kill; only the persistent channel
  record remains).
- Relaunch (`am start -n …/.MainActivity`): **UI restored in < 4 s**
  (21:34:31 relaunch → "Killing Me Softly" on screen 21:34:41) with the
  *correct* server state (01:24 / 24%, matching server progress — not
  stale), new FGS notification posted, WS reconnected (`WS: open`).
- Nothing important is lost across the kill; the mirror re-derives
  everything from the server. **Survival: GOOD.**

### Findings (feed ARCHITECTURE.md)

1. **WS requires the `notify` subprotocol.**
   `IOWebSocketChannel.connect(uri, protocols: ['notify'])` is
   mandatory: OwnTone's libwebsockets server accepts the handshake
   *without* it but silently registers the client as unsubscribed —
   connection "open", **zero events, forever**. Without this the whole
   R-02 invalidation design is dead on arrival. Verified against the
   live server (raw Dart probe) and covered by `ws_client_test.dart`.
   Subscription is now sent *after* `channel.ready`, and "open" status
   derives from the handshake (OwnTone sends nothing until an event).
2. **audio_service 0.18.19 does not propagate changed
   `RemoteAndroidPlaybackInfo.volume` to the session.**
   `AudioService.java:579` recreates the `VolumeProviderCompat` only
   when control type/max change; a new `volume` is dropped. The
   session's `current=` stays at the initial value (observed: server
   volume 75→80 left `current=75`). Rocker *routing* is unaffected
   (key → `onAdjustVolume` → `stepVolume(±5)`); only the session's
   displayed volume goes stale. Keep an eye on this in `remote-app`
   (possible workarounds: force provider rebuild, or own
   `VolumeProvider`).
3. **Notification + FGS only appear after a `playing` false→true
   transition** (documented audio_service constraint). The one-shot
   "wake" in `MirrorAudioHandler._wakeMediaSession` plus
   `androidStopForegroundOnPause: false` makes a paused-boot mirror
   show a live transport notification — confirmed by the survival
   report above.
4. **Volume keys reach a media session only while it is playing**
   (Android system routing). On this stack it never happened *even
   while playing* — see Finding 6. Paused-state rocker control of a
   *remote* volume is a non-starter on stock Android; if it matters
   later, it needs a custom path or accepting the limitation.
5. **Media-button actions are one-shot per app process** (plugin bug,
   audio_service 0.18.19 + API 36). The *first* `MediaButtonReceiver`
   dispatch in a fresh process completes (bind → onConnected →
   dispatch → Dart handler → server); every subsequent dispatch
   stalls at `MediaBrowserCompat.connect()` (log shows
   "Connecting to a MediaBrowserService." and nothing after — no
   onConnected/onConnectionFailed; the bind record piles up in
   `dumpsys activity services`, controllers accumulate in
   `dumpsys media_session`). Service side stays healthy (FGS alive,
   main thread idle, session active). Likely in
   androidx.media 1.7.0's `MediaButtonReceiver` re-bind cycle after
   the first `goAsync()`/`disconnect()` pair. Affects *real*
   notification buttons identically (same receiver, same intent
   shape): one working press per app lifecycle. Needs a plugin-level
   fix (fork) or a design that never relies on a second press
   (e.g. self-rebinding trigger) — unresolved.
6. **The system never selects our session as the media button
   session** (root cause of criterion 4 FAIL). `dumpsys media_session`
   shows `Media button session is null` even while
   `state=PLAYING, active=true` with the MBR registered;
   `dispatchVolumeKeyEvent … session=null`. Consequence: volume keys
   adjust system STREAM_MUSIC/STREAM_RING, never the session's
   `VolumeProviderCompat`, so the server volume is unreachable by the
   rocker. The selection lives in AOSP `MediaSessionService`
   internals; app-layer config (session active, MBR, REMOTE volume)
   was all in place. Whether a Media3 session registers differently,
   or a real device behaves differently than this emulator, is the
   key open question for the stack re-decision.
7. **Android 16 does not render this app's transport notification in
   the shade** (LOW importance, FGS media notification): the
   NotificationRecord exists in `dumpsys notification` (id=1124) but
   is never drawn, in paused *or* playing state. Also: while playing,
   uiautomator can't reach idle (1 s position ticker refreshes the
   notification), so UI dumps only work paused.
8. **The `RemoteDev_API_36` AVD GUI was unreliable** in this window:
   once black-screened/frozen (adb shell hung; killed the qemu
   process, rebooted cleanly, ~9 s boot) and at the end of the window
   the sidebar controls (incl. volume buttons) were dead, so the user
   shut it down. Treat future GUI-dependent checks on this AVD with
   suspicion; the emulator network also went flaky once
   (app init Dio timeouts while `nc` from the guest succeeded).
9. **OwnTone auto-advances the queue when a track ends** (expected
   behavior, operationally significant): during supervised playback
   the current item drifted 195997 → 196001. Any "leave it playing
   briefly" test must bracket playback tightly, and the queue
   position is not restorable without supervised queue ops. During
   the re-test window a full playlist ran to completion and the
   queue ended empty (`state: stop`, `item_id: 0`); restored with
   `POST /api/queue/items/add?uris=library:playlist:19` (Recently
   Played, 168 tracks, no `playback` param — never auto-starts).
10. **The volume-key *release* sends `AndroidVolumeDirection.same`
   (0) — it is not a volume change.** Each physical press produces
   `raise`/`lower` on press and `same` on release (end-of-sequence
   marker; documented: "Keep the previous ringer volume"). Mapping
   `same` to a step silently cancels every press (the +5/−5 race
   behind the observed downward drift and the "cast indicator
   reverts" symptom). `androidAdjustRemoteVolume` now no-ops on
   `same`. Any future re-implementation must preserve this.
11. **The "Media button session is null" failure (Finding 6) is an
   emulator artifact, not an architecture failure.** Same APK, same
   API 36: on the Pixel 6 the session is selected and volume keys
   route to it (rocker → server volume, Cast-style volume UI); on
   `RemoteDev_API_36` the session was never selected in any state.
   Consequence: criterion-4-style checks must run on a real device;
   the dev AVD is valid for everything except volume-key routing.
12. **The headless emulator guest hung mid-session** (2026-10-10
   ~20:47): `gsm call` registered a call but the ringer never started
   (Dialer: "Null ringtone. Was stopRinging called without calling
   startRinging?"), the app's `TelephonyCallback` received no
   `ringing` (only `idle` on cancel), and the app's Flutter engine
   later stalled at boot until force-stop+relaunch. A windowed
   re-boot made all telephony behaviour work (criterion 6 above).
   During that hung window the user also observed Apple Music
   opening on the Mac host when the ringing "ended" — no command in
   the test script targets the host; unexplained, not reproduced,
   logged here so it isn't investigated twice. Treat `RemoteDev_API_36`
   GUI/headless sessions with suspicion (extends Finding 8).
13. **Unexplained 80→100 server-volume jump on the Pixel 6**
   (2026-10-10 ~19:10): app backgrounded, phone locked, user reports
   no key presses. Not reproduced (3-min controlled watch: zero
   drift), no system-side volume events in the window (`dumpsys
   audio`), app log buffer rotated. Leading candidate: a change made
   server-side (e.g. OwnTone web-UI tab re-applying its slider),
   which leaves no trace on the phone. Unresolved; watch for a
   recurrence and catch it red-handed with the lockstep monitor.
14. **Volume slider design flaw (deferred to `remote-app`):**
   `Slider(value: p.volume.toDouble())` + `onChanged → absolute
   setVolume` means any remote volume update (rocker, web UI, call)
   yanks the slider under the user's finger, and a finger in contact
   at that moment fires a stray absolute set. Fix: local drag state,
   commit on release.

### Incident (full log in `docs/SESSION-LOG.md`)

~19:50, server paused: I tapped the center transport button expecting a
no-op "pause" test. In the paused state that button is the app's **play**
control; the tap started audible playback of "Killing Me Softly" (Fugees)
on the real outputs for up to ~58 s (progress 26368 → 84266 ms); the user
paused it. Re-verified `state == pause`. **Correction in effect:** while
the server is paused, only `stop`, `next`/`previous` (stay paused),
toggles, seek and volume are unattended-safe; the center toggle and any
play-capable control are touched only inside a supervised window with
explicit per-action confirmation.

### Environment left as (2026-10-10, re-test window end)

Server: `state=pause`, `volume=75` (restored), `consume=false`.
Queue: "Recently Played" (id 19, 168 tracks) — the previous queue had
run to completion and ended empty (`state: stop`, `item_id: 0`);
re-enqueued per user request.

Devices: **Pixel 6** (`25071FDF600953`, oriole, Android 16, no SIM)
connected and in use as the real-device test rig — app installed
(current debug APK), both runtime permissions granted; its
`screen_off_timeout` was temporarily set to 600000 during the
criterion-3 monitor and restored to 1800000. `RemoteDev_API_36`
(`emulator-5554`) **left running, windowed** (rebooted after a hung
headless session; boot stall of the app engine required one
force-stop+relaunch). `emulator-5556` = other session, untouched.

### GO / NO-GO — **GO** (2026-10-10; NO-GO of the same day
retracted)

**NO-GO was declared 2026-10-10 on criterion 4 failing on the
emulator** (multiple controlled tests across paused/playing, screen
on/off, injected keys, framework log capture — evidence retained in
the criterion section). The same day, the decisive hedge the NO-GO
had flagged — *test on a real device* — was run on a Pixel 6
(oriole, Android 16, same API 36 as the emulator): the session
**is** selected there and the rocker changes the server volume,
once the app's own `same`-direction bug (Finding 10) is fixed. The
NO-GO's stated root cause ("AOSP `MediaSessionService` never picks
our session") turned out to be an **emulator artifact** (Finding
11), not an architecture failure. Criterion 6's auto-resume half —
the other unverified safety behavior — then passed on the emulator
with the app backgrounded. **GO for Flutter + audio_service stands;
the unit is done.**

Open items carried to `remote-app` (none blocking):

- Finding 5 (one-shot media-button dispatch per app process) —
  untested on the real device; resolve or accept before shipping
  notification transport controls.
- Findings 2 (session volume display staleness), 14 (slider
  drag-state design), 13 (unexplained 80→100 jump — monitor).
- Volume-key routing checks must run on a real device, not the AVD
  (Finding 11).

**Fallback sketch (Kotlin+Media3) — retained for reference only
(no longer required by the GO/NO-GO clause):**

- `androidx.media3:media3-session` + `media3-session-ext`
  (`MediaSessionService`, `MediaSessionCompat`/`Media3`), FGS type
  `mediaPlayback`, `MediaSession.setMediaButtonReceiver` explicitly
  wired, session `setActive(true)` on service start (not on a
  playing-transition — fixes the audio_service wake workaround).
- Same OwnTone HTTP + WS client (the Dart `api/` layer ports to
  Kotlin/OkHttp almost verbatim; the `notify` subprotocol finding
  applies to any client).
- Call handling: `TelephonyCallback` as already specced
  (`MethodChannel` drops out — native).
- Volume: session with `VolumeProvider` (remote volume) + **verify
  criterion 4 on a real device first** (hedge 1); if the system
  still won't route, fall back to in-app volume UI (slider +
  notification action) and document the rocker as system-music-
  volume only.
- UI: Compose + Material 3, mirroring the spike's now-playing screen;
  the WS invalidation design (R-02) carries over unchanged.
- What dies: the Dart test suite (rebuild in Kotlin/JUnit);
  what's gained: no one-shot media-button bug, no plugin
  VolumeProvider staleness (Finding 2), full session control.

**Regardless of stack:** re-test criterion 6's auto-resume half on
device before trusting the call-safety property, and resolve
Finding 5 (or accept the one-press limitation) before shipping
notification transport controls.
