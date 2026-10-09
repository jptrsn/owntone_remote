---
name: 001-spike-app
status: pending
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

*(fill on execution: evidence per criterion, gate outputs, survival report,
GO/NO-GO + rationale, incident log if any playback escaped)*
