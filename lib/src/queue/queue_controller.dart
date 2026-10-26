import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../api/owntone_api.dart';
import '../connection/connection_controller.dart';
import '../library/paged_list.dart' show describePagedFetchError;
import 'queue_item.dart';

/// The queue slice (R-11, unit 005b): the full `GET /api/queue` list, kept
/// current by WS `queue` events and reconnects (R-02), with the two user
/// actions — clear and play.
///
/// Same slice contract as OutputsController (unit 004): refetch on the
/// relevant WS event, refetch on reconnect, typed action errors for the
/// snackbar.
class QueueController extends ChangeNotifier {
  QueueController({required ConnectionController connection})
    : _conn = connection,
      _logger = Logger(printer: PrettyPrinter(methodCount: 0));

  final ConnectionController _conn;
  final Logger _logger;

  StreamSubscription<List<String>>? _eventsSub;
  StreamSubscription<void>? _refetchSub;
  ConnectionPhase? _lastPhase;
  bool _initialized = false;
  bool _disposed = false;

  List<QueueItem> _queue = const [];
  bool _hasLoaded = false;
  String? _syncError;
  String? _actionError;
  int _actionErrorSeq = 0;

  List<QueueItem> get queue => _queue;

  /// True once the first fetch succeeded (distinguishes "loading" from an
  /// empty queue).
  bool get hasLoaded => _hasLoaded;

  /// Last refetch failure (transient; cleared by the next success).
  String? get syncError => _syncError;

  /// Last failed user action (optimistic rollback + snackbar).
  String? get actionError => _actionError;
  int get actionErrorSeq => _actionErrorSeq;

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

  /// R-02: a `queue` event is a queue mutation (add/remove/clear/move —
  /// from any client, web UI included) → full refetch. Player-only events
  /// (next/previous) leave the list unchanged; the highlight follows the
  /// player state via PlayerController.
  void _onWsEvents(List<String> events) {
    if (!events.contains('queue')) return;
    if (!_conn.isConnected) return;
    unawaited(_refresh());
  }

  /// Manual refetch (the error-state retry button).
  Future<void> refresh() => _refresh();

  Future<void> _refresh() async {
    final api = _conn.api;
    if (api == null) return;
    try {
      _queue = await api.getQueue();
      _hasLoaded = true;
      _syncError = null;
    } catch (e) {
      _logger.e('queue refetch failed', error: e);
      // First fetch failed: a typed message for the error state; later
      // failures keep the stale list and show a strip instead.
      _syncError = !_hasLoaded
          ? describePagedFetchError(e)
          : 'Sync failed — showing last known state.';
    }
    if (!_disposed) notifyListeners();
  }

  // -- user actions (R-11, unit 005b) ---------------------------------------

  /// `PUT /api/queue/clear` with an optimistic empty list: the rows vanish
  /// immediately; on failure the pre-clear list is restored and the typed
  /// error is surfaced for a snackbar.
  Future<bool> clear() => _action(
    'Clear queue',
    (api) => api.clearQueue(),
    optimistic: (_) => const [],
  );

  /// Queue play (docs/API.md): one `POST /api/queue/items/add` with
  /// `clear=true&playback=start` — the single call that both replaces the
  /// queue and makes the server play. **Supervised**: only reachable from a
  /// user tap on this server (real speakers).
  Future<bool> playUris(List<String> uris) => _action(
    'Play',
    (api) => api.playUris(uris, clear: true, startPlayback: true),
  );

  Future<bool> _action(
    String label,
    Future<void> Function(OwntoneApi) fn, {
    List<QueueItem> Function(List<QueueItem>)? optimistic,
  }) async {
    final api = _conn.api;
    if (api == null || !_conn.isConnected) return false;
    final before = _queue;
    if (optimistic != null) {
      _queue = optimistic(before);
      if (!_disposed) notifyListeners();
    }
    try {
      await fn(api);
      _actionError = null;
    } catch (e) {
      _logger.e('$label failed', error: e);
      _queue = before;
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

/// The R-11 highlight, pure: the queue row that is currently playing.
/// `PlayerState.itemId` is the queue-entry `id` (verified live 2026-10-23:
/// item_id 196174 = entry id, whose track_id is 1195), so the comparison is
/// against [QueueItem.id] — not `trackId`.
QueueItem? findNowPlaying(List<QueueItem> queue, int? itemId) {
  if (itemId == null) return null;
  for (final item in queue) {
    if (item.id == itemId.toString()) return item;
  }
  return null;
}
