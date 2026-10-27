# Release notes — OwnTone Remote 0.1.0

Release candidate: `app-release.apk` 52.9 MB, built from `e765dcb`
(`flutter build apk --release`, gates green: analyze 0 issues ·
format 0 changed · 362/362 tests). Package `dev.educoder.owntone_remote`,
minSdk 26, targetSdk 36. Verified against OwnTone **29.3**
(JSON API `:3689`, websocket `:3688`).

## What works

Verified on-device (Android 16 AVD, full R-ID pass, device-verification
units 001–002; see `.ai-dlc/device-verification/units/`):

- **Connection** — host/port settings, auto-reconnect on relaunch, and
  distinct errors for DNS failure vs refused port vs auth (`R-01`).
- **Reconnect robustness** — offline banner in ~1.4 s of a hard network
  loss, reconnect backoff 1→2→4→8→16→30 s (capped), full refetch on
  reconnect, no notification duplication or state thrash under rapid
  flapping (`R-02`).
- **Now playing** — metadata + artwork (server-relative artwork URLs
  resolved against the webroot with `maxwidth`), progress follows the
  server, seek accurate to ≤50 ms (`R-03`).
- **Transport & controls** — play/pause/next/previous, media-session
  (lock screen) and notification actions, all working with the app
  backgrounded (`R-04`).
- **Notification** — one persistent `mediaPlayback` foreground-service
  notification with the current track and Play/Next/Previous actions;
  updates from websocket events; survives backgrounding (`R-07`).
- **Modes** — shuffle, repeat (off/all/single), consume; changes mirror
  the server within ~2 s both directions (`R-05`).
- **Volume** — slider (server-verified), physical volume rocker in the
  foreground moves server volume by a configurable step (1–10, default
  5, persisted, applies to the next press without a restart), and the
  rocker is inert while backgrounded — it never hijacks server volume
  from the background (`R-06`, `R-14`).
- **Outputs** — speaker list matches the server; selection toggles use
  one full-set `PUT /api/outputs/set`, guarded by a "moving outputs
  redirects live audio" confirm while playing; per-output volume
  sliders (`R-09`).
- **Library** — Playlists, Artists, Albums, Genres; pagination beyond
  page 1 without duplicates; explicit empty states (`R-10`).
- **Queue** — list mirrors the server, exactly one "now playing"
  marker, tap-to-play, clear with confirm (`R-11`).
- **Ratings** — star display (server rating ÷ 20) and star taps
  persist to the server and update via websocket (`R-12`).
- **Search** — grouped Tracks/Artists/Albums results with per-group
  "Load more"; distinct idle / no-results / error / waiting-for-server
  states (`R-13`).
- **Call handling** — incoming call pauses playback; playback
  auto-resumes when the call ends unless the user paused it meanwhile
  (verified with emulator-simulated calls, `R-08`; the real-call pass
  is part of the GrapheneOS gate below).
- **Settings / About** — host/port persist and prefill; rocker-step
  setting; About screen with app version, live server version, and
  server build options (`R-14`).

## GrapheneOS setup

GrapheneOS does **not** auto-grant the legacy `INTERNET` permission, so a
stock install cannot reach the server until you allow it:

1. Install the release APK (`adb install app-release.apk` or your
   preferred sideload).
2. **Settings → Apps → OwnTone Remote → Network** → enable (per-app
   network permission). Without this the app shows connection errors.
3. Launch the app and grant the two runtime prompts:
   **Notifications** (`POST_NOTIFICATIONS` — the now-playing
   notification) and **Phone** (`READ_PHONE_STATE` — used only to
   listen for incoming calls so playback can pause/resume around
   them). Either can be denied; the rest of the app still works
   (call-pause stops working without Phone).
4. On the connection screen enter the server host (e.g.
   `192.168.1.13`) and port `3689` → Connect.

Battery optimization: the playback service runs as a
`mediaPlayback` foreground service (the type Android permits for media
playback), so it is exempt from background-start limits while playing.
If you want the now-playing notification and websocket sync to survive
indefinitely with the screen off, set the app to "Don't optimize" in
Settings → Apps → OwnTone Remote → Battery; it is not required for
normal remote use. (Observed on Android 16 AVDs; the GrapheneOS-specific
battery behaviour is recorded at the device gate — see below.)

## Known limitations

- **Debug-signed release APK.** `buildTypes.release` still uses the
  debug signing config; fine for sideload, not publishable.
- **Chromecast outputs** fail to select server-side on OwnTone 29.3
  (server-side issue) — AirPlay and ALSA outputs work; Chromecast
  selection is untested end-to-end because of it.
- **Silent network drops** (middlebox that kills the path without a
  TCP error) can leave the app showing `sync: live` until a request
  fails — the websocket has no app-level ping yet; hardening unit
  planned.
- **204 artwork** renders the placeholder correctly, but the
  caching layer logs the 204 as an exception (cosmetic log noise).
- **Process death** while paused is not spontaneously recovered: the
  audio service is `START_NOT_STICKY`, so the notification re-appears
  when you next open the app (which auto-reconnects).
- Server **auth (401)** and **PIN-protected outputs** are not
  exercisable on the reference server (no auth, no protected outputs);
  covered by tests only.

## GrapheneOS device gate — pending

The Pixel 10 (GrapheneOS) pass — real incoming call + auto-resume,
per-app network permission behaviour, FGS survival 10 min backgrounded
with screen off, real-device volume rocker, no-GMS crash check — is the
remaining step of `device-verification/003`. Until it runs, the rows
above marked "verified" are Android 16 (emulator) evidence; GrapheneOS
is expected to behave the same minus the GMS/permission differences
above.
