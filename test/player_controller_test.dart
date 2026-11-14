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

  // Unit 012 (unit-011's unguarded-`_refresh` candidate, Player side):
  // R-04 "transport state reflects the server" + R-02 (D2 event → refetch)
  // require per-event `GET /api/player` refreshes to be serialized — one
  // in flight, coalesced trailing refetch, and a superseded response can
  // never overwrite a newer slice. Zone note (from unit 011): these are
  // plain `test`s, so Completers/responses tick on the real event loop —
  // the gates here are polling flags driven by real time.
  group('R-04 refresh serialization (unit 012)', () {
    late ScriptedAdapter adapter;
    late List<FakeWsChannel> channels;
    late ConnectionController conn;
    late PlayerController player;

    var serverVolume = 75;
    var inFlight = 0;
    var maxInFlight = 0;
    var playerArrivals = 0;
    var holdFirst = false;
    var holdArrival = 0;
    var releaseA = false;

    Future<Response<dynamic>> respond(RequestOptions o) async {
      switch (o.path) {
        case '/api/config':
          return jsonResponse(o, _configJson);
        case '/api/queue':
          return jsonResponse(o, _queueJson);
        case '/api/player/volume':
          final v = o.queryParameters['volume'];
          if (v != null) serverVolume = int.parse('$v');
          return jsonResponse(o, <String, dynamic>{});
        case '/api/player':
          inFlight++;
          playerArrivals++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          final vol = serverVolume; // snapshot at REQUEST time
          // Hold ONLY the first arrival — so a concurrent (unguarded)
          // impl's later fetches answer promptly and deterministically
          // clobber instead of also hanging. Real-timer polling is
          // safe in a plain test (the unit-011 fake-clock trap does
          // not apply here).
          if (holdFirst && playerArrivals == holdArrival) {
            final deadline = DateTime.now().add(const Duration(seconds: 2));
            while (!releaseA && DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
          }
          inFlight--;
          return jsonResponse(o, playerJson(volume: vol));
        default:
          return jsonResponse(o, <String, dynamic>{});
      }
    }

    Future<void> holdFetch() async {
      // Arm on the NEXT arrival (the initial load already consumed a
      // count — arming on a fixed index would never hold).
      holdArrival = playerArrivals + 1;
      holdFirst = true;
      releaseA = false;
    }

    Future<void> releaseFetch() async {
      releaseA = true;
      holdFirst = false;
    }

    setUp(() async {
      serverVolume = 75;
      inFlight = 0;
      maxInFlight = 0;
      playerArrivals = 0;
      holdFirst = false;
      releaseA = false;
      adapter = ScriptedAdapter(responder: respond);
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
      await conn.connectTo(_cfg);
      await pump();
    });

    tearDown(() {
      releaseA = true; // never leave a held fetch after a test
      player.dispose();
      conn.dispose();
    });

    test('a superseded player fetch answering late must not clobber the '
        'newer slice (stale-write race)', () async {
      // The next volume event's fetch holds, answering from a
      // request-time snapshot of volume.
      await holdFetch();
      // Event → fetch A starts (holds) holding volume 75.
      channels.single.serverSend('{"notify":["volume"]}');
      await pump(20);
      // Server volume changes while A is in flight; a second event
      // arrives on the same flight → after A lands the trailing fetch
      // must bring the new value.
      serverVolume = 42;
      channels.single.serverSend('{"notify":["volume"]}');
      await pump(20);
      await releaseFetch();
      await pump(60); // let the release propagate + trailing chain land
      expect(
        player.player!.volume,
        42,
        reason:
            'the stale response from the superseded fetch overwrote '
            'the newer slice (unit 012: per-event refreshes must be '
            'serialized)',
      );
    });

    test('a burst of volume events keeps at most one GET in flight and '
        'the mid-burst change still lands (trailing refetch)', () async {
      await holdFetch();
      // Event 1 → fetch A starts against volume 75.
      channels.single.serverSend('{"notify":["volume"]}');
      await pump(20);
      expect(playerArrivals, greaterThanOrEqualTo(1));
      // The mid-burst change lands only AFTER A's request has arrived;
      // four more events pile on that same flight.
      serverVolume = 42;
      final probeStart = playerArrivals;
      for (var i = 0; i < 4; i++) {
        channels.single.serverSend('{"notify":["volume"]}');
        await pump(10);
      }
      expect(
        playerArrivals,
        probeStart,
        reason:
            'burst events must coalesce, not start new flights while A '
            'is in flight (single-flight, unit 012)',
      );
      await releaseFetch();
      await pump(60);
      expect(
        playerArrivals,
        probeStart + 1,
        reason:
            'A plus EXACTLY one coalesced trailing refetch — more GETs '
            'mean per-event fetches slipped through the guard, none '
            'means the trailing refetch was lost (unit 012)',
      );
      expect(
        maxInFlight,
        1,
        reason:
            'per-event refreshes must be single-flight: $maxInFlight '
            'concurrent GET /api/player observed (unit 012)',
      );
      expect(
        player.player!.volume,
        42,
        reason:
            'the mid-burst change must be present after settle '
            '(R-04: transport state reflects the server)',
      );
    });

    test('a resolved action with a fetch in flight re-reads post-commit '
        'state (action-demand contract)', () async {
      // Event → fetch A starts and holds, its response answering from the
      // PRE-action volume 75 (request-time snapshot).
      await holdFetch();
      channels.single.serverSend('{"notify":["volume"]}');
      await pump(20);
      final preAction = playerArrivals;
      // The action's PUT commits volume 42 to the fake server while A is
      // still in flight. A's in-flight chain has already asked the
      // responder, so its response can only ever carry 75 — the only way
      // the slice can end at 42 is a re-read AFTER the commit: the
      // action must demand one (coalescing its confirming read onto A's
      // pre-commit answer is the unit-011 round-1 bug shape this pins —
      // red under a coalesce-without-demand regression, like M2 reds it
      // under trailing removal; see unit Result M3 notes).
      final action = player.setVolume(42);
      await pump(20); // PUT committed; the confirming call sees A in flight
      await releaseFetch(); // A answers with the stale pre-commit 75
      await action;
      await pump(60);
      expect(
        player.player!.volume,
        42,
        reason:
            'the action resolved against a pre-commit fetch — the slice '
            'is stale (unit 012 criterion 1c: a resolved action must '
            're-read post-commit state)',
      );
      expect(
        playerArrivals,
        preAction + 1,
        reason:
            'A plus EXACTLY one post-commit trailing chain (the action '
            'demanded a re-read; none means it coalesced onto the '
            'pre-commit fetch)',
      );
    });
  });
}
