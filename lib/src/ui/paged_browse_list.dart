import 'dart:async';

import 'package:flutter/material.dart';

import '../library/paged_list.dart';

/// One paged library list with the four states (R-10, unit 005a):
/// loading (skeleton rows), empty (icon + text), error (retry), loaded
/// (rows + load-more). The offline banner lives one level up
/// (BrowseScreenScaffold); while [enabled] is false the list is inert (no
/// load-more, no retry) and keeps whatever it has loaded (stale data).
class PagedBrowseList<T> extends StatefulWidget {
  const PagedBrowseList({
    super.key,
    required this.list,
    required this.enabled,
    required this.itemBuilder,
    required this.emptyMessage,
    required this.what,
    this.emptyIcon,
  });

  final PagedList<T> list;
  final bool enabled;
  final Widget Function(BuildContext context, int index, T item) itemBuilder;

  /// Shown with [emptyIcon] when the server answers an empty slice.
  final String emptyMessage;

  /// Noun for the error text: "Could not load artists."
  final String what;
  final IconData? emptyIcon;

  /// How close to the bottom (px) the load-more triggers.
  static const loadMoreThreshold = 300.0;

  /// Skeleton rows while the first page is in flight.
  static const skeletonRows = 8;

  @override
  State<PagedBrowseList<T>> createState() => _PagedBrowseListState<T>();
}

class _PagedBrowseListState<T> extends State<PagedBrowseList<T>> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.list.addListener(_rebuild);
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant PagedBrowseList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.list != widget.list) {
      oldWidget.list.removeListener(_rebuild);
      widget.list.addListener(_rebuild);
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!widget.enabled || !_scroll.hasClients) return;
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - PagedBrowseList.loadMoreThreshold) {
      unawaited(widget.list.loadNext());
    }
  }

  @override
  void dispose() {
    widget.list.removeListener(_rebuild);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = widget.list;

    // A failed first page: the full error state.
    if (list.error != null && list.items.isEmpty) {
      return Center(
        child: _ListErrorState(
          what: widget.what,
          message: list.error!,
          enabled: widget.enabled,
          onRetry: list.retry,
        ),
      );
    }
    if (!list.hasLoaded) {
      // Never started while offline: wait for the connection rather than
      // spin a skeleton forever.
      if (!list.started && !widget.enabled) {
        return const Center(child: Text('Waiting for the server…'));
      }
      return ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: PagedBrowseList.skeletonRows,
        itemBuilder: (_, _) => const _SkeletonRow(),
      );
    }
    if (list.items.isEmpty) {
      return Center(
        child: _ListEmptyState(
          message: widget.emptyMessage,
          icon: widget.emptyIcon ?? Icons.library_music,
        ),
      );
    }
    final hasFooter = list.loading || (list.error != null && !list.exhausted);
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.all(8),
      itemCount: list.items.length + (hasFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        if (i < list.items.length) {
          return widget.itemBuilder(context, i, list.items[i]);
        }
        return list.error != null
            ? _ListErrorRow(
                message: list.error!,
                enabled: widget.enabled,
                onRetry: list.retry,
              )
            : const _LoadingMoreRow();
      },
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow() : super(key: const ValueKey('skeleton-row'));

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}

class _ListEmptyState extends StatelessWidget {
  const _ListEmptyState({required this.message, required this.icon});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          message,
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _ListErrorState extends StatelessWidget {
  const _ListErrorState({
    required this.what,
    required this.message,
    required this.enabled,
    required this.onRetry,
  });

  final String what;
  final String message;
  final bool enabled;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 56, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          Text(
            'Could not load $what.',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: enabled ? onRetry : null,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _ListErrorRow extends StatelessWidget {
  const _ListErrorRow({
    required this.message,
    required this.enabled,
    required this.onRetry,
  });

  final String message;
  final bool enabled;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.error_outline, size: 20, color: theme.colorScheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Load failed — $message',
            style: theme.textTheme.labelMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          onPressed: enabled ? onRetry : null,
          child: const Text('Retry'),
        ),
      ],
    );
  }
}

class _LoadingMoreRow extends StatelessWidget {
  const _LoadingMoreRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }
}
