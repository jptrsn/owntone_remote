import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../api/owntone_api.dart';
import '../connection/connection_controller.dart';
import '../outputs/output.dart';

/// The outputs slice (R-09). Unit 001 criterion 5 requires that after a
/// reconnect the app's *outputs* state is correct; unit 004 adds the
/// interactive actions: selection toggles (one `PUT /outputs/set` with the
/// full selected-id list, never N toggles), per-output volume, and the PIN
/// flow for protected outputs.
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
  bool _hasLoaded = false;
  String? _syncError;
  String? _actionError;
  int _actionErrorSeq = 0;

  List<Output> get outputs => _outputs;

  /// True once the first fetch succeeded (distinguishes "loading" from an
  /// empty server).
  bool get hasLoaded => _hasLoaded;

  /// Last refetch failure (transient; cleared by the next success).
  String? get syncError => _syncError;

  /// Last failed user action (optimistic rollback + snackbar, unit 004 —
  /// same pattern as PlayerController).
  String? get actionError => _actionError;
  int get actionErrorSeq => _actionErrorSeq;

  /// Currently selected (active) outputs, in server order.
  List<Output> get selected =>
      _outputs.where((o) => o.selected).toList(growable: false);

  /// R-09 selection-set math, pure: the selected id set after toggling
  /// [id], as an ordered id list (server order) ready for
  /// `PUT /api/outputs/set`.
  static List<String> selectedIdsAfterToggle(List<Output> outputs, String id) {
    final targetWasSelected = outputs.any((o) => o.id == id && o.selected);
    return [
      for (final o in outputs)
        if (o.id == id ? !targetWasSelected : o.selected) o.id,
    ];
  }

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
      _hasLoaded = true;
      _syncError = null;
    } catch (e) {
      _logger.e('outputs refetch failed', error: e);
      _syncError = 'Sync failed — showing last known state.';
    }
    if (!_disposed) notifyListeners();
  }

  // -- user actions (R-09, unit 004) -----------------------------------------
  //
  // Same contract as PlayerController._action: an optimistic mutation is
  // applied and listeners fire immediately; on success the confirming
  // refetch reconciles with the server; on failure the pre-action state is
  // restored and the typed error is surfaced for a snackbar.

  /// Toggles [id]'s membership in the selected set with exactly one
  /// `PUT /api/outputs/set` carrying the full new id list (R-09: not N
  /// per-output toggles). The playing-guard confirmation lives in the UI,
  /// not here.
  Future<bool> toggle(String id) {
    final ids = selectedIdsAfterToggle(_outputs, id);
    return _action(
      'Outputs',
      (api) => api.setOutputs(ids),
      optimistic: (os) => [
        for (final o in os) o.id == id ? o.copyWith(selected: !o.selected) : o,
      ],
    );
  }

  /// Enables a protected output (`has_password` / `needs_auth_key`) with its
  /// PIN (R-09): `PUT /api/outputs/{id}` with `selected: true, pin: …` —
  /// `/outputs/set` has no pin parameter. A wrong PIN is a server 4xx: the
  /// error is surfaced and the output stays disabled.
  Future<bool> enableWithPin(String id, String pin) => _action(
    'Unlock',
    (api) => api.setOutput(id, selected: true, pin: pin),
    optimistic: (os) => [
      for (final o in os) o.id == id ? o.copyWith(selected: true) : o,
    ],
  );

  /// Per-output volume (R-09): `PUT /api/player/volume?output_id=…`.
  Future<bool> setOutputVolume(String id, int volume) => _action(
    'Output volume',
    (api) => api.setOutputVolume(id, volume),
    optimistic: (os) => [
      for (final o in os)
        o.id == id ? o.copyWith(volume: volume.clamp(0, 100)) : o,
    ],
  );

  Future<bool> _action(
    String label,
    Future<void> Function(OwntoneApi) fn, {
    required List<Output> Function(List<Output> os) optimistic,
  }) async {
    final api = _conn.api;
    if (api == null || !_conn.isConnected) return false;
    final before = _outputs;
    _outputs = optimistic(before);
    if (!_disposed) notifyListeners();
    try {
      await fn(api);
      _actionError = null;
    } catch (e) {
      _logger.e('$label failed', error: e);
      _outputs = before;
      _actionError = _describeActionError(label, e);
      _actionErrorSeq++;
      if (!_disposed) notifyListeners();
      return false;
    }
    await _refresh();
    return true;
  }

  /// A readable, typed message for a failed action (the snackbar text).
  String _describeActionError(String label, Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      if (status != null) {
        return '$label failed — server answered HTTP $status.';
      }
      return '$label failed — could not reach the server.';
    }
    return '$label failed: $e';
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
