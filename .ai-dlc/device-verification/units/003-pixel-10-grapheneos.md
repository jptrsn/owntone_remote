---
name: 003-pixel-10-grapheneos
status: blocked
intent: device-verification
supervised_steps: [1, 2, 3]
---

# Unit 003 — Pixel 10 (GrapheneOS) release pass

## Goal

The final gate: the release build on the user's daily driver, under
GrapheneOS (stricter FGS + per-app permissions, no GMS), including the
one test no emulator can do: a **real incoming call**.

## Preconditions

- Unit 001 done (full pass, release APK built).
- User has the Pixel 10 connected + willing (daily driver — their call,
  their time). Record its serial in AGENTS.md.

## Steps (user-driven window; agent drives via `adb -s <pixel>` only
with the user's go-ahead)

1. `supervised: true` — install the release APK
   (`adb -s <s> install -r <release.apk>`); grant the **per-app Network
   permission** (GrapheneOS: Settings → Apps → OwnTone Remote → Network;
   no legacy auto-grant) + Notification permission.
2. `supervised: true` — connect (host 192.168.1.13), full smoke:
   now-playing display, pause/play (user-confirmed), prev/next,
   shuffle/repeat/consume, volume slider, browse one album, play one
   track (user-confirmed), queue, speakers list, rating display.
   **End paused + verified.**
3. `supervised: true` — **real call test**: user has the app playing
   (one approved start) → user calls the Pixel 10 (or gets a call) →
   playback pauses → call ends → auto-resume (user confirms) → user
   stops/pauses; final state paused + verified.
4. FGS/notification survival: background the app 10 min (screen off),
   notification + controls still work; `adb -s <s> shell dumpsys
   activity services | grep -A5 owntone` (evidence of FGS type).
5. Volume rocker on the Pixel 10 (screen off): ±5 master volume
   (paused — safe).
6. GrapheneOS checklist (record in Result): Network permission model,
   notification permission, FGS type accepted (`mediaPlayback`), no
   GMS dependency triggered any crash, battery-optimization behaviour
   note for the README.
7. Write the release notes fragment (what works, known limitations,
   GrapheneOS setup steps) into `docs/RELEASE-NOTES.md` (new file).

## Completion criteria

1. Release APK installed + permissions granted on GrapheneOS (evidence).
2. Full smoke pass (list above) — per-feature pass/fail in Result.
3. `supervised: true` — real call: pause → auto-resume verified; server
   left paused.
4. FGS + notification survive 10 min backgrounded (dumpsys evidence).
5. Rocker works on the real device (evidence: `/api/player` volume).
6. GrapheneOS checklist complete; `docs/RELEASE-NOTES.md` written.

## Result

**Status: BLOCKED — release gate not run.** 2026-10-27: agent was ready to
drive (all gates green, release APK built, server re-snapshot == baseline)
and asked the user to connect the Pixel 10; user answered **"Not today"**
(~16:03 EDT). The user is the supervisor for this unit and was not present,
so every device step is recorded below rather than improvised. Nothing was
installed, no device touched, no server mutation made.

### Steps 1–3 (supervised) — BLOCKED-PENDING-SUPERVISION

| Step | Status | Why |
|---|---|---|
| 1 install release APK + Network/Notification perms | BLOCKED-PENDING-SUPERVISION | Pixel 10 not connected; user absent |
| 2 full smoke (play/pause/prev/next/modes/volume/browse/queue/speakers/rating), end paused | BLOCKED-PENDING-SUPERVISION | requires user-confirmed audible window |
| 3 real call → pause → auto-resume | BLOCKED-PENDING-SUPERVISION | real call on the user's daily driver — user required |

### Steps 4–5 (unsupervised but device-bound) — BLOCKED (no device)

| Step | Status | Why |
|---|---|---|
| 4 FGS + notification survive 10 min backgrounded (dumpsys) | BLOCKED | needs the Pixel 10 |
| 5 volume rocker screen-off ±5 (server-verified) | BLOCKED | needs the Pixel 10 (paused-safe test, ready to run) |

### Step 6 — GrapheneOS checklist: PARTIAL (static done, on-device pending)

Static, from source (evidence):

