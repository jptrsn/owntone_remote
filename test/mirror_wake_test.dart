import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/audio/mirror_handler.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// R-07 (issue #81): the one-shot media-session wake must be consumed only
/// when it actually fires. `start()` waits at most 10 s for the first
/// `PlayerState`; when the server is unreachable through that window (the
/// Pixel 6 reproduction was the 5 s Dio connectTimeout tripping on a slow
/// NAS), the old `_wakeMediaSession()` still set `_woken = true` before the
/// null check — no wake published, wake forfeited for the life of the
/// process: session `active=false`, no notification, no lockscreen controls
/// until a full restart.
///
/// The suite drives `handler.playbackState` over a real [PlayerController] +
/// [FakeWsChannel] (the harness shape of `mirror_artwork_adversarial_test.dart`)
/// and pins the three clauses:
///  1. delayed first state → NO wake during the boot wait, wake published
///     exactly once when the first state lands, followed by the real state;
///  2. normal launch → exactly one wake, none afterwards while paused;
///  3. server never answers → `playing: true` is NEVER published (the fix
///     must not "solve" the bug by waking unconditionally).
///
/// Tests 1 and 3 each live-out `start()`'s real 10 s boot wait (the wait is
/// a non-goal to change per the issue); keep the per-test timeout in mind
/// before adding more of them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);

  Future<void> pump([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  late WakeServer server;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;

  setUp(() async {
    server = WakeServer();
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

  Future<MirrorAudioHandler> buildHandler() async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.create();
    return MirrorAudioHandler(player, settings: store);
  }

  List<PlaybackState> wakes(List<PlaybackState> published) =>
      published.where((s) => s.playing).toList();

  group('mirror session wake (R-07, #81)', () {
    test('delayed first state: no wake during the 10 s boot wait, wake NOT '
        'forfeited — the first PlayerState to land publishes playing:true '
        'exactly once, followed by the real mirrored state', () async {
      // The server is up for config/WS but the player query keeps '
      //timing out — `_player.player` stays null past start()'s boot wait.
      final handler = await buildHandler();
      final published = <PlaybackState>[];
      final sub = handler.playbackState.listen(published.add);
      addTearDown(sub.cancel);

      final started = handler.start();
      await pump(12_000); // outlives the 10 s boot wait
      await started;

      expect(
        player.player,
        isNull,
        reason: 'harness precondition: still no server state',
      );
      expect(
        wakes(published),
        isEmpty,
        reason:
            'a disconnected app must not post a bogus playing:true — '
            'and the skipped wake must not have consumed the one-shot',
      );

      // The server wakes: the first player state lands via a WS event.
      server.playerAwake = true;
      channels.single.serverSend('{"notify":["player"]}');
      await pump(300);

      final afterWake = wakes(published);
      expect(
        afterWake,
        hasLength(1),
        reason:
            'the deferred wake fired exactly once when state first '
            'arrived (the pre-fix code never woke at all)',
      );
      final wake = afterWake.single;
      expect(
        wake.processingState,
        AudioProcessingState.ready,
        reason: 'audio_service only enters the FGS on ready+playing',
      );
      expect(wake.controls, [
        MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.skipToPrevious,
      ], reason: 'the wake carries the real (paused) controls');
      expect(
        published.indexOf(wake),
        lessThan(published.length - 1),
        reason: 'the real mirrored state follows the wake',
      );
      final real = published.last;
      expect(real.playing, isFalse);
      expect(
        real.updatePosition,
        const Duration(milliseconds: 10),
        reason: 'the post-wake publish is the server slice, not the wake',
      );
      expect(handler.mediaItem.value?.title, 'Delayed');

      // Further paused events must not re-wake.
      final wakeCount = wakes(published).length;
      channels.single.serverSend('{"notify":["player"]}');
      await pump(300);
      expect(
        wakes(published).length,
        wakeCount,
        reason: 'the one-shot stays consumed after the deferred wake',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('normal launch (state present before start()): exactly one '
        'playing:true wake followed by the real state, and paused player '
        'events publish no further wakes', () async {
      server.playerAwake = true;
      // Fill the player slice through the normal event path (a WS
      // 'player' event → refetch) so the connection generation — and
      // the single FakeWsChannel — stay intact.
      channels.single.serverSend('{"notify":["player"]}');
      await pump(200);
      expect(
        player.player,
        isNotNull,
        reason: 'harness precondition: state exists before start()',
      );

      final handler = await buildHandler();
      final published = <PlaybackState>[];
      final sub = handler.playbackState.listen(published.add);
      addTearDown(sub.cancel);

      await handler.start();
      await pump(200);

      expect(
        wakes(published),
        hasLength(1),
        reason: 'one wake per launch — the working path must not change',
      );
      expect(
        published.last.playing,
        isFalse,
        reason: 'the real (paused) state follows the wake',
      );
      expect(handler.mediaItem.value?.title, 'Delayed');

      final wakeCount = wakes(published).length;
      channels.single.serverSend('{"notify":["player"]}');
      await pump(200);
      channels.single.serverSend('{"notify":["volume"]}');
      await pump(200);
      expect(
        wakes(published).length,
        wakeCount,
        reason: 'paused-time player changes never re-publish playing:true',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('offline guarantee: if the server never answers the player query, '
        'playing:true is NEVER published — even across repeated player events '
        'after the boot wait (the wake is pending, never bogus)', () async {
      final handler = await buildHandler();
      final published = <PlaybackState>[];
      final sub = handler.playbackState.listen(published.add);
      addTearDown(sub.cancel);

      final started = handler.start();
      await pump(12_000);
      await started;

      // Player events on a still-dead player endpoint: the pending wake
      // re-attempts must keep declining to publish without state.
      channels.single.serverSend('{"notify":["player"]}');
      await pump(200);
      channels.single.serverSend('{"notify":["queue"]}');
      await pump(200);

      expect(
        server.playerAnswers,
        0,
        reason: 'harness precondition: the player endpoint never answered',
      );
      expect(player.player, isNull);
      expect(
        wakes(published),
        isEmpty,
        reason:
            'a disconnected app must not post a bogus playing:true '
            'notification (class doc / _wakeMediaSession doc)',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

/// OwnTone for the mirror wake path: `/api/config` always answers (the
/// connection must succeed and the WS must open, as on the device), while
/// `/api/player` either hangs the app's 5 s connect window out (`down`) or
/// answers a paused slice with a queue item.
class WakeServer {
  WakeServer();

  bool playerAwake = false;

  /// How many `/api/player` requests answered (for the never-awake test's
  /// liveness assertion).
  int playerAnswers = 0;

  Response<dynamic> handle(RequestOptions o) {
    if (o.method == 'GET') {
      switch (o.path) {
        case '/api/config':
          return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
        case '/api/player':
          if (!playerAwake) {
            // The device-log shape: `DioException [connection timeout]`.
            throw networkError(
              o,
              'connection timeout',
              type: DioExceptionType.connectionTimeout,
            );
          }
          playerAnswers++;
          return jsonResponse(o, {
            'state': 'pause',
            'repeat': 'off',
            'consume': false,
            'shuffle': false,
            'volume': 42,
            'item_id': 197001,
            'item_progress_ms': 10,
            'item_length_ms': 1000,
          });
        case '/api/queue':
          return jsonResponse(o, {
            'items': [
              if (playerAwake)
                {
                  'id': '1',
                  'track_id': 197001,
                  'title': 'Delayed',
                  'artist': 'Wake',
                  'album': 'R-07',
                  'length_ms': 1000,
                  'uri': 'library:track:197001',
                },
            ],
          });
      }
    }
    return jsonResponse(o, <String, dynamic>{});
  }
}
