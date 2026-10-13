import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/player/player_state.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// A tiny stateful OwnTone: PUTs mutate it, GETs reflect it.
class StatefulServer {
  StatefulServer();

  String state = 'pause';
  String repeat = 'off';
  bool consume = false;
  bool shuffle = false;
  int volume = 75;
  int progress = 1000;

  /// When non-null, PUTs to this path fail with [failPutStatus].
  String? failPutPath;
  int failPutStatus = 500;

  Response<dynamic> handle(RequestOptions o) {
    final p = o.path;
    if (o.method == 'GET') {
      switch (p) {
        case '/api/config':
          return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
        case '/api/player':
          return jsonResponse(o, {
            'state': state,
            'repeat': repeat,
            'consume': consume,
            'shuffle': shuffle,
            'volume': volume,
            'item_id': 123,
            'item_length_ms': 100000,
            'item_progress_ms': progress,
          });
        case '/api/queue':
          return jsonResponse(o, {
            'items': [
              {
                'id': 'q1',
                'track_id': 42,
                'title': 'Test Track',
                'artist': 'Test Artist',
                'album': 'Test Album',
                'length_ms': 100000,
                'uri': 'library:track:42',
              },
            ],
          });
        default:
          return jsonResponse(o, <String, dynamic>{});
      }
    }
    if (p == failPutPath) {
      throw DioException(
        requestOptions: o,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: o, statusCode: failPutStatus),
      );
    }
    // dio passes query values through untyped — an `int` stays an `int`.
    final q = o.queryParameters.map((k, v) => MapEntry(k, v.toString()));
    switch (p) {
      case '/api/player/play':
        state = 'play';
      case '/api/player/pause':
        state = 'pause';
      case '/api/player/stop':
        state = 'stop';
        progress = 0;
      case '/api/player/shuffle':
        shuffle = q['state'] == 'true';
      case '/api/player/repeat':
        repeat = q['state'] ?? repeat;
      case '/api/player/consume':
        consume = q['state'] == 'true';
      case '/api/player/volume':
        if (q['volume'] != null) {
          volume = int.parse(q['volume']!).clamp(0, 100);
        } else if (q['step'] != null) {
          volume = (volume + int.parse(q['step']!)).clamp(0, 100);
        }
      case '/api/player/seek':
        progress = int.parse(q['position_ms']!).clamp(0, 100000);
    }
    return Response(requestOptions: o, statusCode: 204);
  }
}

