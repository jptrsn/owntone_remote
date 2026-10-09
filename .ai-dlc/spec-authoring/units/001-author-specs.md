---
name: 001-author-specs
status: pending
intent: spec-authoring
supervised_steps: [3]
---

# Unit 001 — write the four final docs

## Preconditions

- Spike GO (unit 001 result). If NO-GO → stop, report, abort intent.
- Inventory pruned + approved (capture unit 004 result).

## Steps

1. Finalize `REQUIREMENTS.md`: keep R-IDs; rewrite acceptance criteria to
   be verifiable; fold in pruned-scope changes (S7/S8/S10 depth);
   add/remove R-IDs as the inventory demands (renumbering forbidden).
2. Write `docs/SCREENS.md` from the inventory + nav graph + capture
   screenshots: Material 3 idioms (nav rail? bottom bar? sheet for now
   playing? — decide here, cite the ReTune flow being mirrored), elements
   and actions per screen, states, edge cases.
3. Finalize `ARCHITECTURE.md`: integrate the spike survival report (FGS
   type, notification recovery path), lock the `MusicProvider` contract
   (methods the SCREENS.md actually need — no speculative API surface),
   confirm error/offline policy, confirm test layout.
4. Finalize `API.md`: mark every endpoint used (verified-live where
   exercised during the spike; read-only re-checks allowed for the rest —
   never a playback trigger).
5. Cross-reference sweep: every R-ID ↔ SCREENS.md section ↔ API.md
   endpoint; fix dangling references.
6. Record new decisions as D-numbers in PLAN.md §2 (+ session log).
7. `supervised: true` — **user review**: walk the four docs with the user
   (screen-by-screen for SCREENS.md); record decisions verbatim; flip
   docs to `status: final`.

## Completion criteria

1. REQUIREMENTS.md final: all v1 features, verifiable acceptance criteria,
   no dangling scope.
2. SCREENS.md written: every in-v1 screen spec'd with states + endpoints.
3. ARCHITECTURE.md final: spike findings integrated; provider contract
   locked.
4. API.md: every called endpoint listed + verification status.
5. Cross-reference sweep clean (spot-check 5 R-IDs end-to-end).
6. `supervised: true` — user review recorded verbatim in `## Result`;
   docs marked final.

## Result

*(fill: decisions made (D-numbers), user review notes, doc list with
final status)*
