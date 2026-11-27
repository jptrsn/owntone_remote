# Release notes — OwnTone Remote 0.3.0

**Signing:** 0.1.0 was debug-signed; every release since **0.1.1** — including
this one — uses the project's dedicated release key, so installs from 0.1.1
or newer update **in place**. Only a device still on 0.1.0 must uninstall
once and reinstall (Android refuses a certificate change). Your server and
settings are untouched either way.

Release: built from tag `v0.3.0` by `release.sh` (gates green on this
commit: analyze 0 issues · format 0 changed · 696/696 tests;
**signed with the dedicated release keystore** — `release.sh` refuses to
publish debug-signed or foreign-signed APKs; a generated provenance
header with the build commit and artifact sizes is published above these
notes). Package `dev.educoder.owntone_remote`,
minSdk 26, targetSdk 36. Verified against OwnTone **29.3**
(JSON API `:3689`, websocket `:3688`).

## Changes in 0.3.0 (since 0.2.0)

Reliability fixes plus two user-facing features, each with its own build +
review record (cited PRs; device rows recorded in the cited PRs and
`.ai-dlc/` unit files):

- **Volume toaster** — a transient level bar appears on every screen except
  Now Playing when the physical rocker moves server volume (ReTune
  capture-22 parity; shows the resulting level, no accessibility node,
  auto-hides) (issue #92, PR #96).
- **Cold boot self-heals** — launching while the server is unreachable no
  longer strands you on a Retry tap: the error phase re-drives the connect
  on a recovery timer and walks itself to `connected` when the server
  returns (issue #93, PR #95).
- **Notification survives a slow server at launch** — the now-playing
  notification and media session are no longer permanently forfeited when
  the server answers later than the 10 s launch window; the wake is
  retried as soon as player state lands (issue #81, PR #88).
- **Head-unit / notification keys reach the server while paused** — the
  media session stays present with no local audio and no audio focus, and
  transport keys (play-pause, next, previous) from a Bluetooth head unit
  or the notification are forwarded to the server; debug builds also log
  each key arrival for diagnosis (issue #82, PR #89).
- **Connection screen: auto-discovery is the primary flow** — the mDNS
  scan leads the screen and manual host/port sits behind an **Advanced**
  affordance (it remains fully available) (issue #62, PR #75).
- **No fake transport when the server is stopped** — the media tile used
  to show working transport while the server was `stop`ped, but the
  server no-ops *next* and 500s *previous* in that state; the mirror now
  presents only the controls the server actually honours (issue #83,
  PR #87).
- **Volume control is foreground-only by design** — the session-exposed
  (cast / output-row) volume slider was removed: Android sessions imply
  *local* volume semantics, which this app does not own; the in-app
  server-volume surface is the foreground slider + rocker (issue #84,
  `R-06`/D20 decision).
- **Drawer red screen fixed** — the widget-library assertion
  ("Looking up a deactivated widget's ancestor is unsafe") witnessed
  around the drawer/Settings screens is resolved: the deferred page
  builder no longer reads providers on a popped route, and the NowPlaying
  → Server settings pre-fill is read at press time instead of inside the
  pushed route's builder (issues #64/#78, PRs #77, #80; device pass on
  the Pixel 6).

## What works

Verified on-device (Android 16/36 AVDs plus a stock-Android-17 real
device — a Pixel 6; full R-ID + reconnect passes by device-verification
units 001–002, release-build pass by unit 003, real-hardware pass by
unit 004, and per-feature device passes in the cited `remote-app`
units — see `.ai-dlc/device-verification/units/` and
`.ai-dlc/remote-app/units/`, plus the 0.1.1, 0.2.0 and 0.3.0 unit
passes above).
The silent-drop row was proven on-device in unit 009 (debug build; the
release build runs the identical dart:io `pingInterval` code path):

- **Connection** — auto-discovery leads the screen (LAN scan over mDNS
  with its own loading/timeout/error states and one-tap prefill,
  cancellable so a popped screen never keeps scanning); manual
  host/port sits behind **Advanced** and is never blocked;
  auto-reconnect on relaunch, and distinct errors for DNS failure vs
  refused port vs auth (`R-01`, `R-20`). A cold boot against a down
  server recovers on its own via the error-phase retry timer.
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
  from the caching layer at either fetch site; rating stars render on
  their own centred row below artist/album, and elapsed·slider·duration
  share the playhead row without the slider squeezing the labels;
  overflow offers **Go to Artist / Go to Album** into the track's
  browse context (`R-03`, `R-17`).
- **Transport & controls** — play/pause/next/previous, media-session
  (lock screen) and notification actions, all working with the app
  backgrounded (`R-04`; the backgrounded shade-tap is evidenced on
  dv-003's AVD — on the dv-004 Pixel 6 the shell media-key injection
  path is inert, so backgrounded control was not re-verifiable there,
  see the device gate below); a **persistent bottom mini transport bar**
  while a track is loaded (`R-22`).
- **Navigation** — ReTune-style **hamburger drawer on every main
  screen** (player identity, connection state, Queue/Outputs/Settings/
  About) (`R-21`); **Speakers app-bar action on every browse screen**
  (`R-18`).
- **Theme** — Light / Dark / Follow-system picker, persisted (`R-26`).
- **Notification** — one persistent `mediaPlayback` foreground-service
  notification with the current track and Play/Next/Previous actions;
  updates from websocket events; survives backgrounding; present while
  **paused** too — the media session stays active with no local audio and
  no audio focus, so genuine head-unit and notification transport keys
  forward to the server even between tracks (`R-07`; wake also survives a
  slow server at launch).
- **Modes** — shuffle, repeat (off/all/single), consume; changes mirror
  the server within ~2 s both directions (`R-05`).
- **Volume** — in-app server-volume slider (server-verified) plus the
  physical rocker in the foreground, which moves server volume by a
  configurable step (1–10, default 5, persisted, applies to the next
  press without a restart) and now pops a transient **volume toaster** on
  every screen except Now Playing; the rocker is inert while backgrounded
  — it never hijacks server volume from the background; there is
  deliberately **no session-exposed volume control** (no cast/row volume
  slider — Android sessions imply local-volume semantics this app does
  not own) (`R-06`/D20, `R-14`).
- **Outputs** — speaker list matches the server; multi-deselect is
  silent, deselecting the **only** selected output warns and on confirm
  stops playback (if playing); unselected outputs render their volume
  slider disabled-but-visible, following live websocket changes;
  selection toggles use one full-set `PUT /api/outputs/set` (`R-09`).
- **Library** — Playlists, Artists, Albums, Genres, and **Songs** (all
  tracks); alphabetical **section headers** on Artists/Genres/Songs;
  playlist/album detail offers **Play All / Shuffle / Play Next / Add
  to Up Next** (add-only paths never clear the queue); pagination
  beyond page 1 without duplicates; explicit empty states
  (`R-10`, `R-15`, `R-19`, `R-25`).
- **Queue** — list mirrors the server, exactly one "now playing"
  marker, **tap advances the queue in place** (no replacement), **long-
  press drag-reorder** committing a single server move (now-playing row
  inert), **per-row Remove and Play Next**, clear with confirm, and a
  pure-visibility "hide items played earlier" toggle; per-event
  refetches are **single-flight with a coalesced trailing refresh**, so
  overlapping server churn can't leave a stale count or an out-of-date
  list (`R-11`, `R-23`, `R-24`).
- **Ratings** — star display (server rating ÷ 20) and star taps
  persist to the server and update via websocket (`R-12`).
- **Search** — grouped Tracks/Artists/Albums results with per-group
  "Load more"; distinct idle / no-results / error / waiting-for-server
  states; **play taps switch the screen to Now Playing** (`R-13`).
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
   `192.168.1.13`) and port `3689` → Connect — or run the **scan** to
   find the server on the LAN (mDNS discovery needs the same network
   permission).

Battery optimization: the playback service runs as a
`mediaPlayback` foreground service (the type Android permits for media
playback), so it is exempt from background-start limits while playing.
If you want the now-playing notification and websocket sync to survive
indefinitely with the screen off, set the app to "Don't optimize" in
Settings → Apps → OwnTone Remote → Battery; it is not required for
normal remote use. (Observed on Android 16 AVDs, and on the stock
Android 17 Pixel 6 in dv-004: the `mediaPlayback` FGS carried audio +
websocket through a 10-min screen-off window with **no** battery-
optimisation exemption required; battery-Doze IDLE does not engage in a
10-min on-USB window. The GrapheneOS-specific battery behaviour is
recorded at the device gate — see below.)

## Known limitations

- **Chromecast outputs** fail to select server-side on OwnTone 29.3
  (server-side issue) — AirPlay and ALSA outputs work; Chromecast
  selection is untested end-to-end because of it.
- **Volume rocker works while the app screen is on**; with the screen
  off (or the app backgrounded) the rocker is deliberately **inert** —
  it never changes server volume from behind, at the cost of not
  acting as an in-pocket media rocker (R-06 design decision).
- **No-GMS verified statically, not on a GMS-less OS.** The app has
  zero Google/Play dependencies (Gradle + resolved pubspec), but every
  verification device so far — emulator images and the stock Pixel 6
  (dv-004) — ships `com.google.android.gms`; crash-free operation on a
  true no-GMS ROM (GrapheneOS, CalyxOS) is on the untested list below
  (its verification flash was declined by the owner on 2026-11-16).
- **Process death** while paused is not spontaneously recovered: the
  audio service is `START_NOT_STICKY`, so the notification re-appears
  when you next open the app (which auto-reconnects).
- Server **auth (401)** and **PIN-protected outputs** are not
  exercisable on the reference server (no auth, no protected outputs);
  covered by tests only.

## Device gate — verified (release build) + untested list

The release binary for the **0.1.x line** was device-verified twice —
those passes cover the unchanged code paths below. The 0.2.0 changes
were each device-verified per unit on a disposable AVD (overnight runs
of 2026-11-19/20; the audible-playback rows closed in the supervised
user-present Pixel 6 pass of 2026-11-20), and those records were
adjudicated by independent retroactive reviews on 2026-11-21 (correction
sweep in `docs/SESSION-LOG.md` + the cited PRs). The **0.3.0 delta** is
likewise record-backed per change: the auto-discovery-primary connection
flow had a Pixel 6 host device pass (round-3 approve, PR #75); the
drawer/settings crash fix closed with a Pixel 6 host pass; the stopped-
server transport, foreground-only-volume, launch-wake and key-forwarding
changes were observed on the Pixel 6 in host sessions on 2026-11-26/27
(raw `dumpsys media_session` records, `click(...)` log lines, and
server-side volume/item deltas on the cited PRs); the cold-boot
self-heal and the volume toaster carry their own unit device records in
`.ai-dlc/night-2026-11-27/`. The 0.3.0 release binary itself follows the
same policy as the 0.1.1/0.2.0 notes — UI-only deltas verified on
debug/unit builds, with the dv-003/004 release passes quoted here for
the unchanged runtime surface.

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

`device-verification/004` passed on 2026-11-16 on **real hardware** —
a Pixel 6 (`oriole`) running stock Android 17, release build (rebuilt
on `de1a627`, debug-signed): **FGS + notification survived 10 min
backgrounded with the screen off under the real battery manager** —
the device held `mWakefulness=Dozing` (screen-off sleep; deviceidle
stayed `mState=ACTIVE` — battery-Doze IDLE is not reached in a 10-min
on-USB window), `isForeground=true` and the same pid held, 0 crashes,
and the **websocket stayed established through the screen-off window**
(the device's per-uid background firewall does not starve an app with
an active `mediaPlayback` FGS); **cold-start auto-reconnect** (app
sockets to the server's websocket port within ~8 s of launch with no
user action); the **volume rocker on real hardware** (server-verified
per press-batch — 5 presses = ±25 at the default step 5 — inert while
backgrounded). Backgrounded **media-key** control was not re-verifiable
on the device (shell media-button injection is inert there — the app's
media session is quoted registered; the shade-control tap remains
evidenced on dv-003's AVD). Full evidence:
`.ai-dlc/device-verification/units/004-pixel6-real-hardware.md`.

Explicitly **untested on real hardware** (documented, not silently
dropped; all emulator-approximated or statically covered). Project-owner
decisions of 2026-11-16 (dv-004) are recorded against each item:

1. A **real carrier call** (the RIL/Telecom edge cases a simulated
   `gsm call` can't model — the app's `TelephonyCallback` path itself
   was exercised end-to-end on the emulator's Telecom layer, in both
   the debug and release passes). The test device carries a SIM but
   has **no voice service** (emergency-only registration), so a real
   inbound call cannot reach it; the owner accepted the emulated
   coverage rather than provisioning a line. This item therefore
   **stands as accepted-by-emulation** — still untested against a real
   carrier, re-open it if a callable device becomes available.
2. **GrapheneOS per-app Network permission** behaviour (the setup steps
   above are documentation, not a GrapheneOS-verified procedure).
   **Declined 2026-11-16**: verifying it requires flashing GrapheneOS,
   which wipes the only real test device; the owner opted to keep this
   documented-only.
3. **GrapheneOS battery-optimisation** specifics (FGS mediaPlayback is
   an AOSP-standard type — its survival through a 10-min screen-off
   window on stock Android 17 was verified in dv-004; battery-Doze
   IDLE itself was not engaged there either, and GrapheneOS's stricter
   enforcement was not exercised). **Declined 2026-11-16** (same flash
   decision).
   The same decision keeps **crash-free operation on a true no-GMS
   ROM** untested (the stock test device ships GMS).

The original release gate — a supervised pass on a Pixel 10 daily
driver under GrapheneOS — was retired by the project owner on
2026-11-13 in favour of the disposable-AVD pass above; items 1–3 above
are the owner's documented call of 2026-11-16, not dropped.