/// Unit 002 (SCREENS.md "Interaction design"): optimistic update on control
/// press → confirm on the response; on 5xx/network failure → rollback +
/// typed action error. R-05 repeat-cycle order. R-06 volume clamping.
void main() {
  late StatefulServer server;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;

  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);

  Future<void> pump([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  setUp(() async {
    server = StatefulServer();
    adapter = ScriptedAdapter(responder: server.handle);
    channels = [];
    conn = ConnectionController(
      dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
      wsFactory: (uri, subscriptions, backoff) => WsClient(
        uri: uri,
        subscriptions: subscriptions,
        backoff: Backoff(
          initial: const Duration(milliseconds: 5),
          maximum: const Duration(milliseconds: 20),
        ),
        channelFactory: (u) {
          final c = FakeWsChannel();
          channels.add(c);
          return c;
        },
      ),
    );
    player = PlayerController(connection: conn);
    await player.init();
    await conn.connectTo(cfg);
    await pump();
  });

  tearDown(() {
    player.dispose();
    conn.dispose();
  });

  test('volume: optimistic apply, rollback + typed error on 5xx', () async {
    server.failPutPath = '/api/player/volume';

    final pending = player.setVolume(50);
    // Optimistic: the UI sees 50 before the (failing) response.
    expect(player.player!.volume, 50);
    await pending;

    // Rolled back to the pre-action value, error surfaced for the snackbar.
    expect(player.player!.volume, 75);
    expect(player.actionError, contains('Volume failed'));
    expect(player.actionError, contains('HTTP 500'));
    expect(player.actionErrorSeq, 1);

    // Server recovers: the same action succeeds and reconciles.
    server.failPutPath = null;
    await player.setVolume(60);
    expect(player.player!.volume, 60);
    expect(player.actionError, isNull);
    expect(adapter.requests, contains('PUT /api/player/volume?volume=60'));
  });

  test('play: optimistic state, confirmed by the refetch', () async {
    final pending = player.play();
    expect(player.player!.isPlaying, isTrue);
    await pending;
    expect(player.player!.isPlaying, isTrue, reason: 'server confirmed');
    expect(player.actionError, isNull);
  });

  test('pause: optimistic state, rollback on failure', () async {
    server.state = 'play';
    await player.play(); // bring the fixture to a real play state
    expect(player.player!.isPlaying, isTrue);

    server.failPutPath = '/api/player/pause';
    final pending = player.pause();
    expect(player.player!.isPlaying, isFalse, reason: 'optimistic');
    await pending;
    expect(player.player!.isPlaying, isTrue, reason: 'rolled back');
    expect(player.actionError, contains('Pause failed'));
  });

  test('seek: optimistic progress, commit on release (R-03)', () async {
    final pending = player.seekMs(42000);
    expect(player.player!.itemProgressMs, 42000);
    await pending;
    expect(player.player!.itemProgressMs, 42000);
    expect(
      adapter.requests,
      contains('PUT /api/player/seek?position_ms=42000'),
    );
  });

  test('stepVolume clamps at 100 (R-06)', () async {
    server.volume = 98;
    await player.setVolume(98);
    await player.stepVolume(5);
    expect(player.player!.volume, 100);
    expect(adapter.requests, contains('PUT /api/player/volume?step=5'));
  });

  test('repeat cycle off → all → single → off (R-05)', () async {
    expect(player.player!.repeat, Repeat.off);
    await player.cycleRepeat();
    expect(player.player!.repeat, Repeat.all);
    expect(adapter.requests, contains('PUT /api/player/repeat?state=all'));

    await player.cycleRepeat();
    expect(player.player!.repeat, Repeat.single);
    expect(adapter.requests, contains('PUT /api/player/repeat?state=single'));

    await player.cycleRepeat();
    expect(player.player!.repeat, Repeat.off);
    expect(adapter.requests, contains('PUT /api/player/repeat?state=off'));
  });

  test(
    'shuffle/consume: optimistic state confirmed by the server (R-05)',
    () async {
      final f1 = player.setShuffle(true);
      expect(player.player!.shuffle, isTrue);
      await f1;
      expect(player.player!.shuffle, isTrue);

      final f2 = player.setConsume(true);
      expect(player.player!.consume, isTrue);
      await f2;
      expect(player.player!.consume, isTrue);
      expect(adapter.requests, contains('PUT /api/player/shuffle?state=true'));
      expect(adapter.requests, contains('PUT /api/player/consume?state=true'));
    },
  );

  test('a FAILED call-pause does not claim the pause (D9 safety)', () async {
    server.state = 'play';
    await player.play();
    server.failPutPath = '/api/player/pause';
    final before = adapter.requests.length;

    player.onCallRinging();
    await pump(100);
    // The pause failed: the app must not auto-resume a server it never
    // paused.
    await player.onCallEnded();
    expect(
      adapter.requests.skip(before),
      isNot(contains(contains('/api/player/play'))),
      reason: 'no resume after a failed call-pause',
    );
    expect(player.player!.isPlaying, isTrue, reason: 'still playing');
  });

  test('repeated failures bump the seq (same message re-toasts)', () async {
    server.failPutPath = '/api/player/consume';
    await player.setConsume(true);
    expect(player.actionErrorSeq, 1);
    await player.setConsume(false);
    expect(player.actionErrorSeq, 2);
  });
}
