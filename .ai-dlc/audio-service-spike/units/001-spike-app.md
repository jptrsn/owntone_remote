---
name: 001-spike-app
status: blocked
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

**State: `blocked` — NO-GO declared 2026-10-10.** Supervised window
executed 2026-10-10 (user-confirmed) on `RemoteDev_API_36` (serial
`emulator-5554`). **Criterion 4 FAILED** (volume rocker never changes
the server's volume — the system never selects our session for volume
key routing, in paused *or* playing state) → per the unit's GO/NO-GO
clause, **NO-GO for Flutter/audio_service** is declared; the
Kotlin+Media3 fallback is sketched below. Build work stops pending the
user's stack re-decision.

Scoreboard: 1 PASS · 2 PASS (stop + pause) · 3 mechanism PASS (literal
web-UI form BLOCKED — emulator shut down) · **4 FAIL** · 5 PASS (with
caveats) · 6 negative PASS (resume half BLOCKED) · 7 PASS.

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

### Criterion 3 — server-side change → app in ~2 s via WS: mechanism
PASS, literal web-UI form BLOCKED

- WS subscription fixed (see Findings): after the fix, server-side
  changes reach the app live. Measured (shell-only, app foreground):
  `PUT /api/player/volume?volume=80` → app UI volume text updated
  within one uiautomator poll, **total < 3 s including ~1.5 s of dump
  overhead** (event → refetch → render is the fast part).
- The criterion's exact "web UI action → ~2 s" form needs a user click
  in the web UI. **BLOCKED:** the dev AVD was shut down mid-window
  (broken emulator GUI — sidebar controls dead; see Findings 7).
  Re-runnable in any later window; the WS pipeline is already proven
  end-to-end by the mechanism test and by the app tracking live
  server state (item advances, progress, volume) throughout the window.

### Criterion 4 — rocker changes master (server) volume: **FAIL**

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

### Criterion 6 — call pause/auto-resume: negative half PASS,
resume half BLOCKED

- App backgrounded, server **user-paused**: `adb emu gsm call` → app
  log `call state: ringing` (21:33:12) → server stayed paused (the app
  did not claim a pause it didn't cause) → `gsm cancel` →
  `call state: idle` (21:33:38) → server **still paused, no
  auto-resume**. D9 pause-origin logic behaves correctly on device.
- "Call pauses a *playing* server + auto-resume on end" — the other
  GO/NO-GO clause — **BLOCKED**: the dev AVD was shut down mid-window
  (broken emulator GUI, Finding 7) before this test ran. It remains
  the one safety behavior unverified on device; re-runnable in a
  later window (needs: play → `adb emu gsm call 5551234567` →
  verify auto-pause → `gsm cancel` → verify auto-resume → pause).

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
   position is not restorable without supervised queue ops.

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

### Environment left as (2026-10-10, window end)

`state=pause`, `volume=75` (restored; had drifted to 28 during
window), `consume=false`. Queue current item = 196001 (drifted from
the pre-session position by auto-advance during supervised playback;
restoring the original position needs supervised queue ops — not
done). Dev AVD **shut down by the user** (broken GUI). Adbd was left
running as **root** on the emulator before shutdown (`adb root` was
used for `sendevent`; normal emulators reset on next boot).

### GO / NO-GO — **NO-GO** (declared 2026-10-10)

**Criterion 4 failed after reasonable effort** (multiple controlled
tests across paused/playing, screen on/off, injected keys, framework
log capture — evidence in the criterion section). Per the unit's
clause: **NO-GO for Flutter + audio_service; build work stops; the
stack re-decision is the user's.**

The failure is in *system session selection* (AOSP
`MediaSessionService` never picks our session for volume keys), not
in the Dart layer. Two honest hedges before the re-decision:

1. **Emulator vs. device.** The "Media button session is null"
   behavior may be emulator-specific. The cheapest decisive
   experiment: install the same debug APK on the Pixel 10
   (GrapheneOS release candidate, not yet connected) and repeat the
   criterion-4 matrix. If the rocker works there, the architecture
   stands and only the test device was wrong.
2. **What Media3 would change.** A Kotlin+Media3 session uses the
   *same* framework session API; nothing guarantees Media3's session
   gets selected where audio_service's wasn't. What Media3 does
   change: full control over session lifecycle (`setActive`,
   `setMediaButtonReceiver`, explicit `MediaController` volume
   handling, `AudioAttributes`/session config), a maintained
   (non-stuck) media-button path (the one-shot bug, Finding 5, is in
   audio_service's receiver flow — Media3's `MediaButtonReceiver`
   usage is standard and not one-shot), and a cleaner FGS lifecycle.

**Fallback sketch (Kotlin+Media3), if chosen:**

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
