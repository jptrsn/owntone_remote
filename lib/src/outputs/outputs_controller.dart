import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../connection/connection_controller.dart';
import '../outputs/output.dart';

/// The outputs slice (data only). Unit 001 criterion 5 requires that after a
/// reconnect the app's *outputs* state is correct, so the slice exists now;
/// the interactive speakers screen (R-09) is unit 004.
class OutputsController extends ChangeNotifier {
  OutputsController({required ConnectionController connection})
    : _conn = connection,
      _logger = Logger(printer: PrettyPrinter(methodCount: 0));

  final ConnectionController _conn;
  final Logger _logger;

  StreamSubscription<List<String>>? _eventsSub;
  StreamSubscription<void>? _refetchSub;
  ConnectionPhase? _lastPhase;
  bool _initialized = false;
  bool _disposed = false;

  List<Output> _outputs = const [];

  List<Output> get outputs => _outputs;

  /// Currently selected (active) outputs, in server order.
  List<Output> get selected =>
      _outputs.where((o) => o.selected).toList(growable: false);

  /// Wires the controller to the connection and fetches the first slice if
  /// the connection is already up. Idempotent.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _lastPhase = _conn.phase;
    _conn.addListener(_onConnectionChanged);
    _eventsSub = _conn.events.listen(_onWsEvents);
    _refetchSub = _conn.refetchAll.listen((_) => unawaited(_refresh()));
    if (_conn.isConnected) unawaited(_refresh());
  }

  void _onConnectionChanged() {
    final phase = _conn.phase;
    final prev = _lastPhase;
    _lastPhase = phase;
    if (phase == ConnectionPhase.connected &&
        prev != ConnectionPhase.connected) {
      unawaited(_refresh());
    }
  }

  /// R-02: `outputs` (and `volume` — an output volume change re-emits it)
  /// invalidate this slice.
  void _onWsEvents(List<String> events) {
    if (!events.any((e) => e == 'outputs' || e == 'volume')) return;
    if (!_conn.isConnected) return;
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final api = _conn.api;
    if (api == null) return;
    try {
      _outputs = await api.getOutputs();
    } catch (e) {
      _logger.e('outputs refetch failed', error: e);
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _conn.removeListener(_onConnectionChanged);
    _eventsSub?.cancel();
    _refetchSub?.cancel();
    super.dispose();
  }
}
