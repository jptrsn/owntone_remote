---
name: 008-settings-extras
status: pending
intent: remote-app
supervised_steps: []
---

# Unit 008 — rocker-step setting + About screen (R-14)

R-IDs: R-14 (the two pieces that were never built; host/port persistence
already verified). Opened by device-verification unit 001, which
recorded the R-14 partial as FAIL → this unit; the table rows are
re-run afterwards.

## Goal

1. **Volume-rocker step size** becomes a real setting: today
   `lib/src/audio/mirror_handler.dart:90` has
   `static const rockerStep = 5` with `TODO(R-14)`. Persist an int
   (1–10, default 5) like the host/port prefs, read it in the mirror
   handler, expose it in Settings with immediate effect (no restart).
2. **About screen with server version** (name/version, server version
   + buildoptions from `GET /api/config`, app version from
   `package_info_plus` or pubspec constant — prefer no new dependency
   if the config + a compile-time const suffice).

## Steps / notes

- Step change applies to the *next* keypress while foregrounded;
  backgrounded behavior is untouched (R-06 invariants — never mirror
  while backgrounded).
- About is read-only; tapping server version re-fetches `/api/config`
  (shows the offline error state if unreachable).
- Tests: step persistence + applied value in handler mapping (1→±1,
  10→±10, clamping); About renders config fields + offline state; use
  `test/fakes/`.

## Completion criteria

1. R-14 acceptance rows verified on-device (own per-unit AVD or free
   `RemoteDev_API_36`; never another session's emulator): step=1 →
   rocker ±1 and step=10 → ±10 on the live server **while foregrounded,
   server stopped or paused** (volume-only — no playback), restored to
   default 5 afterwards.
2. Gates green + debug build.
3. device-verification/001 table R-14 rows updated with the new
   evidence.
4. SESSION-LOG entry + commit `remote-app/008: ...`.

## Result

*(fill)*
