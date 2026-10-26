import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/outputs/outputs_controller.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/queue/queue_controller.dart';
import 'package:owntone_remote/src/rating/rating_controller.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';
import 'package:owntone_remote/src/ui/queue_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// R-11 (unit 005b C2): the queue screen against fakes — server-order rows,
/// the now-playing highlight (the live-verified `item_id` = entry-`id`
/// match), clear (optimistic + rollback), WS `queue` refresh, offline
/// behaviour, and the play action's single add call.
void main() {
  late Fixture fx;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late OutputsController outputs;
  late QueueController queue;
  late RatingController rating;
  late SettingsStore store;

  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);

  /// [configure] runs before the connection is made, so controllers' first
  /// fetches already see the configured fixture state.
  Future<void> wireUp({void Function(Fixture)? configure}) async {
    SharedPreferences.setMockInitialValues({});
    fx = Fixture();
    configure?.call(fx);
    adapter = ScriptedAdapter(responder: fx.handle);
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
          if (fx.serverDown) c.handshakeFails = true;
          return c;
        },
      ),
    );
    player = PlayerController(connection: conn);
    await player.init();
    outputs = OutputsController(connection: conn);
    await outputs.init();
    queue = QueueController(connection: conn);
    await queue.init();
    rating = RatingController(connection: conn, player: player);
    await rating.init();
    store = SettingsStore(await SharedPreferences.getInstance());
    await conn.connectTo(cfg);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  Future<void> pumpScreen(WidgetTester tester, Widget screen) =>
      tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<SettingsStore>.value(value: store),
            ChangeNotifierProvider<ConnectionController>.value(value: conn),
            ChangeNotifierProvider<PlayerController>.value(value: player),
            ChangeNotifierProvider<OutputsController>.value(value: outputs),
            ChangeNotifierProvider<QueueController>.value(value: queue),
            ChangeNotifierProvider<RatingController>.value(value: rating),
            ChangeNotifierProvider<RatingController>.value(value: rating),
          ],
          child: MaterialApp(home: screen),
        ),
      );

  /// Lets the (fake) network futures complete, then renders frames.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  tearDown(() {
    rating.dispose();
    queue.dispose();
    outputs.dispose();
    player.dispose();
    conn.dispose();
  });

  /// Rows are asserted through their compound semantics label
  /// (`<title>[, now playing][, artist · album]` — no numbers in rows,
  /// user call 2026-10-26) — via the Semantics widget itself:
  /// `bySemanticsLabel` needs the semantics tree, which plain widget tests
  /// do not enable.
  Finder row(String title, {bool nowPlaying = false}) {
    final label =
        '$title'
        '${nowPlaying ? ', now playing' : ''}, Muse · Absolution';
    return find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == label,
    );
  }

  Finder nowPlayingRows() => find.byWidgetPredicate(
    (w) =>
        w is Semantics && w.properties.label?.contains('now playing') == true,
  );

  group('R-11 rendering + highlight', () {
    testWidgets('rows in server order; the item_id row is highlighted', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      // Server order, with title + artist · album + length.
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.text('Muse · Absolution'), findsWidgets);
      expect(find.text('Blues in the Attic'), findsOneWidget);
      expect(find.text('House Party'), findsOneWidget);

      // The highlight: item_id 196174 = the first entry's id.
      expect(row('Skunk', nowPlaying: true), findsOneWidget);
      expect(row('Blues in the Attic'), findsOneWidget);
      expect(row('Blues in the Attic', nowPlaying: true), findsNothing);
      // The highlighted row carries the play icon, the others numbers.
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('highlight follows item_id — not track_id (live-verified)', (
      tester,
    ) async {
      // item_id = a track_id no entry id holds: no highlight.
      await tester.runAsync(() => wireUp(configure: (f) => f.itemId = 1195));
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(nowPlayingRows(), findsNothing);

      // item_id = the second entry's id: that row highlights.
      fx.itemId = 196175;
      await tester.runAsync(() => player.refreshState());
      await settle(tester);
      expect(row('Blues in the Attic', nowPlaying: true), findsOneWidget);
      expect(row('Skunk', nowPlaying: true), findsNothing);
    });

    testWidgets('stopped server (no item_id): no highlight', (tester) async {
      await tester.runAsync(() => wireUp(configure: (f) => f.itemId = null));
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(nowPlayingRows(), findsNothing);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });

    testWidgets('empty queue: icon + message', (tester) async {
      await tester.runAsync(() => wireUp(configure: (f) => f.items.clear()));
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(find.text('The queue is empty.'), findsOneWidget);
    });

    testWidgets('first-fetch failure: error state + retry recovers', (
      tester,
    ) async {
      await tester.runAsync(
        () => wireUp(configure: (f) => f.failQueueGet = true),
      );
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(find.text('Could not load the queue.'), findsOneWidget);

      fx.failQueueGet = false;
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.text('Skunk'), findsOneWidget);
    });
  });

  group('R-11 clear', () {
    testWidgets('confirm → optimistic empty, one PUT /api/queue/clear', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      await tester.tap(find.byTooltip('Clear queue'));
      await tester.pump();
      expect(find.text('Clear the queue?'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      await settle(tester);
      expect(adapter.requests, contains('PUT /api/queue/clear'));
      expect(find.text('The queue is empty.'), findsOneWidget);
      expect(find.text('Skunk'), findsNothing);
    });

    testWidgets('cancel keeps the rows and sends nothing', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      await tester.tap(find.byTooltip('Clear queue'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(find.text('Skunk'), findsOneWidget);
      expect(adapter.requests.where((r) => r.contains('clear')), isEmpty);
    });

    testWidgets('failed clear: rollback + snackbar', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      fx.failClear = true;

      await tester.tap(find.byTooltip('Clear queue'));
      await tester.pump();
      await tester.tap(find.text('Clear'));
      await settle(tester);

      // The rows came back (rollback) and the typed error is shown.
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.textContaining('Clear queue failed'), findsOneWidget);
    });
  });

  group('R-11 play from the queue (C1 wire)', () {
    testWidgets('row tap → one add call, clear + playback=start', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      await tester.tap(find.text('House Party'));
      await settle(tester);
      expect(
        adapter.requests,
        contains(
          'POST /api/queue/items/add'
          '?uris=library%3Atrack%3A1193&clear=true&playback=start',
        ),
      );
    });

    testWidgets('failed play: snackbar, queue unchanged', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      fx.failPlay = true;

      await tester.tap(find.text('House Party'));
      await settle(tester);
      expect(find.textContaining('Play failed'), findsOneWidget);
      expect(find.text('House Party'), findsOneWidget);
    });
  });

  group('R-11 refresh (R-02)', () {
    testWidgets('WS queue event (external change) refetches', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(find.text('Skunk'), findsOneWidget);

      // An external client (web UI) adds a track → the server notifies.
      await tester.runAsync(() async {
        fx.items.insert(0, Fixture.track(200001, 0, 'New Track', 1201, 300000));
        fx.renumber();
        channels.last.serverSend('{"notify":["queue"]}');
      });
      await settle(tester);
      expect(find.text('New Track'), findsOneWidget);
    });

    testWidgets('reconnect refetches the queue', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      // The server drops and stays down (failed handshakes), so the
      // backoff retries keep the app in its offline window.
      await tester.runAsync(() async {
        fx.serverDown = true;
        channels.last.serverClose();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      // Offline: the banner is up and the stale rows stay.
      await settle(tester);
      expect(find.textContaining('Queue disabled'), findsOneWidget);
      expect(find.text('Skunk'), findsOneWidget);

      // The queue changes while we are out; the server comes back and the
      // backoff reconnect lands.
      await tester.runAsync(() async {
        fx.items.insert(
          0,
          Fixture.track(200002, 0, 'Offline Change', 1202, 400000),
        );
        fx.renumber();
        fx.serverDown = false;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await settle(tester);
      expect(find.textContaining('Queue disabled'), findsNothing);
      expect(find.text('Offline Change'), findsOneWidget);
    });
  });

  group('R-11 offline', () {
    testWidgets('offline: banner + stale rows, taps inert', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      await tester.runAsync(() async {
        fx.serverDown = true;
        channels.last.serverClose();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await settle(tester);
      expect(
        find.text('Server unreachable — retrying. Queue disabled.'),
        findsOneWidget,
      );
      expect(find.text('Skunk'), findsOneWidget);

      // Taps do nothing while offline (no add call is recorded — the
      // backoff retries also hit the adapter, so compare on the add path).
      final addsBefore = adapter.requests
          .where((r) => r.contains('/items/add'))
          .length;
      await tester.tap(find.text('Skunk'));
      await settle(tester);
      expect(
        adapter.requests.where((r) => r.contains('/items/add')).length,
        addsBefore,
      );
    });
  });

  testWidgets('now-playing entry: "Queue · N" opens the queue screen', (
    tester,
  ) async {
    await tester.runAsync(wireUp);
    await pumpScreen(tester, const NowPlayingScreen());
    await settle(tester);
    expect(find.text('Queue · 3'), findsOneWidget);

    await tester.tap(find.text('Queue · 3'));
    await settle(tester);
    expect(find.text('Skunk'), findsOneWidget);
  });
}

/// A minimal live-shaped fixture: the three-item queue, a mutable player
/// item_id, and per-endpoint failure switches.
class Fixture {
  int? itemId = 196174;

  final List<Map<String, dynamic>> items = [
    track(196174, 0, 'Skunk', 1195, 343835),
    track(196175, 1, 'Blues in the Attic', 1194, 242640),
    track(196176, 2, 'House Party', 1193, 250720),
  ];

  bool failQueueGet = false;
  bool failClear = false;
  bool failPlay = false;

  /// While true, REST calls fail and new WS handshakes fail — the app stays
  /// in its offline state until this is cleared (the unit 002 dropServer
  /// pattern), so a test can observe the offline window before the backoff
  /// reconnect lands.
  bool serverDown = false;

  static Map<String, dynamic> track(
    int id,
    int position,
    String title,
    int trackId,
    int lengthMs,
  ) => {
    'id': id,
    'position': position,
    'track_id': trackId,
    'title': title,
    'artist': 'Muse',
    'album': 'Absolution',
    'length_ms': lengthMs,
    'uri': 'library:track:$trackId',
  };

  /// Keep the wire `position` field in list order (the server always does).
  void renumber() {
    for (var i = 0; i < items.length; i++) {
      items[i]['position'] = i;
    }
  }

  Map<String, dynamic> get _playerJson => {
    'state': 'stop',
    'volume': 50,
    'item_id': itemId,
    'item_length_ms': 343835,
    'item_progress_ms': 0,
  };

  Response<dynamic> handle(RequestOptions o) {
    if (serverDown) {
      throw networkError(
        o,
        socketFailure('Connection refused (ECONNREFUSED)', 111),
      );
    }
    final p = o.uri.path;
    if (p.startsWith('/api/queue') && failQueueGet && o.method == 'GET') {
      throw DioException(
        requestOptions: o,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: o, statusCode: 500),
      );
    }
    switch (p) {
      case '/api/config':
        return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
      case '/api/player':
        return jsonResponse(o, _playerJson);
      case '/api/outputs':
        return jsonResponse(o, {'outputs': []});
      case '/api/queue':
        return jsonResponse(o, {
          'version': 1,
          'count': items.length,
          'items': items,
        });
      case '/api/queue/clear':
        if (failClear) {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 500),
          );
        }
        items.clear();
        return Response(requestOptions: o, statusCode: 204);
      case '/api/queue/items/add':
        if (failPlay) {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 500),
          );
        }
        final q = o.uri.queryParameters;
        final uris = (q['uris'] ?? '').split(',');
        final shouldClear = q['clear'] == 'true';
        if (shouldClear) items.clear();
        // Expand each uri as one fresh entry (the server expands containers;
        // the fixture's uris are all tracks).
        for (var i = 0; i < uris.length; i++) {
          final m = RegExp(r'library:track:(\d+)').firstMatch(uris[i]);
          items.add(
            track(
              200000 + i,
              items.length,
              'Added ${uris[i]}',
              int.parse(m?.group(1) ?? '0'),
              100000,
            ),
          );
        }
        return jsonResponse(o, {
          'version': 2,
          'count': items.length,
          'items': items,
        });
      default:
        return Response(requestOptions: o, statusCode: 404);
    }
  }
}
