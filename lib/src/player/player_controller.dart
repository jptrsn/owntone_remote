import 'dart:async';

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

  PlayerState? get player => _player;
  NowPlayingItem? get nowPlaying => _nowPlaying;

  /// Last refetch failure (transient; cleared by the next success).
  String? get syncError => _syncError;

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

  /// Runs a server call, surfacing failures in [syncError]. Returns false
  /// when the call was skipped (offline) or failed.
  Future<bool> _call(String label, Future<void> Function(OwntoneApi) fn) async {
    final api = _conn.api;
    if (api == null || !_conn.isConnected) return false;
    try {
      await fn(api);
    } catch (e) {
      _logger.e('$label failed', error: e);
      _syncError = '$label failed: $e';
      if (!_disposed) notifyListeners();
      return false;
    }
    return true;
  }

  // -- user actions --------------------------------------------------------

  Future<void> play() async {
    if (!await _call('Play', (api) => api.play())) return;
    _tracker.onUserPlay();
    await _refreshAll();
  }

  Future<void> pause() => _callPause(byCall: false);

  Future<void> stop() async {
    if (!await _call('Stop', (api) => api.stop())) return;
    _tracker.onUserStop();
    await _refreshAll();
  }

  Future<void> next() async {
    if (!await _call('Next', (api) => api.next())) return;
    await _refreshAll();
  }

  Future<void> previous() async {
    if (!await _call('Previous', (api) => api.previous())) return;
    await _refreshAll();
  }

  Future<void> seekMs(int ms) async {
    if (!await _call('Seek', (api) => api.seekMs(ms))) return;
    await _refreshAll();
  }

  Future<void> setShuffle(bool on) async {
    if (!await _call('Shuffle', (api) => api.setShuffle(on))) return;
    await _refreshAll();
  }

  /// off → all → single → off (the UI cycle).
  Future<void> cycleRepeat() async {
    final current = _player?.repeat ?? Repeat.off;
    final next = switch (current) {
      Repeat.off => Repeat.all,
      Repeat.all => Repeat.single,
      Repeat.single => Repeat.off,
    };
    await setRepeat(next);
  }

  Future<void> setRepeat(Repeat mode) async {
    if (!await _call('Repeat', (api) => api.setRepeat(mode))) return;
    await _refreshAll();
  }

  Future<void> setConsume(bool on) async {
    if (!await _call('Consume', (api) => api.setConsume(on))) return;
    await _refreshAll();
  }

  Future<void> setVolume(int volume) async {
    if (!await _call('Volume', (api) => api.setVolume(volume))) return;
    await _refreshAll();
  }

  /// Relative volume change — the hardware-rocker path (R-06, unit 003).
  Future<void> stepVolume(int step) async {
    if (!await _call('Volume', (api) => api.stepVolume(step))) return;
    await _refreshAll();
  }

  // -- call handling (D9) ----------------------------------------------------

  /// RINGING: pause the server *only if it is playing*; otherwise the call
  /// must not claim the pause (no auto-resume later).
  void onCallRinging() {
    unawaited(_callPause(byCall: true));
  }

  /// IDLE: resume only if this app paused the server for the call.
  Future<void> onCallEnded() async {
    if (!_tracker.takeCallResume()) return;
    if (!await _call('Resume', (api) => api.play())) return;
    await _refreshAll();
  }

  Future<void> _callPause({required bool byCall}) async {
    final wasPlaying = _player?.isPlaying ?? false;
    if (byCall) {
      _tracker.onCallStart(wasPlaying: wasPlaying);
    } else {
      _tracker.onUserPause();
    }
    if (!wasPlaying) return; // nothing to pause — and the pause is not ours
    if (!await _call('Pause', (api) => api.pause())) return;
    await _refreshAll();
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
