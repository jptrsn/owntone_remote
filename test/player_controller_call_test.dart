import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
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

/// Holds the pause response for 900 ms, so the call can end while the
/// call-pause is still in flight (the resume must wait for the ack).
class DelayingPauseAdapter implements HttpClientAdapter {
  DelayingPauseAdapter(this.inner);
  final ScriptedAdapter inner;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path == '/api/player/pause') {
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    return inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
}

/// Call handling (D9, R-08): the server pauses only once a ringing call is
/// confirmed (the 500 ms flap window elapsed, or the call connected) and
/// resumes on call end only when this app caused the pause. All timings are
/// real — the flap window is a real [Timer].
void main() {
  final int flapMs = PlayerController.flapWindow.inMilliseconds;

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

  test('a ringing->idle flap under the window issues nothing (R-08)', () async {
    await player.play();
    final afterPlay = adapter.requests.length;

    player.onCallRinging();
    await pump(200);
    await player.onCallEnded();
    await pump(flapMs + 300);

    expect(
      adapter.requests.skip(afterPlay),
      isNot(contains(contains('/api/player/pause'))),
      reason: 'the flap ended before the 500 ms window — no pause',
    );
    expect(
      adapter.requests.skip(afterPlay),
      isNot(contains(contains('/api/player/play'))),
      reason: 'no resume either',
    );
    expect(server.state, 'play');
  });

  test(
    'a call while playing: pause on confirmation, resume on end (R-08)',
    () async {
      await player.play();
      final afterPlay = adapter.requests.length;

      player.onCallRinging();
      await pump(flapMs + 200);

      expect(server.state, 'pause', reason: 'the flap window elapsed');
      expect(
        adapter.requests
            .skip(afterPlay)
            .where((r) => r.contains('/api/player/pause')),
        hasLength(1),
        reason: 'exactly one pause, at confirmation',
      );
      final afterPause = adapter.requests.length;

      await player.onCallEnded();
      await pump(300);

      expect(
        adapter.requests.skip(afterPause),
        contains(contains('/api/player/play')),
        reason: 'the call caused the pause — it resumes',
      );
      expect(server.state, 'play');
    },
  );

  test('a call while user-paused: no pause, no resume (R-08)', () async {
    await player.pause();
    final afterPause = adapter.requests.length;

    player.onCallRinging();
    await pump(flapMs + 200);
    expect(
      adapter.requests.skip(afterPause),
      isNot(contains(contains('/api/player/pause'))),
      reason: 'the pause is the user\'s, not the call\'s',
    );

    await player.onCallEnded();
    await pump(300);

    expect(
      adapter.requests.skip(afterPause),
      isNot(contains(contains('/api/player/play'))),
      reason: 'the call did not cause the pause — no auto-resume',
    );
    expect(server.state, 'pause');
  });

  test('a call while stopped: nothing happens (R-08)', () async {
    await player.stop();
    final afterStop = adapter.requests.length;

    player.onCallRinging();
    await pump(flapMs + 200);
    await player.onCallEnded();
    await pump(300);

    expect(
      adapter.requests.skip(afterStop),
      isNot(contains(contains('/api/player/pause'))),
    );
    expect(
      adapter.requests.skip(afterStop),
      isNot(contains(contains('/api/player/play'))),
    );
    expect(server.state, 'stop');
  });

  test(
    'a failed call-pause is never claimed — no auto-resume (R-08)',
    () async {
      await player.play();
      server.failPutPath = '/api/player/pause';
      final afterPlay = adapter.requests.length;

      player.onCallRinging();
      await pump(flapMs + 200); // confirmation fired; the pause failed
      expect(player.actionError, contains('Pause failed'));

      await player.onCallEnded();
      await pump(300);

      expect(
        adapter.requests.skip(afterPlay),
        isNot(contains(contains('/api/player/play'))),
        reason: 'the failed pause never owned the origin',
      );
      expect(server.state, 'play', reason: 'still playing');
    },
  );

  test(
    'a call ending before the pause acks resumes once the ack lands (R-08)',
    () async {
      final slowConn = ConnectionController(
        dioFactory: (options) =>
            Dio(options)..httpClientAdapter = DelayingPauseAdapter(adapter),
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
      final slowPlayer = PlayerController(connection: slowConn);
      addTearDown(() {
        slowPlayer.dispose();
        slowConn.dispose();
      });
      await slowPlayer.init();
      await slowConn.connectTo(cfg);
      await pump();

      await slowPlayer.play();
      slowPlayer.onCallRinging();
      await pump(flapMs + 100); // the pause is now in flight (~900 ms slow)
      final beforeEnd = adapter.requests.length;

      await slowPlayer.onCallEnded();
      await pump(200);
      expect(
        adapter.requests.skip(beforeEnd),
        isNot(contains(contains('/api/player/play'))),
        reason: 'the resume must not precede the pause ack',
      );

      await pump(1500);
      expect(
        adapter.requests.skip(beforeEnd),
        contains(contains('/api/player/play')),
        reason: 'the ack landed — the deferred resume fires',
      );
      expect(server.state, 'play');
    },
  );

  test(
    'active confirms immediately — no wait for the flap window (R-08)',
    () async {
      await player.play();

      player.onCallRinging();
      await pump(100);
      player.onCallActive();
      await pump(100);

      expect(
        server.state,
        'pause',
        reason: 'a connected call is real — confirmed well before $flapMs ms',
      );
      final afterPause = adapter.requests.length;

      await player.onCallEnded();
      await pump(300);

      expect(
        adapter.requests.skip(afterPause),
        contains(contains('/api/player/play')),
      );
      expect(server.state, 'play');
    },
  );

  test('active without a preceding ringing confirms (R-08)', () async {
    await player.play();

    player.onCallActive();
    await pump(100);

    expect(server.state, 'pause', reason: 'OFFHOOK alone is a real call');
  });
}
