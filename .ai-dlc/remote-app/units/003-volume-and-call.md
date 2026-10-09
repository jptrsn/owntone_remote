---
name: 003-volume-and-call
status: pending
intent: remote-app
supervised_steps: [3, 4]
---

# Unit 003 — volume rocker + call handling (pause / auto-resume)

R-IDs: R-06, R-08. The two "system integration" features.

## Goal

Hardware volume rocker → master volume (step), screen off + backgrounded.
Incoming call → pause server; call end → auto-resume **only if the app
paused for the call** (pause-origin tracking, R-08).

## Steps / notes

- Rocker: `RemoteAndroidPlaybackInfo(max: 100, current: v)` published on
  every volume change; `androidAdjustRemoteVolume` →
  `PUT /api/player/volume?step=±N` (default N=5, configurable in
  settings per R-14 — add the setting here if R-14 is in scope for the
  unit order; otherwise hardcode 5 + TODO).
- Call channel: Kotlin `TelephonyCallback` (API 31+; `TelephonyManager`),
  events → `call_state` stream. `PlayerController`:
  - `ringing|offhook` while `state == play` → `pause()`,
    `pauseOrigin = call`;
  - `idle` → if `pauseOrigin == call` → `resume()` (playback=start via
    `PUT /api/player/play` — **supervised**);
  - user pause sets `pauseOrigin = user` → never auto-resumed.
- Edge cases (unit tests): call during pause (no-op), call during
  `state == stop` (no resume), call ends before pause ack (debounce
  window), multiple ringing/idle flaps (ignore flaps <500 ms).
- Tests: pause-origin state machine (all edges above), channel event
  mapping (mock MethodChannel), rocker step math.

## Completion criteria

1. Rocker up/down changes master volume ±5 with **screen off + app
   backgrounded** (evidence: `GET /api/player` volume before/after,
   timestamped). *(safe while paused)*
2. Slider and rocker stay in sync (WS volume events).
3. `supervised: true` — simulated call (emulator Extended Controls →
   Phone → dial) while playing (user-approved play) → server `pause`;
   call ends → server `play` (auto-resume).
4. `supervised: true` — user-pause case: pause manually, simulate call,
   call ends → **still paused**.
5. Edge-case unit tests pass (flaps, call-while-paused, stop state).
6. Gates pass.

## Result

*(fill: rocker evidence, call-test transcripts (logcat/channel events),
gate output, incidents — call tests are the most likely to play audio:
pause + verify after each)*
