# Release notes — OwnTone Remote 0.1.0

Release candidate: `app-release.apk` 54.6 MB, built from `926a6be`
(`flutter build apk --release`, gates green: analyze 0 issues ·
format 0 changed · 421/421 tests). Package `dev.educoder.owntone_remote`,
minSdk 26, targetSdk 36. Verified against OwnTone **29.3**
(JSON API `:3689`, websocket `:3688`).

## What works

Verified on-device (Android 16/36 AVDs; full R-ID + reconnect passes by
device-verification units 001–002, release-build pass by unit 003, and
per-feature device passes in the cited `remote-app` units — see
`.ai-dlc/device-verification/units/` and `.ai-dlc/remote-app/units/`).
The silent-drop row was proven on-device in unit 009 (debug build; the
release build runs the identical dart:io `pingInterval` code path):

- **Connection** — host/port settings, auto-reconnect on relaunch, and
  distinct errors for DNS failure vs refused port vs auth (`R-01`).
- **Reconnect robustness** — offline banner in ~1.4 s of a hard network
  loss, reconnect backoff 1→2→4→8→16→30 s (capped), full refetch on
  reconnect, no notification duplication or state thrash under rapid
  flapping, and **silent drops detected in ~20 s** (tested bound ≤25 s) via a 10 s websocket
  ping/pong liveness check (a dead socket now fails into reconnect
  instead of leaving the app falsely `sync: live`) (`R-02`).
- **Now playing** — metadata + artwork (server-relative artwork URLs
  resolved against the webroot with `maxwidth`), progress follows the
  server, seek accurate to ≤50 ms; a **204 (no artwork) answer renders
  the placeholder as the normal case** — no exception or retry storm
  from the caching layer at either fetch site (`R-03`).
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
  marker, tap-to-play, clear with confirm; per-event refetches are
  **single-flight with a coalesced trailing refresh**, so overlapping
  server churn can't leave a stale count or an out-of-date list
  (`R-11`).
- **Ratings** — star display (server rating ÷ 20) and star taps
  persist to the server and update via websocket (`R-12`).
- **Search** — grouped Tracks/Artists/Albums results with per-group
  "Load more"; distinct idle / no-results / error / waiting-for-server
  states (`R-13`).
- **Call handling** — incoming call pauses playback; playback
  auto-resumes when the call ends unless the user paused it meanwhile
  (verified with emulator-simulated calls on both the debug and the
  **release** build — the release pass confirmed pause at the call and
  same-position auto-resume on cancel, user-confirmed audible, `R-08`;
  a real carrier call remains on the untested list below).
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
- **Volume rocker works while the app screen is on**; with the screen
  off (or the app backgrounded) the rocker is deliberately **inert** —
  it never changes server volume from behind, at the cost of not
  acting as an in-pocket media rocker (R-06 design decision).
- **No-GMS verified statically, not on a GMS-less OS.** The app has
  zero Google/Play dependencies (Gradle + resolved pubspec), but the
  emulator images used for verification ship `com.google.android.gms`;
  crash-free operation on a true no-GMS ROM (GrapheneOS, CalyxOS) is
  on the untested list below.
- **Process death** while paused is not spontaneously recovered: the
  audio service is `START_NOT_STICKY`, so the notification re-appears
  when you next open the app (which auto-reconnects).
- Server **auth (401)** and **PIN-protected outputs** are not
  exercisable on the reference server (no auth, no protected outputs);
  covered by tests only.

## Device gate — verified (release build) + untested list

`device-verification/003` passed on 2026-11-13: the release APK
(`926a6be`) on a **disposable Android 36 AOSP emulator** (created and
deleted by the unit; no GMS UI on the image). Verified in that pass:
install + permission grants, the full smoke (all rows above), the
**incoming-call pause + same-position auto-resume** through the
emulator's Telecom layer (user-confirmed audible), **FGS + notification
survival 10 min backgrounded with the screen off** (`isForeground=true`,
same pid, zero crashes, notification controls still working), the
server-verified volume rocker, and cold-start auto-reconnect. Full
evidence: `.ai-dlc/device-verification/units/003-release-pass-disposable-avd.md`.

Explicitly **untested on real hardware** (documented, not silently
dropped; all emulator-approximated or statically covered):

1. A **real carrier call** (the RIL/Telecom edge cases a simulated
   `gsm call` can't model — the app's `TelephonyCallback` path itself
   was exercised end-to-end).
2. **GrapheneOS per-app Network permission** behaviour (the setup steps
   above are documentation, not a GrapheneOS-verified procedure).
3. **GrapheneOS battery-optimisation** specifics (FGS mediaPlayback is
   an AOSP-standard type; GrapheneOS's stricter enforcement was not
   exercised).

The original release gate — a supervised pass on a Pixel 10 daily
driver under GrapheneOS — was retired by the project owner on
2026-11-13 in favour of the disposable-AVD pass above; real-hardware
items 1–3 stay open as a user-side check whenever convenient.
