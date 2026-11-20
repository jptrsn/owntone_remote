---
title: "Queue: drag-reorder (tap-and-hold) via PUT queue move"
labels: enhancement, area:queue
---

## Change
The queue cannot be reordered anywhere — `QueueController` has only
`clear` / `playUris` / `skipToQueueItem` (`queue_controller.dart:147-180`);
`QueueScreen` renders a plain `ListView` (`queue_screen.dart:242`).
ReTune supports tap-and-hold drag reorder (first-entry dialog
"tap and hold to drag", `docs/retune-capture/16-up-next/`; drag
affordance verified visual-only on the Pixel 6, `23-playing-audit`).
OwnTone's server-side move exists and is unused by us:
`PUT /api/queue/items/{id}?new_position=N` (`docs/API.md:94`).
User decision 2026-11-19 (N-03).

## Expected
- `ReorderableListView` in `QueueScreen`; drag starts on long-press
  (ReTune gesture parity); commit fires on drop.
- `QueueController.moveItem(QueueItem item, int newIndex)` follows the
  existing `_action` pattern verbatim (`queue_controller.dart:182-212`):
  optimistic list reorder → PUT → on failure restore the pre-action list
  + typed `_describeActionError` snackbar + trailing post-commit refresh.
  Do **not** hand-roll a second refresh path — the single-flight +
  trailing-refresh contract (unit 011, `queue_controller.dart:103-143`)
  is what prevents the stale-queue clobbering this file's comments warn
  about.
- **Hide-played interaction** (#23): drag indices are *display* indices
  under `visibleQueue`'s cut. Map through the cut to absolute positions
  (pure function, unit-tested — next to `visibleQueue`), or disable drag
  while hide-played is ON. Pick the simpler **correct** option; the
  choice must be stated in the PR and covered by tests either way.
- The now-playing row is **not draggable** (OwnTone keeps the current
  entry fixed; verify live before locking the rule in).
- A WS `queue` event arriving mid-drag: keep the local drag order, let
  the post-commit refresh reconcile (document the behavior in a test).
- Drag handle gets a semantics label ("Reorder <title>"; ReTune's drag
  is a11y-invisible — do better).

## Where
`lib/src/ui/queue_screen.dart` (`_QueueList`), `lib/src/queue/queue_controller.dart`
(`moveItem`), `lib/src/api/owntone_api.dart` (`moveQueueItem(id, newPos)` —
verify exact param name live: `docs/API.md` says `new_position`), pure
index-mapping fn next to `visibleQueue` (`queue_controller.dart:264`).

## Requirements
R-23. Diff-list N-03.

## Repro / verification
Unit tests: index mapping incl. hide-cut (pure); `_action`-pattern
rollback on fake 500 (pattern already proven by clear's optimistic test).
Widget test: drive a drag, assert exactly one `PUT /api/queue/items/{id}
?new_position=N` with the mapped N on the fake API; now-playing row
inert. Live supervised manual once on the dev device (queue order
matches server after drag; web UI shows the same order). Gates green.
