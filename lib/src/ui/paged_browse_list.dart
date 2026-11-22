import 'dart:async';

import 'package:flutter/material.dart';

import '../library/paged_list.dart';
import 'list_states.dart';

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
    this.groupKeyOf,
  });

  final PagedList<T> list;
  final bool enabled;
  final Widget Function(BuildContext context, int index, T item) itemBuilder;

  /// R-25: when set, the loaded branch renders disabled alphabetical
  /// section headers (ReTune `basic_header` pattern) before every item
  /// whose normalized group key (see [browseSectionKey]) differs from the
  /// previous *loaded* item's — so paging across a letter boundary emits
  /// the header exactly once, in either direction. Null (the default)
  /// renders the plain list (Playlists/Albums stay headerless).
  final String Function(T item)? groupKeyOf;

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
        child: ListErrorState(
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
      return ListSkeletonRows(rows: PagedBrowseList.skeletonRows);
    }
    if (list.items.isEmpty) {
      return Center(
        child: ListEmptyState(
          message: widget.emptyMessage,
          icon: widget.emptyIcon ?? Icons.library_music,
        ),
      );
    }
    final hasFooter = list.loading || (list.error != null && !list.exhausted);
    // R-25: flatten items (+ headers where the group key changes) into one
    // row list. The key comparison runs against the previous *loaded*
    // item, not the previous row — a header therefore lands once across a
    // page boundary and once across a reload, never twice.
    final groupKeyOf = widget.groupKeyOf;
    final rows = <_BrowseRow>[];
    String? prevKey;
    for (var i = 0; i < list.items.length; i++) {
      if (groupKeyOf != null) {
        final key = browseSectionKey(groupKeyOf(list.items[i]));
        if (key != prevKey) {
          rows.add(_BrowseRow.header(key));
          prevKey = key;
        }
      }
      rows.add(_BrowseRow.item(i));
    }
    return ListView.separated(
      controller: _scroll,
      padding: const EdgeInsets.all(8),
      itemCount: rows.length + (hasFooter ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        if (i < rows.length) {
          final row = rows[i];
          if (row.header != null) {
            return _SectionHeader(label: row.header!);
          }
          return widget.itemBuilder(context, row.index, list.items[row.index]);
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

/// One rendered row of the loaded branch: an item (by index) or a section
/// header (by label).
class _BrowseRow {
  const _BrowseRow.item(this.index) : header = null;
  const _BrowseRow.header(this.header) : index = -1;

  final int index;
  final String? header;
}

/// The R-25 letter group from an item's server sort key: uppercased first
/// character; anything that is not a letter (digit, symbol, empty) folds
/// into `#` — ReTune's `basic_header` collapse.
/// PR #54 review (F3) hypothesised single-rune `toUpperCase` EXPANSION
/// (ß→SS, ﬀ→FF). DISPROVED by measurement (PR #70): Dart's toUpperCase is
/// the simple 1:1 mapping — 'ß' stays 'ß', the ﬀ ligature is unchanged; no
/// two-char group is reachable. Behaviour pinned in tracks_screen_test.
String browseSectionKey(String sortName) {
  final trimmed = sortName.trim();
  if (trimmed.isEmpty) return '#';
  final first = String.fromCharCodes(trimmed.runes.take(1)).toUpperCase();
  return _letterFirst.hasMatch(first) ? first : '#';
}

final _letterFirst = RegExp(r'^\p{L}', unicode: true);

/// A section header row (R-25): structure, not a control — no ink, no tap
/// callback, nothing focusable. The semantics label stays for a11y readers
/// as a heading (`header: true`), the way ReTune's disabled header rows
/// read as structure rather than list items.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      label: label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.secondary,
            ),
          ),
        ),
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
