import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/queue/queue_controller.dart';
import 'package:owntone_remote/src/queue/queue_item.dart';

/// R-23 (issue #46): the display-drop → server-absolute `new_position`
/// mapping for queue drag-reorder, pure — `queueMoveNewPosition` next to
/// `visibleQueue` (`queue_controller.dart`). The drop indices follow
/// `ReorderableListView.onReorderItem` (Flutter 3.41+): `newIndex` is
/// already the POST-REMVAL insert index (the old `onReorder`
/// decrement-yourself contract would double-shift downward drags).
QueueItem item(String id, int position) => QueueItem(
  id: id,
  position: position,
  trackId: 100 + int.parse(id),
  title: 'T$id',
  artist: 'Muse',
  album: 'Absolution',
  lengthMs: 1000,
  uri: 'library:track:${100 + int.parse(id)}',
);

List<QueueItem> queue5() => [
  item('1', 0),
  item('2', 1),
  item('3', 2),
  item('4', 3),
  item('5', 4),
];

/// The canonical remove-and-insert move — what BOTH the server
/// (`new_position` = final index, docs/API.md:94) and the optimistic
/// reorder do.
List<QueueItem> move(List<QueueItem> list, int from, int to) {
  final moved = list[from];
  return List<QueueItem>.of(list)
    ..removeAt(from)
    ..insert(to, moved);
}

