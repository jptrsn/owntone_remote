---
title: "Queue rows need per-row Remove (and Play Next) — today only clear-all exists"
labels: enhancement, area:queue
---

## Change
The queue offers one destructive hammer only: clear-all with a confirm
(`queue_screen.dart:124-129`, `QueueController.clear`
`queue_controller.dart:150-154`). There is no way to drop one item.
ReTune's queue row accessory opens a popup menu **Play Next · Remove**
(machine-verified on the Pixel 6 with the player paused — zero audio
requests in logcat; `docs/retune-capture/23-playing-audit/notes.md`
A3; the list-header accessory is `Clear`, which the new app already has).
User decision 2026-11-19 (N-04).

## Expected
Per-row actions on `QueueScreen` rows (popup menu or `Dismissible` —
whichever matches the M3 language; the now-playing row is excluded for
both):
- **Remove** → `QueueController.removeItem(QueueItem)` —
  `DELETE /api/queue/items/{id}` (`docs/API.md:95`, 204) through the
  `_action` pattern (`queue_controller.dart:182-212`): optimistic splice,
  rollback + typed snackbar on failure, trailing post-commit refresh
  (single-flight/unit 011 contract — same warning as the reorder issue).
- **Play Next** → insert ahead of the current next item:
  `POST /api/queue/items/add?uris=<this row's uri>&position=<current+1>`
  **without `clear`** — verify the exact position/param semantics live
  (`docs/API.md:93` lists `position`; the webplayer JS read on 2026-11-19
  is the reference implementation). Reuses the track's `uri` field;
  a queued row's Play Next moves semantics (remove+insert vs insert-copy)
  must be decided live and recorded — ReTune's row copy is the safe
  default.
- Menu items get tooltips + semantics labels (ReTune's CheckedTextView
  popup exposes text but no actionable a11y — do better).
- Swipe-to-dismiss may implement Remove **instead of** a visible
  accessory only if row taps keep working unchanged (row tap =
  skip-in-place per #21 — must not regress).

## Where
`lib/src/ui/queue_screen.dart` (`_queueRow`),
`lib/src/queue/queue_controller.dart` (`removeItem`, `playNext`),
`lib/src/api/owntone_api.dart` (`deleteQueueItem`, `addUris` position
support — `playUris` today hardwires clear+start per its doc-comment;
add the non-clear variant without touching that method's contract).

## Requirements
R-24. Diff-list N-04.

## Repro / verification
Unit tests capture the exact endpoints/params on the fake API (DELETE
path+id; add WITHOUT `clear=true`, correct `position`); optimistic
remove + rollback on fake 500; now-playing row exposes neither action
(or they're disabled); hide-played interplay (removing above the cut).
Supervised manual once (remove a queued item while playing; server web
UI shows the same list after). Gates green.
