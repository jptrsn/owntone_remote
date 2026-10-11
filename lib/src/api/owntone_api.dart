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

  Future<void> _put(String path, [Map<String, dynamic>? query]) =>
      _dio.put(path, queryParameters: query);
}
