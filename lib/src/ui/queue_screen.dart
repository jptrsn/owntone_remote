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
        // Issue #21: a queued row is already in the queue — tapping it
        // skips in place (queue content unchanged), it must NOT re-add
        // with clear+playback=start (that replaced the whole queue).
        onSkip: (item) => unawaited(queueController.skipToQueueItem(item)),
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
    required this.onSkip,
  });

  final QueueController controller;

  /// The rows to render — the (possibly hide-cut, issue #23) view of
  /// `controller.queue` computed by the parent on every build.
  final List<QueueItem> items;
  final bool enabled;
  final String? nowPlayingId;

  /// Row tap (issue #21): advance the queue in place to [item] —
  /// `QueueController.skipToQueueItem`, never `playUris`.
  final void Function(QueueItem item) onSkip;

  @override
  State<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<_QueueList> {
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
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: widget.items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _queueRow(context, widget.items[i]),
            ),
          ),
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
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: widget.items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _queueRow(context, widget.items[i]),
    );
  }

  Widget _queueRow(BuildContext context, QueueItem item) {
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
