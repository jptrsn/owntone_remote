import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

const _configJson = {'websocket_port': 3688, 'version': '29.3'};
const _queueJson = {
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
};

Map<String, dynamic> playerJson({String state = 'pause', int volume = 75}) => {
  'state': state,
  'repeat': 'off',
  'consume': false,
  'shuffle': false,
  'volume': volume,
  'item_id': 123,
  'item_length_ms': 100000,
  'item_progress_ms': 1000,
  'artwork_url': './artwork/nowplaying',
};

const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

Future<void> pump([int ms = 50]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

int playerFetches(ScriptedAdapter adapter) =>
    adapter.requests.where((r) => r.endsWith('/api/player')).length;

void main() {
  group('PlayerController event → invalidation mapping (R-02)', () {
    late ScriptedAdapter adapter;
    late List<FakeWsChannel> channels;
    late ConnectionController conn;
    late PlayerController player;
    bool serverDown = false;

    setUp(() async {
      serverDown = false;
      adapter = ScriptedAdapter(
        responder: (o) {
          if (serverDown) {
            throw networkError(
              o,
              socketFailure('Connection refused (ECONNREFUSED)', 111),
            );
          }
          switch (o.path) {
            case '/api/config':
              return jsonResponse(o, _configJson);
            case '/api/player':
              return jsonResponse(o, playerJson());
            case '/api/queue':
              return jsonResponse(o, _queueJson);
            default:
              return jsonResponse(o, <String, dynamic>{});
          }
        },
      );
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
            if (serverDown) c.handshakeFails = true;
            return c;
          },
        ),
      );
      player = PlayerController(connection: conn);
      await player.init();
      await conn.connectTo(_cfg);
      await pump();
    });

    tearDown(() {
      player.dispose();
      conn.dispose();
    });

    test('first slice is fetched on connect', () {
      expect(player.player, isNotNull);
      expect(player.player!.volume, 75);
      expect(player.nowPlaying, isNotNull);
      expect(player.nowPlaying!.title, 'Test Track');
    });

    test(
      'player-relevant WS events refetch; non-relevant events do not',
      () async {
        await pump();
        final before = playerFetches(adapter);

        channels.single.serverSend('{"notify":["database"]}');
        channels.single.serverSend('{"notify":["update"]}');
        await pump(30);
        expect(
          playerFetches(adapter),
          before,
          reason: 'database/update are not player-slice invalidations',
        );

        channels.single.serverSend('{"notify":["volume"]}');
        await pump(30);
        expect(playerFetches(adapter), greaterThan(before));
      },
    );

    test(
      'server-side change is visible in the slice within the WS cycle',
      () async {
        // The server changes the volume (paused-state action, unit 001
        // criterion 4): the `volume` event must bring the new value.
        var volume = 75;
        final savedResponder = adapter.responder;
        adapter.responder = (o) {
          if (o.path == '/api/player') {
            return jsonResponse(o, playerJson(volume: volume));
          }
          return savedResponder(o);
        };

        expect(player.player!.volume, 75);
        volume = 80;
        channels.single.serverSend('{"notify":["volume"]}');
        await pump(30);
        expect(player.player!.volume, 80);
      },
    );

    test('WS reconnect → refetchAll → the slice is refetched', () async {
      await pump();
      final before = playerFetches(adapter);

      channels.single.serverClose();
      await pump(300); // backoff 5/10/20ms…

      expect(conn.wsPhase, WsPhase.open);
      expect(playerFetches(adapter), greaterThan(before));
    });

    test('offline: actions are no-ops (no REST calls, no crash)', () async {
      serverDown = true;
      channels.single.serverClose();
      await pump(30);
      expect(conn.phase, ConnectionPhase.offline);

      final before = adapter.requests.length;
      await player.play();
      await player.pause();
      await player.next();
      await player.setVolume(50);
      await player.stepVolume(5);
      await player.seekMs(1234);
      expect(adapter.requests, hasLength(before));
      expect(player.syncError, isNull);

      // The server is back: actions work again.
      serverDown = false;
      await pump(300);
      expect(conn.phase, ConnectionPhase.connected);
      await player.setVolume(80);
      expect(
        adapter.requests.where((r) => r.contains('volume')).length,
        greaterThan(0),
      );
    });

    test('call arriving while paused does not claim the pause (D9)', () async {
      expect(player.player!.isPlaying, isFalse); // fixture: server paused
      player.onCallRinging();
      await pump(30);
      // The server was not playing, so nothing may have been sent — and
      // call-end must not resume playback either.
      final before = adapter.requests.length;
      await player.onCallEnded();
      expect(adapter.requests, hasLength(before));
    });
  });
}