- FGS type: `android:foregroundServiceType="mediaPlayback"` on
  `com.ryanheise.audioservice.AudioService` (`android/app/src/main/
  AndroidManifest.xml`) + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` permission.
  Accepted on Android 16 (dv-001 dumpsys `FOREGROUND` id 1124); GrapheneOS
  acceptance = pending device check.
- Permissions declared: `INTERNET, WAKE_LOCK, READ_PHONE_STATE,
  FOREGROUND_SERVICE, FOREGROUND_SERVICE_MEDIA_PLAYBACK,
  POST_NOTIFICATIONS` — exactly the remote's needs; no storage/location/
  contacts. `READ_PHONE_STATE` is used only by the TelephonyCallback call
  listener (`OwntoneRemotePlugin.kt`); denying it degrades only call-pause.
- Runtime prompts: app requests `POST_NOTIFICATIONS` (33+) +
  `READ_PHONE_STATE` at startup (`lib/main.dart:46` →
  `call_state.dart:31` `requestPermissions`).
- Per-app **Network** permission (GrapheneOS): documented in the setup
  steps (`docs/RELEASE-NOTES.md` § GrapheneOS setup); the actual
  grant/deny behaviour on the device = pending check.
- **No GMS dependency**: zero google/firebase/play artifacts in the Gradle
  build (`android/` clean of `play-services`/`firebase`/`google-services`)
  and zero matching packages in the resolved `pubspec.lock`
  (dio, web_socket_channel, audio_service 0.18.19, provider,
  shared_preferences, intl, logger). A no-GMS-crash *observation* on
  GrapheneOS = pending device check.
- Battery-optimization note: drafted in `docs/RELEASE-NOTES.md`
  (mediaPlayback FGS; "Don't optimize" optional for indefinite
  screen-off sync) — GrapheneOS-specific behaviour = pending check.

### Step 7 — `docs/RELEASE-NOTES.md` — DONE (this commit)

What-works (R-ID grouped, evidence-sourced to dv-001/002), GrapheneOS
setup steps (incl. per-app Network grant), known limitations (debug-signed
release, Chromecast server-side selection bug, silent-drop blind spot,
204-artwork log noise, `START_NOT_STICKY` recovery-on-relaunch, untested
401/PIN paths), and an explicit "GrapheneOS device gate — pending" section
so the notes cannot be mistaken for a completed device pass.

### Gate rows (run this session on clean HEAD `e765dcb`, `git status` 0 files)

| Gate | Result | Evidence |
|---|---|---|
| `flutter analyze` | PASS | `No issues found! (ran in 2.5s)` |
| `dart format --set-exit-if-changed` | PASS | `Formatted 78 files (0 changed)` |
| `flutter test --exclude-tags live` | PASS | `00:21 +362: All tests passed!` |
| `flutter build apk --release` | PASS | `app-release.apk` **52.9 MB** (Gradle 37.2 s) — release candidate for the window |
| `flutter build apk --debug` | PASS | `app-debug.apk` 189.9 MB |

### Server left as found (read-only session — GETs only, zero requests issued)

As found (start) and as left (16:05:38 EDT) are **identical**:

```
GET /api/player:   state=pause volume=0 item_id=197132 item_length_ms=211200 item_progress_ms=183144
GET /api/outputs:  selected [Volumio Kitchen (AirPlay 1, vol 0)]; Server ALSA unselected vol 8
GET /api/queue:    185 items, first 197130 'Skunk' (Thundersmack, Brass)
```

No external-session interference observed during the window. No
library/rating/playlist/output mutations, no playback (none possible — no
device), no rescan/update.

### Device policy compliance

- Pixel 10: never connected (user "not today"); AGENTS.md row stays
  "record when connected".
- No AVD was created this session (none of the executable steps needed
  one); nothing to delete. `adb devices -l` final: only foreign
  `emulator-5560` (`ZipCaptions_QA_API_36`, other session — untouched).

### dv-001 / dv-002 cross-reference

No on-device checks ran, so nothing shifted: dv-001's full R-ID table and
dv-002's reconnect rows stand unchanged. (The dv-001 "release APK
52.6 MB — not shipped; unit 003" row is now superseded by the 52.9 MB
build above — same artifact lineage, HEAD moved `6642bb4`→`e765dcb`.)

### Prepared for the device window (so it starts instantly)

1. User enables Developer options → Android debugging; record serial
   (AGENTS.md table) — verify it is the Pixel 10 before any `-s`.
2. `adb -s <serial> install -r build/app/outputs/flutter-apk/app-release.apk`
   → GrapheneOS Network permission → launch → 2 runtime prompts →
   Connect (host `192.168.1.13`, port 3689).
3. **First check on-device:** release-build semantics —
   `ensureSemantics()` is unconditional (`lib/main.dart:42`) but confirm
   content-desc lands in release before trusting any dump; per the
   a11y-bridge rule, validate the harness sees a known-present label
   before concluding absence, VM `evaluate_expression` (128-char chunks)
   as fallback.
4. Then steps 2→3→4→5; every audio moment user-confirmed; baseline to
   restore = the curl block above.

### Follow-ups (flagged only — no fix units opened, per instruction)

- **artwork-204**: cache-manager logs 204 as exception (cosmetic; open
  since dv-001).
- **R-02 hardening (dv-002)**: `WsClient` has no `pingInterval` / no
  ConnectivityManager listener → a silent network drop keeps the app
  falsely `sync: live`; small remote-app unit later (WS ping or periodic
  REST probe while connected).
