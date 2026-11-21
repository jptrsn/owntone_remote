import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../player/player_controller.dart';
import '../queue/queue_controller.dart';
import '../queue/queue_item.dart';
import 'app_drawer.dart';
import 'browse_rows.dart';
import 'browse_screen_scaffold.dart';
import 'list_states.dart';

/// The queue screen (R-11, unit 005b): rows in server order, the
/// now-playing row highlighted via `PlayerState.itemId` (which is the
/// queue-entry `id` — verified live), a clear action, and tap-to-skip —
/// tapping a row advances the queue in place (issue #21), it never
/// re-adds or clears.
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  QueueController? _snackController;
  int _seenActionErrorSeq = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_snackController != null) return;
    final c = context.read<QueueController>();
    _snackController = c;
    _seenActionErrorSeq = c.actionErrorSeq;
    c.addListener(_onActionError);
  }

  /// A failed clear / play rolls the UI back (QueueController) and surfaces
  /// a snackbar with the typed error.
  void _onActionError() {
    final c = _snackController;
    if (c == null) return;
    if (c.actionErrorSeq != _seenActionErrorSeq) {
      _seenActionErrorSeq = c.actionErrorSeq;
      final message = c.actionError;
      if (message != null && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  @override
  void dispose() {
    _snackController?.removeListener(_onActionError);
    super.dispose();
  }

  /// Clearing is destructive (the live library's queue can hold hundreds of
  /// items) — confirm before `PUT /api/queue/clear`.
  Future<void> _confirmClear(BuildContext context) async {
    final queueController = context.read<QueueController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear the queue?'),
        content: const Text('This removes every queued item.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await queueController.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final queueController = context.watch<QueueController>();
    final player = context.watch<PlayerController>();
    final enabled = conn.phase == ConnectionPhase.connected;
    final nowPlaying = findNowPlaying(
      queueController.queue,
      player.player?.itemId,
    );
    // Issue #23: the hide toggle is a pure view filter — this is the whole
    // "action". No controller call, no API touch; recomputed on every build
    // so a WS queue/player event re-anchors the cut automatically. Stays
    // pressable while offline (it touches nothing on the server).
    final items = visibleQueue(
      queueController.queue,
      player.player?.itemId,
      hidePlayed: queueController.hidePlayedItems,
    );

    return BrowseScreenScaffold(
      title: 'Queue',
      drawer: const AppDrawer(selected: DrawerDestination.queue),
      offlineMessage: 'Server unreachable — retrying. Queue disabled.',
      actions: [
        IconButton(
          tooltip: queueController.hidePlayedItems
              ? 'Show items played earlier'
              : 'Hide items played earlier',
          icon: Icon(
            queueController.hidePlayedItems
                ? Icons.visibility_off
                : Icons.visibility,
          ),
          onPressed: () => queueController.hidePlayedItems =
              !queueController.hidePlayedItems,
        ),
        IconButton(
          tooltip: 'Clear queue',
          icon: const Icon(Icons.delete_sweep),
          onPressed: enabled && queueController.queue.isNotEmpty
              ? () => _confirmClear(context)
              : null,
        ),
      ],
      body: _QueueList(
        controller: queueController,
        items: items,
        enabled: enabled,
        nowPlayingId: nowPlaying?.id,
        nowPlayingItemId: player.player?.itemId,
        // Issue #21: a queued row is already in the queue — tapping it
        // skips in place (queue content unchanged), it must NOT re-add
        // with clear+playback=start (that replaced the whole queue).
        onSkip: (item) => unawaited(queueController.skipToQueueItem(item)),
        // R-24 (issue #47) per-row actions. The position is computed from
        // the LIVE controller state at tap time (same live-read split as
        // the drag's drop mapping — a build-time capture would go stale
        // under a WS queue event).
        onPlayNext: (item) => unawaited(
          queueController.playNext(
            item,
            position: queuePlayNextPosition(
              queueController.queue,
              player.player?.itemId,
            ),
          ),
        ),
        onRemove: (item) {
          // PR #60 retroactive review minor: the menu is gated at BUILD
          // time, so a popup left open across a track advance could DELETE
          // the (newly) now-playing entry — whose server-side semantics are
          // deliberately unprobed. Live re-read at selection time (same
          // pattern as onPlayNext's position).
          final current = findNowPlaying(
            queueController.queue,
            player.player?.itemId,
          );
          if (current?.id == item.id) return;
          unawaited(queueController.removeItem(item));
        },
      ),
    );
  }
}

class _QueueList extends StatefulWidget {
  const _QueueList({
    required this.controller,
    required this.items,
    required this.enabled,
    required this.nowPlayingId,
    required this.nowPlayingItemId,
    required this.onSkip,
    required this.onPlayNext,
    required this.onRemove,
  });

  final QueueController controller;

  /// The rows to render — the (possibly hide-cut, issue #23) view of
  /// `controller.queue` computed by the parent on every build.
  final List<QueueItem> items;
  final bool enabled;
  final String? nowPlayingId;

  /// `PlayerState.itemId` — the anchor [queueMoveNewPosition] needs to
  /// re-derive the hide-cut at drop time (the same source the parent's
  /// `visibleQueue` call used to build [items]).
  final int? nowPlayingItemId;

  /// Row tap (issue #21): advance the queue in place to [item] —
  /// `QueueController.skipToQueueItem`, never `playUris`.
  final void Function(QueueItem item) onSkip;

  /// R-24 (issue #47) row-menu actions: insert a COPY of [item] after the
  /// current entry / delete [item]. Never offered on the now-playing row
  /// (no menu at all — R-24; the server-side now-playing delete is
  /// deliberately unprobed on the shared fixture).
  final void Function(QueueItem item) onPlayNext;
  final void Function(QueueItem item) onRemove;

  @override
  State<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<_QueueList> {
  /// R-23 mid-drag contract (issue #46): while a drag is live the list is
  /// FROZEN at the items the user grabbed. Two independent reasons:
  ///  1. Flutter 3.47.9 trips its per-item GlobalKey ("Duplicate GlobalKey
  ///     detected") when a refetch rebuilds the sliver while the overlay
  ///     proxy holds the dragged child;
  ///  2. R-23 itself: a WS `queue` event arriving mid-drag must NOT yank
  ///     the row out from under the finger — the drag keeps its LOCAL
  ///     order and the [_action]-trailing post-commit refresh reconciles
  ///     afterwards (pinned by the issue-#46 widget test).
  /// Both the parent-driven rebuild (identical cached widget) and the
  /// `itemBuilder` closure (frozen items — the sliver re-invokes it on
  /// every internal drag frame) must be frozen, or the rebuild slips
  /// through anyway. Released by `onReorderEnd` (fires on same-place
  /// drops too) and defensively in `onReorderItem`. Known exotic
  /// limitation: a SYSTEM-cancelled drag (pointer takeover) fires neither
  /// callback; the list then unfreezes on the next drag or a revisit.
  bool _dragging = false;
  Widget? _lastBuilt;
  List<QueueItem>? _frozenItems;
  Timer? _unfreezeTimer;

  List<QueueItem> get _rendered => _frozenItems ?? widget.items;

  void _beginDragGate() {
    // NO setState here: the drag-start frame must stay the sliver's own
    // (supported) update — replacing the ReorderableListView *instance* in
    // that very frame makes the overlay's reparented child orphan its
    // still-listed row elements (duplicate-GlobalKey at finalize). The
    // freeze works by NEVER handing the element a new instance while
    // dragging (`_queueListView` returns `_lastBuilt`).
    _unfreezeTimer?.cancel(); // a stale safety timer must not unfreeze
    _dragging = true; // mid-drag
    _frozenItems = widget.items;
  }

  void _endDragGate() {
    _unfreezeTimer?.cancel();
    if (!_dragging && _frozenItems == null) return;
    setState(() {
      _dragging = false;
      _frozenItems = null;
    });
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(covariant _QueueList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_rebuild);
      widget.controller.addListener(_rebuild);
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _unfreezeTimer?.cancel();
    widget.controller.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;

    if (c.hasLoaded && c.syncError != null && c.queue.isNotEmpty) {
      // A failed refetch keeps the stale rows; the strip says so.
      return Column(
        children: [
          _SyncErrorStrip(message: c.syncError!),
          Expanded(child: _queueListView(context, c)),
        ],
      );
    }
    if (!c.hasLoaded) {
      if (c.syncError != null) {
        // The first fetch failed: the full error state.
        return Center(
          child: ListErrorState(
            what: 'the queue',
            message: c.syncError!,
            enabled: widget.enabled,
            onRetry: c.refresh,
          ),
        );
      }
      if (!widget.enabled) {
        return const Center(child: Text('Waiting for the server…'));
      }
      return const ListSkeletonRows();
    }
    if (widget.items.isEmpty) {
      return const Center(
        child: ListEmptyState(
          message: 'The queue is empty.',
          icon: Icons.queue_music,
        ),
      );
    }
    return _queueListView(context, c);
  }

  /// R-23 (issue #46): the queue is reorderable — long-press-drag (ReTune's
  /// "tap and hold to drag", `16-up-next`) commits on drop.
  /// `ReorderableDelayedDragStartListener` is the load-bearing choice: the
  /// plain `ReorderableDragStartListener` starts the drag IMMEDIATELY on
  /// pointer-down in this Flutter (3.47.9), which would steal row taps and
  /// list scrolls; the delayed variant waits out the long-press timeout
  /// (ReTune parity). `buildDefaultDragHandles: false` + the handle only on
  /// draggable rows is what makes the **now-playing row inert** (R-23:
  /// OwnTone keeps the current entry fixed — no handle to grab ⇒ no drag,
  /// no request). `onReorderItem` (not the deprecated `onReorder`) hands
  /// drop indices already adjusted for the removed item —
  /// [queueMoveNewPosition] maps them through the hide-cut to the
  /// server-absolute `new_position`; the optimistic reorder + rollback +
  /// trailing refresh all live in `QueueController.moveItem` (the unit-011
  /// single-flight contract — never hand-roll a refresh here). A WS
  /// `queue` event arriving mid-drag rebuilds the list under the overlay;
  /// the drag keeps its local order and the post-commit refresh
  /// reconciles (documented by the issue-#46 widget test).
  ///
  /// Flutter 3.47.9 has no `separatorBuilder` on `ReorderableListView` —
  /// the row gap is baked in as each item's bottom padding (with the list
  /// bottom padding zeroed), byte-equivalent to the old `ListView
  /// .separated` geometry.
  Widget _queueListView(BuildContext context, QueueController c) {
    if (_dragging && _lastBuilt != null) return _lastBuilt!;
    final items = _rendered;
    final list = ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      itemCount: items.length,
      buildDefaultDragHandles: false,
      onReorderStart: (int index) => _beginDragGate(),
      onReorderEnd: (int index) {
        // Fires on the RAW drop (even same-place) — ~250 ms before the
        // drop-back animation finishes and `_dragReset` removes the proxy.
        // Unfreezing HERE (or earlier) collides with the live proxy on any
        // changed row set (duplicate GlobalKey). The common path unfreezes
        // one frame after `onReorderItem`; this timer covers the rest
        // (same-place drops never call `onReorderItem`).
        _unfreezeTimer?.cancel();
        _unfreezeTimer = Timer(const Duration(milliseconds: 500), _endDragGate);
      },
      onReorderItem: (int oldIndex, int newIndex) {
        final dragged = items;
        // One frame of deferral, for a reason: the framework calls
        // `onReorderItem` BEFORE its own `_dragReset` (the overlay-proxy
        // teardown) in the same frame — unfreezing and firing the
        // optimistic notify HERE lands the rebuilt row set in the same
        // finalizeTree as the still-mounted proxy (the duplicate-
        // GlobalKey assertion). The next frame sees the proxy gone.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _endDragGate(); // before the optimistic notify — let it render
          if (oldIndex < 0 || oldIndex >= dragged.length) return;
          final item = dragged[oldIndex];
          // The cut is re-derived from the LIVE controller list: a
          // mid-drag refetch may have shifted the anchor — that is the
          // documented reconciliation trade (the trailing refresh
          // settles the truth).
          final absolute = queueMoveNewPosition(
            c.queue,
            widget.nowPlayingItemId,
            hidePlayed: c.hidePlayedItems,
            displayFromIndex: oldIndex,
            displayToIndex: newIndex,
          );
          if (absolute == null) return;
          unawaited(c.moveItem(item, absolute));
        });
      },
      itemBuilder: (context, i) {
        final item = _rendered[i]; // frozen while dragging (see above)
        return Padding(
          key: ValueKey(item.id),
          padding: const EdgeInsets.only(bottom: 8),
          child: _queueRow(context, item, i),
        );
      },
    );
    _lastBuilt = list;
    return list;
  }

  Widget _queueRow(BuildContext context, QueueItem item, int index) {
    final theme = Theme.of(context);
    final isNowPlaying = item.id == widget.nowPlayingId;
    final secondary = [
      item.artist,
      item.album,
    ].where((s) => s.isNotEmpty).join(' · ');
    return Semantics(
      container: true,
      label:
          '${item.title}'
          '${isNowPlaying ? ', now playing' : ''}'
          '${secondary.isEmpty ? '' : ', $secondary'}',
      child: Material(
        color: isNowPlaying
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: widget.enabled ? () => widget.onSkip(item) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                if (isNowPlaying) ...[
                  Icon(
                    Icons.play_arrow,
                    size: 20,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        style: theme.textTheme.titleMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (secondary.isNotEmpty)
                        Text(
                          secondary,
                          style: theme.textTheme.labelSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatTrackLength(item.lengthMs),
                  style: theme.textTheme.labelSmall,
                ),
                // R-23 drag handle (issue #46): absent on the now-playing
                // row (it must stay inert — no handle to grab) and while
                // offline (row taps are gated the same way). The semantics
                // label is ours — ReTune's drag is a11y-invisible (23
                //-playing-audit); "Reorder <title>" is the R-23 contract.
                if (!isNowPlaying && widget.enabled) ...[
                  const SizedBox(width: 8),
                  Semantics(
                    label: 'Reorder ${item.title}',
                    child: ReorderableDelayedDragStartListener(
                      index: index,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.drag_handle,
                          size: 20,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  // R-24 (issue #47): ReTune's row accessory popup
                  // (Play Next · Remove — 23-playing-audit A3, verified
                  // with the player paused). PopupMenuButton is the
                  // repo's M3 overflow precedent (browse_screens.dart);
                  // swipe-to-dismiss was rejected because proving
                  // row-tap-skip-in-place (#21) survives the Dismissible
                  // gesture arena is the harder, riskier contract. The
                  // NOW-PLAYING ROW IS EXCLUDED: this whole block is
                  // gated on !isNowPlaying — neither action is offered
                  // (or reachable) for the current entry (R-24). The
                  // button's tap is consumed by PopupMenuButton itself —
                  // it does not bubble to the row's InkWell, so the #21
                  // skip stays tap-only (pinned by the non-regression
                  // widget test).
                  const SizedBox(width: 4),
                  Semantics(
                    label: 'Queue options ${item.title}',
                    child: PopupMenuButton<String>(
                      tooltip: 'Queue options',
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        Icons.more_vert,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      onSelected: (value) {
                        if (value == 'play-next') {
                          widget.onPlayNext(item);
                        } else if (value == 'remove') {
                          widget.onRemove(item);
                        }
                      },
                      itemBuilder: (context) => [
                        // Menu items carry BOTH a tooltip and a semantics
                        // label (R-24 "do better than ReTune's a11y-
                        // invisible CheckedTextView popup").
                        PopupMenuItem<String>(
                          value: 'play-next',
                          child: Tooltip(
                            message: 'Play next',
                            child: Semantics(
                              label: 'Play next ${item.title}',
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                leading: const Icon(Icons.play_arrow),
                                title: const Text('Play next'),
                              ),
                            ),
                          ),
                        ),
                        PopupMenuItem<String>(
                          value: 'remove',
                          child: Tooltip(
                            message: 'Remove from queue',
                            child: Semantics(
                              label: 'Remove ${item.title} from queue',
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                leading: Icon(
                                  Icons.delete_outline,
                                  color: theme.colorScheme.error,
                                ),
                                title: Text(
                                  'Remove',
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "sync failed — stale data" strip (same shape as the now-playing
/// sync-error strip).
class _SyncErrorStrip extends StatelessWidget {
  const _SyncErrorStrip({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          message,
          style: TextStyle(color: theme.colorScheme.onErrorContainer),
        ),
      ),
    );
  }
}
