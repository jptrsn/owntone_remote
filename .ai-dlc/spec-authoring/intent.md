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
quality_gates: []   # gate = user review of the four docs
---

# Intent: spec-authoring (Phase 3)

## Problem

The build phase must not re-derive decisions: it needs four final,
cross-referenced documents — requirements with verifiable acceptance
criteria, screen-by-screen Material 3 spec, the spike-validated
architecture, and the verified API subset.

## Inputs

- Spike: `.ai-dlc/audio-service-spike/units/001-spike-app.md` `## Result`
  (GO/NO-GO + paused-state survival report). **If NO-GO, this intent is
  aborted** — the stack decision comes back to the user first.
- Capture: `docs/retune-capture/feature-inventory.md` (**pruned +
  approved** — unit 004 gate met) + navigation.md + screen captures.
- Seeds: `docs/REQUIREMENTS.md` v0.1, `docs/ARCHITECTURE.md` v0.1,
  `docs/API.md`.
- PLAN.md §2 (all D-decisions) — nothing here may contradict a recorded
  decision; new decisions get a new D-number in PLAN.md §2.

## Outputs (all in docs/)

1. **REQUIREMENTS.md (final)** — every v1 feature, R-ID, priority,
   verifiable acceptance criteria; scope-out table; N-constraints.
2. **SCREENS.md (new)** — per screen (from pruned inventory + nav graph):
   Material 3 layout description, elements, actions → endpoint,
   navigation edges, states (loading / empty / error / offline),
   edge cases (long titles, no artwork, huge lists).
3. **ARCHITECTURE.md (final)** — spike findings integrated (FGS design,
   remote volume, call channel), provider contract locked, state flow,
   error/offline policy, testing strategy.
4. **API.md (verified)** — every endpoint the app will call, marked
   verified-live where exercised; anything unverified flagged.

## Success Criteria (intent-level)

- [ ] All four docs finalized, cross-referenced (R-ID ↔ screen ↔ endpoint)
- [ ] Every v1 requirement has ≥1 acceptance criterion that a test or a
      supervised device check can verify
- [ ] No screen in SCREENS.md without an endpoint mapping (or explicit
      local-only behaviour)
- [ ] **User review pass recorded** (this is the intent gate)

## Context

- This is a HITL documentation intent: no code, no device work (except
  optionally re-running a couple of unverified API calls read-only).
- Decisions made here (browse depth, queue reorder, license/name) are
  recorded as new D-numbers in PLAN.md §2 + session log.
