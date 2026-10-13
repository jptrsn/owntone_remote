import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../api/owntone_api.dart';
import '../connection/connection_controller.dart';
import 'pause_origin.dart';
import 'player_state.dart';

/// The single source of truth for the server's player slice (R-02, R-03).
///
/// Flow (D2): [ConnectionController] event = invalidation → refetch the
/// slice → notify. Every app action goes through here so the pause-origin
/// tracker stays consistent (D9). Actions are no-ops while disconnected
/// (the UI disables the controls too — unit 001 criterion 6).
class PlayerController extends ChangeNotifier {
  PlayerController({required ConnectionController connection})
    : _conn = connection,
      _logger = Logger(printer: PrettyPrinter(methodCount: 0));

  final ConnectionController _conn;
  final Logger _logger;
  final PauseOriginTracker _tracker = PauseOriginTracker();

  StreamSubscription<List<String>>? _eventsSub;
  StreamSubscription<void>? _refetchSub;
  ConnectionPhase? _lastPhase;
  bool _initialized = false;
  bool _disposed = false;

  PlayerState? _player;
  NowPlayingItem? _nowPlaying;
  String? _syncError;
  String? _actionError;
  int _actionErrorSeq = 0;

  PlayerState? get player => _player;
  NowPlayingItem? get nowPlaying => _nowPlaying;

  /// Last refetch failure (transient; cleared by the next success).
  String? get syncError => _syncError;

  /// Last failed user action (unit 002: optimistic rollback + snackbar).
  /// [actionErrorSeq] bumps on every failure so the UI can show the same
  /// message twice in a row.
  String? get actionError => _actionError;
  int get actionErrorSeq => _actionErrorSeq;

  bool get initialized => _initialized;
  bool get isPlaying => _player?.isPlaying ?? false;
  bool get connected => _conn.isConnected;

