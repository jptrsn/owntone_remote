import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../api/owntone_api.dart';
import '../api/ws_client.dart';
import 'pause_origin.dart';
import 'player_state.dart';

/// The single source of truth for the server's player state.
///
/// Flow: WS event (invalidation) → refetch the slice → notify. Every app
/// action goes through here so the pause-origin tracker stays consistent.
class PlayerController extends ChangeNotifier {
  PlayerController({required OwntoneApi api})
    : _api = api,
      _logger = Logger(printer: PrettyPrinter(methodCount: 0));

  static const _wsSubscriptions = [
    'player',
    'volume',
    'outputs',
    'queue',
    'options',
  ];

  final OwntoneApi _api;
  final Logger _logger;
  final PauseOriginTracker _tracker = PauseOriginTracker();
  WsClient? _ws;
  StreamSubscription<List<String>>? _wsEvents;
  StreamSubscription<String>? _wsStatus;

  PlayerState? _player;
  NowPlayingItem? _nowPlaying;
  String _wsState = 'disconnected';
  String? _error;
  bool _initialized = false;

  PlayerState? get player => _player;
  NowPlayingItem? get nowPlaying => _nowPlaying;
  String get wsState => _wsState;
  String? get error => _error;
  bool get initialized => _initialized;
  bool get isPlaying => _player?.isPlaying ?? false;

  /// Connects (fetches config + first player slice, then starts the WS).
  /// Never throws: failures are surfaced via [error].
  Future<void> init() async {
    try {
      final config = await _api.getConfig();
      final wsPort = config['websocket_port'] as int? ?? 0;
      if (wsPort > 0) {
        final wsUri = _api.baseUrl.replace(
          scheme: 'ws',
          port: wsPort,
          path: '/',
          query: '',
        );
        _ws = WsClient(uri: wsUri, subscriptions: _wsSubscriptions);
        _wsEvents = _ws!.events.listen(_onWsEvents);
        _wsStatus = _ws!.status.listen((s) {
          _wsState = s == 'reconnecting' ? 'reconnecting' : s;
          notifyListeners();
        });
      }
      await _refreshAll();
      _ws?.start();
      _initialized = true;
    } catch (e) {
      _logger.e('init failed', error: e);
      _error = 'Cannot reach server: $e';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _wsEvents?.cancel();
    _wsStatus?.cancel();
    _ws?.stop();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    final p = await _api.getPlayer();
    _player = p;
    _tracker.onServerStateChanged(p.isPlaying);
    _nowPlaying = p.isStopped ? null : await _api.getNowPlaying();
    _error = null;
    notifyListeners();
  }

  void _onWsEvents(List<String> events) {
    // The spike only cares about the player slice; any of these may change
    // what the now-playing screen shows (R-02: re-fetch on every event).
    final relevant = events
        .where(
          (e) =>
              e == 'player' || e == 'volume' || e == 'options' || e == 'queue',
        )
        .isNotEmpty;
    if (!relevant) return;
    unawaited(() async {
      try {
        await _refreshAll();
      } catch (e) {
        _logger.e('refetch failed', error: e);
      }
    }());
  }

  // -- user actions --------------------------------------------------------

  Future<void> play() async {
    _tracker.onUserPlay();
    await _api.play();
    await _refreshAll();
  }

  Future<void> pause() => _doPause(byCall: false);

  Future<void> stop() async {
    _tracker.onUserStop();
    await _api.stop();
    await _refreshAll();
  }

  Future<void> next() async {
    await _api.next();
    await _refreshAll();
  }

  Future<void> previous() async {
    await _api.previous();
    await _refreshAll();
  }

  Future<void> seekMs(int ms) async {
    await _api.seekMs(ms);
    await _refreshAll();
  }

  Future<void> setShuffle(bool on) async {
    await _api.setShuffle(on);
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
    await _api.setRepeat(mode);
    await _refreshAll();
  }

  Future<void> setConsume(bool on) async {
    await _api.setConsume(on);
    await _refreshAll();
  }

  Future<void> setVolume(int volume) async {
    await _api.setVolume(volume);
    await _refreshAll();
  }

  Future<void> stepVolume(int step) async {
    await _api.stepVolume(step);
    await _refreshAll();
  }

  // -- call handling (D9) ----------------------------------------------------

  /// RINGING: pause the server *only if it is playing*; otherwise the call
  /// must not claim the pause (no auto-resume later).
  void onCallRinging() {
    unawaited(_doPause(byCall: true));
  }

  /// IDLE: resume only if this app paused the server for the call.
  Future<void> onCallEnded() async {
    if (!_tracker.takeCallResume()) return;
    try {
      await _api.play();
      await _refreshAll();
    } catch (e) {
      _logger.e('call-end resume failed', error: e);
      _error = 'Call-end resume failed: $e';
      notifyListeners();
    }
  }

  Future<void> _doPause({required bool byCall}) async {
    final wasPlaying = _player?.isPlaying ?? false;
    if (byCall) {
      _tracker.onCallStart(wasPlaying: wasPlaying);
    } else {
      _tracker.onUserPause();
    }
    if (!wasPlaying) return; // nothing to pause — and the pause is not ours
    try {
      await _api.pause();
      await _refreshAll();
    } catch (e) {
      _logger.e('pause failed', error: e);
      _error = 'Pause failed: $e';
      notifyListeners();
    }
  }
}
