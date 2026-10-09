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
status: planned
epic: ""
quality_gates:
  - { name: analyze, command: "flutter analyze" }
  - { name: format, command: "dart format --output=none --set-exit-if-changed ." }
  - { name: test, command: "flutter test --exclude-tags live" }
---

# Intent: device-verification (Phase 5)

## Problem

"Builds and passes unit tests" is not "works as a remote". v1 is proven
by a full requirements pass on the dev AVD, a reconnect-robustness pass,
and a supervised pass on the real Pixel 10 (GrapheneOS) — the only device
that can test a real incoming call.

## Solution

Three units, in order:

| # | Unit | Where |
|---|---|---|
| 001 | Full requirements pass | `RemoteDev_API_36` |
| 002 | Reconnect robustness | `RemoteDev_API_36` |
| 003 | Pixel 10 GrapheneOS (release build) | Pixel 10, user-driven |

## Success Criteria (intent-level)

- [ ] Every v1 R-ID's acceptance criteria: pass/fail table recorded
- [ ] Reconnect scenarios: no crash, state converges to server truth
- [ ] Pixel 10: install, per-app Network permission, FGS survival,
      rocker, **real call + auto-resume** — all verified with the user
- [ ] Release APK built (`flutter build apk --release`) and recorded

## Context

- The Pixel 10 is the user's **daily driver** — unit 003 is entirely at
  the user's convenience, with the user holding the device; the agent
  drives via `adb -s <pixel-serial>` only when the user has it connected
  and has agreed.
- GrapheneOS specifics (unit 003): per-app Network permission must be
  granted manually (no legacy auto-grant); check the notification
  permission too; FGS type enforcement is stricter than AOSP.
- Everything that plays audio is supervised (D16). The full pass includes
  play — it happens in one agreed window, and the server is left paused.
