---
name: 003-pixel-10-grapheneos
status: pending
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

*(fill: smoke table, call-test transcript, dumpsys excerpt, checklist,
incidents — and the single most important line: server state at the end
of the window)*
