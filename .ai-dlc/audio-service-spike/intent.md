---
workflow: default
git:
  change_strategy: unit
  auto_merge: false
  auto_squash: false
announcements: []
passes: []
active_pass: ""
iterates_on: ""
created: 2026-10-08
status: done
epic: ""
quality_gates:
  - { name: analyze, command: "flutter analyze" }
  - { name: format, command: "dart format --output=none --set-exit-if-changed ." }
  - { name: test, command: "flutter test --exclude-tags live" }
---

# Intent: audio-service-spike (Phase 1 — risk gate)

## Problem

The entire v1 value proposition (notification, lockscreen, volume rocker,
call handling) depends on a Flutter `audio_service` foreground service that
**mirrors remote server state instead of playing local audio**. Nobody has
verified that Android 16 keeps such a service alive, that remote volume
events reach it backgrounded, or that a Kotlin call channel can pause/resume
the *server*. If this is broken, the whole stack choice is wrong — so it is
tested first, before any UX work is built on top.

## Solution

Minimal Flutter app on the dev AVD (`RemoteDev_API_36`):
hardcoded `192.168.1.13:3689`, one now-playing screen (track + artwork +
controls + progress), `audio_service` handler fed by `GET /api/player` +
websocket, Kotlin platform channel stub for call state. No browsing, no
settings, no queue. ~2–3 days of work, deliberately ugly.

## Domain Model

- **PlayerState**: state (play/pause/stop), repeat, consume, shuffle,
  volume, item_id, item_length_ms, item_progress_ms, artwork_url
  (all from `GET /api/player`; see docs/API.md).
- **Data source**: OwnTone JSON API `http://192.168.1.13:3689` +
  websocket `ws://192.168.1.13:3688` (events: player, volume, outputs,
  queue, options).
- **Data gaps**: FGS survival in paused state (unknown → criterion 7);
  `mediaPlayback` FGS justification without local audio (unknown →
  criterion 7); remote-volume delivery while screen off (unknown →
  criterion 4).

## Success Criteria (intent-level)

- [ ] Unit 001 complete with all criteria verified (or NO-GO declared)
- [ ] Paused-state survival report written (feeds ARCHITECTURE.md)
- [ ] GO/NO-GO decision recorded in the session log; if NO-GO, a
      Kotlin+Media3 fallback plan is sketched before any other build work

## Context

- `audio_service` 0.18.x already proven in `~/Documents/owntone_sync` — but
  there it wraps `just_audio` **playing local files**. The remote-mirror
  mode (handler with no local media stream) is the new, untested part.
- The server is real and has speakers — **audio safety rule applies**
  (AGENTS.md §1). Criteria 3, 5 (play button), 6 need supervised windows.
- Flutter 3.41.7 / Dart 3.11.5; targetSdk 36, minSdk 26; no Play Services;
  cleartext HTTP on.
- Dev AVD does not exist yet — unit 001 creates it (commands in the unit).
  The other session's `emulator-5554` is never touched.
