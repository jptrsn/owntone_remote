import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import 'connection_banner.dart';

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
  });

  final String title;
  final Widget body;
  final VoidCallback? onReconnect;
  final VoidCallback? onLibraryChanged;

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
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          if (!enabled)
            const ConnectionBanner(
              message: 'Server unreachable — retrying. Browsing disabled.',
            ),
          Expanded(child: widget.body),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    super.dispose();
  }
}
