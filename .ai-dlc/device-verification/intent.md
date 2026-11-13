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
and (unit 003) a supervised release-build pass on a disposable AVD —
including the incoming-call pause/auto-resume path driven through the
emulator's Telecom layer (`adb emu gsm call`).

## Solution

Three units, in order:

| # | Unit | Where |
|---|---|---|
| 001 | Full requirements pass | `RemoteDev_API_36` |
| 002 | Reconnect robustness | `RemoteDev_API_36` |
| 003 | Release pass | `OwnToneVerify003_API_36` (created + deleted by the unit) |

## Success Criteria (intent-level)

- [ ] Every v1 R-ID's acceptance criteria: pass/fail table recorded
- [ ] Reconnect scenarios: no crash, state converges to server truth
- [ ] 003: release APK install, FGS survival, rocker, **call pause +
      auto-resume (emulated call)** — all verified with the user
- [ ] Release APK built (`flutter build apk --release`) and recorded
- [ ] Untested-on-real-hardware items (real carrier call, GrapheneOS
      per-app Network permission, battery optimisation) explicitly
      documented — not silently dropped

## Context

- **Device decision (user, 2026-11-13):** the original 003 gated release
  on the user's Pixel 10 (GrapheneOS) daily driver; it never ran
  (BLOCKED-PENDING-SUPERVISION, 2026-10-27) and the user replaced it with
  the disposable-AVD plan. The superseded GrapheneOS/static/gate evidence
  is preserved in the unit file; real-hardware-only checks stay documented
  as untested.
- 003 still needs the **user present** for its audible window — the
  emulator does not change D16/AGENTS §1; every start is confirmed.
- Everything that plays audio is supervised (D16). The full pass includes
  play — it happens in one agreed window, and the server is left paused.
