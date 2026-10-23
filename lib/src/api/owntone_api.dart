import 'package:dio/dio.dart';

import '../outputs/output.dart';
import '../player/player_state.dart';

/// Thin OwnTone JSON API client (docs/API.md). One instance per configured
/// server; the base URL is set by the ConnectionController (R-01).
class OwntoneApi {
  OwntoneApi({required Dio dio, required Uri baseUrl})
    : _dio = dio,
      _baseUrl = baseUrl;

  final Dio _dio;
  final Uri _baseUrl;

  Uri get baseUrl => _baseUrl;

  Future<Map<String, dynamic>> getConfig() async {
    final res = await _dio.get('/api/config');
    return res.data as Map<String, dynamic>;
  }

  Future<PlayerState> getPlayer() async {
    final res = await _dio.get('/api/player');
    return PlayerState.fromJson(res.data as Map<String, dynamic>);
  }

  /// Now-playing item, or null when stopped / no queue item (R-03).
  Future<NowPlayingItem?> getNowPlaying() async {
    final res = await _dio.get(
      '/api/queue',
      queryParameters: const {'id': 'now_playing'},
    );
    final data = res.data as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? const [];
    if (items.isEmpty) return null;
    return NowPlayingItem.fromJson(
      items.first as Map<String, dynamic>,
      _baseUrl,
    );
  }

  Future<List<Output>> getOutputs() async {
    final res = await _dio.get('/api/outputs');
    final data = res.data as Map<String, dynamic>;
    final list = data['outputs'] as List<dynamic>? ?? const [];
    return [for (final e in list) Output.fromJson(e as Map<String, dynamic>)];
  }

  Future<void> play() => _put('/api/player/play');
  Future<void> pause() => _put('/api/player/pause');
  Future<void> stop() => _put('/api/player/stop');
  Future<void> next() => _put('/api/player/next');
  Future<void> previous() => _put('/api/player/previous');

  Future<void> seekMs(int positionMs) =>
      _put('/api/player/seek', {'position_ms': positionMs});

  Future<void> setShuffle(bool on) =>
      _put('/api/player/shuffle', {'state': on});

  Future<void> setRepeat(Repeat mode) =>
      _put('/api/player/repeat', {'state': mode.wire});

  Future<void> setConsume(bool on) =>
      _put('/api/player/consume', {'state': on});

  Future<void> setVolume(int volume) =>
      _put('/api/player/volume', {'volume': volume});

  /// Relative volume change — the volume-rocker path (±5 per press).
  Future<void> stepVolume(int step) =>
      _put('/api/player/volume', {'step': step});

  /// Per-output volume (R-09). OwnTone 29.3 takes `output_id` on the same
  /// player-volume endpoint as the master volume.
  Future<void> setOutputVolume(String outputId, int volume) =>
      _put('/api/player/volume', {'volume': volume, 'output_id': outputId});

  /// Enables exactly this set of outputs and disables the rest — one call
  /// for multi-select, never N per-output toggles (R-09, docs/API.md).
  Future<void> setOutputs(List<String> outputIds) =>
      _dio.put('/api/outputs/set', data: {'outputs': outputIds});

  /// Per-output write used by the PIN flow (R-09): enabling a
  /// `has_password` / `needs_auth_key` output sends `selected: true` plus
  /// the `pin` on the single-output endpoint — `/outputs/set` has no pin
  /// parameter.
  Future<void> setOutput(
    String outputId, {
    bool? selected,
    int? volume,
    String? pin,
  }) async {
    final body = <String, dynamic>{
      'selected': ?selected,
      'volume': ?volume,
      'pin': ?pin,
    };
    await _dio.put('/api/outputs/$outputId', data: body);
  }

  Future<void> _put(String path, [Map<String, dynamic>? query]) =>
      _dio.put(path, queryParameters: query);
}
