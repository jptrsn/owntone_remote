import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../library/paged_list.dart';
import 'browse_screen_scaffold.dart';
import 'paged_browse_list.dart';

/// The stateful base for every paged browse screen (R-10, unit 005a):
/// owns one [PagedList], starts the first load when the connection is up,
/// refetches on reconnect (and on library invalidation), and renders the
/// list through [PagedBrowseList]. Concrete screens (ArtistsScreen, …)
/// are thin declarative wrappers over this.
class PagedBrowseScreen<T> extends StatefulWidget {
  const PagedBrowseScreen({
    super.key,
    required this.title,
    required this.buildList,
    required this.itemBuilder,
    required this.emptyMessage,
    required this.emptyIcon,
    required this.what,
  });

  final String title;

  /// Builds the (unstarted) list for this screen; [conn] is captured by
  /// the fetch closure so the API client is resolved at call time.
  final PagedList<T> Function(ConnectionController conn) buildList;

  /// [enabled] is the current connection state (rows stay inert while
  /// the offline banner is up).
  final Widget Function(BuildContext context, int index, T item, bool enabled)
  itemBuilder;

  final String emptyMessage;
  final IconData emptyIcon;

  /// Noun for the error text: "Could not load artists."
  final String what;

  @override
  State<PagedBrowseScreen<T>> createState() => _PagedBrowseScreenState<T>();
}

class _PagedBrowseScreenState<T> extends State<PagedBrowseScreen<T>> {
  late final PagedList<T> _list;

  @override
  void initState() {
    super.initState();
    final conn = context.read<ConnectionController>();
    _list = widget.buildList(conn);
    if (conn.phase == ConnectionPhase.connected) {
      unawaited(_list.loadFirst());
    }
  }

  void _onReconnect() {
    // Already tried (incl. a failed first page) → full refetch; otherwise
    // the first load simply starts now.
    if (_list.started) {
      unawaited(_list.reload());
    } else {
      unawaited(_list.loadFirst());
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final enabled = conn.phase == ConnectionPhase.connected;
    return BrowseScreenScaffold(
      title: widget.title,
      onReconnect: _onReconnect,
      onLibraryChanged: _list.started ? () => unawaited(_list.reload()) : null,
      body: PagedBrowseList(
        list: _list,
        enabled: enabled,
        emptyMessage: widget.emptyMessage,
        emptyIcon: widget.emptyIcon,
        what: widget.what,
        itemBuilder: (context, i, item) =>
            widget.itemBuilder(context, i, item, enabled),
      ),
    );
  }

  @override
  void dispose() {
    _list.dispose();
    super.dispose();
  }
}