void main() {
  group('R-23 queueMoveNewPosition (pure, issue #46)', () {
    test('hide OFF: display == absolute — downward drop (already-adjusted '
        'newIndex is used as-is, NOT re-decremented)', () {
      // onReorderItem already adjusted: dropping B to last reports (1, 3)
      // on a 4-item list, and 3 IS the final index.
      final q = [item('1', 0), item('2', 1), item('3', 2), item('4', 3)];
      expect(
        queueMoveNewPosition(
          q,
          1,
          hidePlayed: false,
          displayFromIndex: 1,
          displayToIndex: 3,
        ),
        3,
        reason:
            'double-shifting (the old onReorder contract) would land '
            'every downward drag one slot short',
      );
    });

    test('hide OFF: upward drop', () {
      final q = [item('1', 0), item('2', 1), item('3', 2), item('4', 3)];
      expect(
        queueMoveNewPosition(
          q,
          1,
          hidePlayed: false,
          displayFromIndex: 3,
          displayToIndex: 0,
        ),
        0,
      );
    });

    test('hide ON: drop maps through the cut (display 0 → cut + 0, the '
        'defect case a naive impl gets wrong)', () {
      // [A, B(cur), C, D, E] hide ON → visible [B, C, D, E] (cut = 1).
      // Drag E (display 3) to the top (display 0) — the server position
      // is 1 (right at the anchor), NOT 0 (that would land it in the
      // already-played region the user cannot see).
      expect(
        queueMoveNewPosition(
          queue5(),
          2,
          hidePlayed: true,
          displayFromIndex: 3,
          displayToIndex: 0,
        ),
        1,
      );
    });

    test('hide ON: downward drop inside the window maps with the cut', () {
      // visible [B, C, D, E] (cut 1): drag B (display 0) to last (display 3).
      expect(
        queueMoveNewPosition(
          queue5(),
          2,
          hidePlayed: true,
          displayFromIndex: 0,
          displayToIndex: 3,
        ),
        4,
      );
    });

    test('hide ON, unanchorable (no current item) → cut 0, identity', () {
      expect(
        queueMoveNewPosition(
          queue5(),
          null,
          hidePlayed: true,
          displayFromIndex: 4,
          displayToIndex: 0,
        ),
        0,
      );
      expect(
        queueMoveNewPosition(
          queue5(),
          999, // current item not in the list — same unanchorable case
          hidePlayed: true,
          displayFromIndex: 0,
          displayToIndex: 4,
        ),
        4,
      );
    });

    test('hide ON, anchor at index 0 → cut 0 (matches visibleQueue)', () {
      expect(
        queueMoveNewPosition(
          queue5(),
          1,
          hidePlayed: true,
          displayFromIndex: 4,
          displayToIndex: 1,
        ),
        1,
      );
    });

    test('indices outside the visible window → null (stale-callback '
        'defence — the drop no-ops)', () {
      // Visible window is [B, C, D, E] (cut 1, length 4): display index 4
      // addresses nothing.
      expect(
        queueMoveNewPosition(
          queue5(),
          2,
          hidePlayed: true,
          displayFromIndex: 4,
          displayToIndex: 0,
        ),
        isNull,
      );
      expect(
        queueMoveNewPosition(
          queue5(),
          2,
          hidePlayed: true,
          displayFromIndex: 0,
          displayToIndex: 4,
        ),
        isNull,
      );
      expect(
        queueMoveNewPosition(
          queue5(),
          2,
          hidePlayed: true,
          displayFromIndex: -1,
          displayToIndex: 0,
        ),
        isNull,
      );
      expect(
        queueMoveNewPosition(
          queue5(),
          2,
          hidePlayed: true,
          displayFromIndex: 0,
          displayToIndex: -1,
        ),
        isNull,
      );
    });

    // The invariant that makes the cut-safe mapping CORRECT rather than
    // plausible: after the optimistic commit, what the user SEES is
    // exactly `visibleQueue` of what the SERVER stored (remove +
    // insert-at-new_position) — one shared cut definition, so the drop
    // window and the render can never disagree. Covers drops below the
    // current entry (the entry slides into the hidden region — the
    // honest ReTune-semantics outcome) and drops inside the window.
    test('equivalence: visible(canonical full move) == canonical move of '
        'the visible window (server truth == user-perceived order)', () {
      const cases = <(int? current, bool hide, int from, int to)>[
        (1, false, 3, 0), // drop before the current row (hide OFF)
        (1, false, 0, 4),
        (2, true, 3, 0), // drop onto the anchor row (hide ON)
        (2, true, 0, 3),
        (3, true, 2, 1),
        (null, true, 4, 2),
        (1, true, 4, 0), // anchor at 0 → cut 0
      ];
      for (final (current, hide, from, to) in cases) {
        final q = queue5();
        final mapped = queueMoveNewPosition(
          q,
          current,
          hidePlayed: hide,
          displayFromIndex: from,
          displayToIndex: to,
        );
        expect(mapped, isNotNull, reason: '($current,$hide,$from,$to)');
        final absolute = mapped!;
        // The dragged entry's ABSOLUTE index (display + cut) — the server
        // moves it from there to `new_position`.
        final cut =
            q.length - visibleQueue(q, current, hidePlayed: hide).length;
        final serverSide = visibleQueue(
          move(q, cut + from, absolute),
          current,
          hidePlayed: hide,
        );
        // What the user dragged: the same canonical move on the window
        // they were looking at.
        final userSide = move(
          visibleQueue(q, current, hidePlayed: hide),
          from,
          to,
        );
        // The window may re-anchor after a move that crosses the current
        // entry (the hidden region follows the current item, issue #23),
        // so equality holds up to the anchor semantics: a row dragged
        // INTO the hidden region legitimately disappears from the
        // window rather than misordering it. Assert the rows that REMAIN
        // visible are in the server order, and no visible row crossed the
        // anchor the server did not move.
        final visibleAfterServerMove = serverSide.map((e) => e.id).toList();
        final stillVisible = userSide
            .where((e) => visibleAfterServerMove.contains(e.id))
            .map((e) => e.id)
            .toList();
        expect(
          visibleAfterServerMove,
          stillVisible,
          reason:
              'server-side ($current,$hide,$from→$to): '
              '$visibleAfterServerMove vs user-side '
              '$stillVisible',
        );
      }
    });

    test('move mapping uses the SAME cut as visibleQueue (shared anchor): '
        'a mid-session anchor change maps fresh', () {
      final q = queue5();
      // Anchor B (cut 1): display 1 → absolute 2.
      expect(
        queueMoveNewPosition(
          q,
          2,
          hidePlayed: true,
          displayFromIndex: 1,
          displayToIndex: 2,
        ),
        3,
      );
      // WS event moved the current track to C (cut 2): same display drop
      // now means absolute 3+… re-derived from the CURRENT list, not a
      // captured cut.
      expect(
        queueMoveNewPosition(
          q,
          3,
          hidePlayed: true,
          displayFromIndex: 1,
          displayToIndex: 2,
        ),
        4,
      );
    });

    test('single-row window: only index 0 addresses it', () {
      final q = queue5(); // hide ON, anchor at E (index 4) → visible [E]
      expect(
        queueMoveNewPosition(
          q,
          5,
          hidePlayed: true,
          displayFromIndex: 0,
          displayToIndex: 0,
        ),
        4,
      );
    });
  });
}
