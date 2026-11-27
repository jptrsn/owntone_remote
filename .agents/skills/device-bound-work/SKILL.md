---
name: device-bound-work
description: Rules for issues/PRs involving Android devices — AVDs/emulators, adb, the Pixel 6 test device, flutter run, on-device observation, or audio verification on the OwnTone server. Such steps are host-bound and must never be attempted by a sandboxed agent.
triggers:
  - adb
  - avd
  - emulator
  - pixel 6
  - flutter run
  - on-device
  - uiautomator
  - screencap
  - media notification
  - media key
  - playback
  - audio verification
---

Device-bound steps run ONLY in the opencode harness on the maintainer's
host (AGENTS.md § Maintenance model). In a sandboxed conversation:

- Never run `adb`, create or start an AVD/emulator, or touch the Pixel 6
  (`25071FDF600953`) or any `emulator-*` serial — they belong to other
  sessions (AGENTS.md § Hard rule 2).
- Never call the OwnTone server (`192.168.1.13`) with anything
  playback-capable; unattended audio-safety rules apply (AGENTS.md § Hard
  rule 1). Treat the server as at-most read-only GETs, and skip it
  entirely if unsure.
- Implement and verify everything hardware-free: fake-based unit/widget
  tests (`test/fakes/`), the four quality gates, code reading, docs-mcp
  checks (`owntone-server` for API facts).
- Record every hardware-dependent completion criterion as
  `BLOCKED-PENDING-HOST-VERIFICATION` in the PR body — action → expected
  observation → substitute hardware-free proof — and comment requesting
  the `needs-host-tools` label so the host session runs the device pass.
- If the issue cannot meaningfully proceed without device access (e.g.
  issue #64, whose red-screen capture needs a connected `flutter run`),
  stop early: comment what is needed, apply/ask for `needs-host-tools`,
  and return. Never fabricate device evidence — a green suite is not
  evidence of on-device behaviour.
