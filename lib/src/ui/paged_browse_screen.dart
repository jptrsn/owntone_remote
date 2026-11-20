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
    this.groupKeyOf,
    this.drawer,
    this.appActions,
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

  /// R-25: forwarded to [PagedBrowseList] — set to get alphabetical
  /// section headers (Artists/Genres; Songs when #38 lands).
  final String Function(T item)? groupKeyOf;

  /// R-21: forwarded to [BrowseScreenScaffold] — the drawer with this
  /// screen's `selected:` destination (null → plain hamburger, e.g. the
  /// detail screens that are not drawer destinations).
  final Widget? drawer;

  /// R-19 (issue #41): extra app-bar actions built with the live
  /// [PagedList] — the detail screens' Play All / Shuffle / Play Next /
  /// Add to Up Next overflow gates its entries on emptiness, so it needs
  /// the list state. [_PagedBrowseScreenState] listens to the list, so the
  /// app bar rebuilds when the first page lands.
  final List<Widget> Function(BuildContext context, PagedList<T> list)?
  appActions;

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
    // R-19: the app-bar overflow gates on list emptiness, so the app bar
    // must rebuild when the first page lands — PagedBrowseList listens to
    // the list for the body, but the scaffold actions are built here.
    _list.addListener(_onListChanged);
    if (conn.phase == ConnectionPhase.connected) {
      unawaited(_list.loadFirst());
    }
  }

  void _onListChanged() {
    if (mounted) setState(() {});
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
      // R-18: outputs one tap away from every browse screen (D-09). The
      // paged app bar carries at most title + back + this icon — the
      // 360-logical-px overflow constraint (unit 004 finding) is pinned by
      // test/outputs_appbar_test.dart.
      actions: [
        const OutputsAppBarAction(),
        if (widget.appActions != null) ...widget.appActions!(context, _list),
      ],
      drawer: widget.drawer,
      onReconnect: _onReconnect,
      onLibraryChanged: _list.started ? () => unawaited(_list.reload()) : null,
      body: PagedBrowseList(
        list: _list,
        enabled: enabled,
        emptyMessage: widget.emptyMessage,
        emptyIcon: widget.emptyIcon,
        what: widget.what,
        groupKeyOf: widget.groupKeyOf,
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
