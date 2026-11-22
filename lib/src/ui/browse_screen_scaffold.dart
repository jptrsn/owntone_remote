import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import 'app_drawer.dart';
import 'connection_banner.dart';
import 'mini_player.dart';
import 'outputs_screen.dart';

/// The shell shared by every browse screen (R-10, unit 005a): app bar with
/// back, the app-wide offline banner (unit 001), and the reconnect /
/// invalidation wiring:
///
/// - [onReconnect] fires when the connection transitions back to
///   [ConnectionPhase.connected] — the open list refetches (R-10: "recovers
///   on reconnect");
/// - [onLibraryChanged] fires on WS `database` / `update` events while
///   connected (R-02: every event is an invalidation → refetch the visible
///   list).
class BrowseScreenScaffold extends StatefulWidget {
  const BrowseScreenScaffold({
    super.key,
    required this.title,
    required this.body,
    this.onReconnect,
    this.onLibraryChanged,
    this.actions,
    this.drawer,
    this.offlineMessage = 'Server unreachable — retrying. Browsing disabled.',
  });

  final String title;
  final Widget body;
  final VoidCallback? onReconnect;
  final VoidCallback? onLibraryChanged;

  /// App-bar actions (unit 005b: the queue screen's clear button).
  final List<Widget>? actions;

  /// The R-21 navigation drawer (issue #44), mirrored like [actions] from
  /// the call site so each screen names its own selected destination.
  /// Defaults to a plain [AppDrawer] (hamburger on every browse screen —
  /// the frozen "hamburger on every main screen" contract); pass
  /// `const AppDrawer(selected: …)` on screens that are drawer
  /// destinations.
  final Widget? drawer;

  final String offlineMessage;

  @override
  State<BrowseScreenScaffold> createState() => _BrowseScreenScaffoldState();
}

class _BrowseScreenScaffoldState extends State<BrowseScreenScaffold> {
  ConnectionPhase? _lastPhase;
  StreamSubscription<List<String>>? _eventsSub;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_eventsSub == null) {
      final conn = context.read<ConnectionController>();
      _lastPhase = conn.phase;
      _eventsSub = conn.events.listen(_onWsEvents);
    }
  }

  void _onWsEvents(List<String> events) {
    final conn = context.read<ConnectionController>();
    if (!conn.isConnected) return;
    if (!events.any((e) => e == 'database' || e == 'update')) return;
    (widget.onLibraryChanged ?? widget.onReconnect)?.call();
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final prev = _lastPhase;
    _lastPhase = conn.phase;
    if (conn.phase == ConnectionPhase.connected &&
        prev != ConnectionPhase.connected) {
      // Defer: the callback mutates list state (notifyListeners →
      // setState), which must not happen during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReconnect?.call();
      });
    }
    final enabled = conn.phase == ConnectionPhase.connected;
    return Scaffold(
      // drawerAwareLeading: AppBar's auto-leading replaces the BackButton
      // with the DrawerButton once a drawer exists — pushed screens need
      // both (app_drawer.dart explains; do not reduce to leading: null).
      appBar: AppBar(
        title: Text(widget.title),
        leading: drawerAwareLeading(context),
        leadingWidth: drawerAwareLeadingWidth(context),
        actions: widget.actions,
      ),
      drawer: widget.drawer ?? const AppDrawer(),
      body: Column(
        children: [
          if (!enabled) ConnectionBanner(message: widget.offlineMessage),
          Expanded(child: widget.body),
        ],
      ),
      // R-22 (issue #45): the mini transport bar on every browse screen
      // (Library/Search/Queue and all paged views). bottomNavigationBar is
      // Scaffold's own layer: it never scrolls with the list and never
      // overlaps row hit-tests. The offline banner sits at the body's top,
      // the bar at the bottom — they coexist; the bar itself goes inert
      // with the connection (MiniPlayer reads the phase).
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    super.dispose();
  }
}

/// R-18 (D-09, `docs/retune-capture/14-speakers/`): ReTune's app-bar
/// **Speakers** action — outputs are one tap from any browse screen, mid-
/// browse, not only from now-playing. Same destination as now-playing's
/// entry ([OutputsScreen]).
///
/// Pressable while offline on purpose (queue hide-toggle precedent): the
/// action itself touches nothing on the server and [OutputsScreen] renders
/// the offline banner + waiting state itself. Do not "fix" it to disable
/// with the connection — that regresses the R-18 "one tap from any browse
/// screen" acceptance to "one tap while lucky".
class OutputsAppBarAction extends StatelessWidget {
  const OutputsAppBarAction({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Outputs',
      icon: const Icon(Icons.speaker, semanticLabel: 'Outputs'),
      onPressed: () => Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => const OutputsScreen())),
    );
  }
}