  /// Wires the controller to the connection and fetches the first slice
  /// if the connection is already up. Idempotent.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _lastPhase = _conn.phase;
    _conn.addListener(_onConnectionChanged);
    _eventsSub = _conn.events.listen(_onWsEvents);
    _refetchSub = _conn.refetchAll.listen((_) => unawaited(_refreshAll()));
    if (_conn.isConnected) unawaited(_refreshAll());
  }

  void _onConnectionChanged() {
    final phase = _conn.phase;
    final prev = _lastPhase;
    _lastPhase = phase;
    if (phase == ConnectionPhase.connected &&
        prev != ConnectionPhase.connected) {
      unawaited(_refreshAll());
    }
  }

  /// R-02: every WS event is an invalidation — refetch the affected slice.
  /// Only player-relevant events; `outputs` belongs to OutputsController.
  void _onWsEvents(List<String> events) {
    final relevant = events.any(
      (e) => e == 'player' || e == 'volume' || e == 'options' || e == 'queue',
    );
    if (!relevant || !_conn.isConnected) return;
    unawaited(_refreshAll());
  }

  Future<void> _refreshAll() async {
    final api = _conn.api;
    if (api == null) return;
    try {
      final p = await api.getPlayer();
      _player = p;
      _tracker.onServerStateChanged(p.isPlaying);
      _nowPlaying = p.isStopped ? null : await api.getNowPlaying();
      _syncError = null;
    } catch (e) {
      _logger.e('player refetch failed', error: e);
      _syncError = 'Sync failed — showing last known state.';
    }
    if (!_disposed) notifyListeners();
  }

  /// Runs a server call with an optimistic UI update (unit 002,
  /// SCREENS.md "Interaction design"): [optimistic] is applied to the
  /// current state and the listeners fire immediately; on success the
  /// confirming [refetch] reconciles with the server truth; on failure the
  /// pre-action state is restored and the error is surfaced for a snackbar
  /// ([actionError]/[actionErrorSeq]).
  /// Returns false when the call was skipped (offline) or failed.
  Future<bool> _action(
    String label,
    Future<void> Function(OwntoneApi) fn, {
    PlayerState? Function(PlayerState p)? optimistic,
  }) async {
    final api = _conn.api;
    if (api == null || !_conn.isConnected) return false;
    final before = _player;
    if (before != null && optimistic != null) {
      _player = optimistic(before);
      if (!_disposed) notifyListeners();
    }
    try {
      await fn(api);
      _actionError = null;
    } catch (e) {
      _logger.e('$label failed', error: e);
      if (before != null) _player = before;
      _actionError = _describeActionError(label, e);
      _actionErrorSeq++;
      if (!_disposed) notifyListeners();
      return false;
    }
    await _refreshAll();
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

  // -- user actions --------------------------------------------------------

  Future<void> play() async {
    final ok = await _action(
      'Play',
      (api) => api.play(),
      optimistic: (p) => p.copyWith(state: 'play'),
    );
    if (ok) _tracker.onUserPlay();
  }

  Future<void> pause() => _callPause(byCall: false);

  Future<void> stop() async {
    final ok = await _action(
      'Stop',
      (api) => api.stop(),
      optimistic: (p) => p.copyWith(state: 'stop', itemProgressMs: 0),
    );
    if (ok) _tracker.onUserStop();
  }

  /// No optimistic mutation: the app cannot know which item becomes
  /// current — the confirming refetch carries it.
  Future<void> next() => _action('Next', (api) => api.next());

  Future<void> previous() => _action('Previous', (api) => api.previous());

  Future<void> seekMs(int ms) {
    final limit = _player?.itemLengthMs;
    return _action(
      'Seek',
      (api) => api.seekMs(ms),
      optimistic: (p) => p.copyWith(itemProgressMs: ms.clamp(0, limit ?? ms)),
    );
  }

  Future<void> setShuffle(bool on) => _action(
    'Shuffle',
    (api) => api.setShuffle(on),
    optimistic: (p) => p.copyWith(shuffle: on),
  );

  /// off → all → single → off (the UI cycle, R-05).
  Future<void> cycleRepeat() async {
    final current = _player?.repeat ?? Repeat.off;
    final next = switch (current) {
      Repeat.off => Repeat.all,
      Repeat.all => Repeat.single,
      Repeat.single => Repeat.off,
    };
    await setRepeat(next);
  }

  Future<void> setRepeat(Repeat mode) => _action(
    'Repeat',
    (api) => api.setRepeat(mode),
    optimistic: (p) => p.copyWith(repeat: mode),
  );

  Future<void> setConsume(bool on) => _action(
    'Consume',
    (api) => api.setConsume(on),
    optimistic: (p) => p.copyWith(consume: on),
  );

  Future<void> setVolume(int volume) => _action(
    'Volume',
    (api) => api.setVolume(volume),
    optimistic: (p) => p.copyWith(volume: volume.clamp(0, 100)),
  );

  /// Relative volume change — the hardware-rocker path (R-06, unit 003).
  Future<void> stepVolume(int step) => _action(
    'Volume',
    (api) => api.stepVolume(step),
    optimistic: (p) => p.copyWith(volume: (p.volume + step).clamp(0, 100)),
  );

  // -- call handling (D9) ----------------------------------------------------

  /// RINGING: pause the server *only if it is playing*; otherwise the call
  /// must not claim the pause (no auto-resume later).
  void onCallRinging() {
    unawaited(_callPause(byCall: true));
  }

  /// IDLE: resume only if this app paused the server for the call.
  Future<void> onCallEnded() async {
    if (!_tracker.takeCallResume()) return;
    await _action(
      'Resume',
      (api) => api.play(),
      optimistic: (p) => p.copyWith(state: 'play'),
    );
  }

  Future<void> _callPause({required bool byCall}) async {
    final wasPlaying = _player?.isPlaying ?? false;
    if (!wasPlaying) return; // nothing to pause — and the pause is not ours
    if (byCall) {
      // Claim the pause only once it has actually happened — a failed pause
      // must not own the origin (or a later call-end would auto-resume a
      // server that is still playing).
      final ok = await _pause();
      if (ok) _tracker.onCallStart(wasPlaying: wasPlaying);
    } else {
      _tracker.onUserPause();
      await _pause();
    }
  }

  Future<bool> _pause() => _action(
    'Pause',
    (api) => api.pause(),
    optimistic: (p) => p.copyWith(state: 'pause'),
  );

  @override
  void dispose() {
    _disposed = true;
    _conn.removeListener(_onConnectionChanged);
    _eventsSub?.cancel();
    _refetchSub?.cancel();
    super.dispose();
  }
}
