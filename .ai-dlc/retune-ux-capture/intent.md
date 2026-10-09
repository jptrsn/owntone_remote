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
quality_gates: []   # gates are the DoD checklist in each unit + the intent DoD below
---

# Intent: retune-ux-capture (Phase 2)

## Problem

The app must match ReTune's UX (D6) — but ReTune is proprietary, closed,
iTunes-shaped, and half its surface is irrelevant to OwnTone. We need a
reliable, user-approved map of: which screens/flows matter, what each
action does, and which JSON API endpoint the new app uses instead.

## Solution

Capture on a dedicated **older** AVD (`Retune_API_33`, D13) with ReTune
sideloaded and **user-paired** to 192.168.1.13:

1. **Screen walk** — screencap + `uiautomator` hierarchy + notes per
   screen/state; navigation graph; run from the **paused** state (audio
   safety, D16).
2. **Static pass** — `apktool d` on the APK: strings, layouts,
   `preferences.xml`, DAAP path constants (mapping only, never
   implementation).
3. **Inventory** — every feature mapped to the JSON surface (or marked
   out/gap), OwnTone-only feature set enforced (AGENTS.md §5), pruned by
   the user.

Protocol: `docs/retune-capture/CAPTURE-PROTOCOL.md` (read it first).

## Domain Model

- **Screen**: name, elements, states (normal/empty/error/paused/playing),
  navigation edges. (Captured, not code.)
- **Feature**: user action → ReTune effect → JSON API endpoint (or gap).
- **Data source**: the running paired ReTune on the capture AVD (real
  library data) + the APK itself (static).
- **Data gaps**: playing-only states (supervised window required);
  error/offline states (need user-coordinated server stop, optional).

## Success Criteria (intent-level)

- [ ] All walk units' coverage tables complete and honest
- [ ] Static pass reconciled with the walk (no unexplained layouts)
- [ ] `feature-inventory.md`: every action → JSON mapping or explicit
      out/gap; zero iTunes-only features documented in depth
- [ ] **User has pruned + approved the inventory** (this is the intent gate)

## Context

- **Audio safety is the dominant constraint** (D16): real server, real
  speakers, possibly unattended. Walk from paused state only; never tap
  ReTune's play control without the user confirming that specific action;
  accidental playback → immediate API pause + incident log.
- **ReTune is read-only** (D17): the paired instance is the only working
  reference; no `pm clear`/uninstall/reinstall/settings changes.
- Device: `Retune_API_33` (Android 13, `google_apis`). The APK is pure
  Java (no native libs) — if it misbehaves on 33, fallback: API 34/35/36
  images on the same AVD concept (note the deviation in the session log).
- This intent is **independent of the spike** and may run in parallel
  (PLAN §10). Unit 001 pauses for the user (pairing).
