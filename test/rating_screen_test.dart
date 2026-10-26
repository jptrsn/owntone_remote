import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/library/library_models.dart';
import 'package:owntone_remote/src/outputs/outputs_controller.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/queue/queue_controller.dart';
import 'package:owntone_remote/src/rating/rating_controller.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';
import 'package:owntone_remote/src/ui/browse_screens.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// R-12 (unit 006) widget surface: stars on track rows matching the server
/// (C1), tap-to-set with optimistic update + rollback, the WS `database`
/// event refreshing a visible row (C4), and the now-playing rating (C2).
void main() {
  late RatingFixture fx;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late OutputsController outputs;
  late QueueController queue;
  late RatingController rating;
  late SettingsStore store;

  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);

  Future<void> wireUp() async {
    SharedPreferences.setMockInitialValues({});
    fx = RatingFixture();
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
          ],
          child: MaterialApp(home: screen),
        ),
      );

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

  const album = Album(
    id: '5741211977103795472',
    name: 'Absolution',
    artist: 'Muse',
    artistId: '2025221010526333778',
    trackCount: 3,
    lengthMs: 500000,
    year: 2003,
    uri: 'library:album:5741211977103795472',
  );

  Finder rowWithLabel(String label) => find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == label,
  );

  Finder starsLabel(int stars) => rowWithLabel('Rating: $stars of 5 stars');

  Future<void> tapStar(WidgetTester tester, Finder row, int star) async {
    await tester.tap(
      find.descendant(of: row, matching: find.byKey(ValueKey('rate-$star'))),
    );
    await settle(tester);
  }

  group('R-12 track rows', () {
    testWidgets('rows show stars matching the server (C1 wiring)', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, AlbumTracksScreen(album: album));
      await settle(tester);

      // Server ratings: Intro 40 → 2, Apocalypse Please (absent) → 0,
      // Butterflies 100 → 5 (fixture below).
      expect(rowWithLabel('Intro, track 1, 0:22, 2 stars'), findsOneWidget);
      expect(
        rowWithLabel('Apocalypse Please, track 2, 2:58, 0 stars'),
        findsOneWidget,
      );
      expect(
        rowWithLabel('Butterflies and Hurricanes, track 3, 4:12, 5 stars'),
        findsOneWidget,
      );
      // Glyphs themselves: 2 + 0 + 5 = 7 filled of 15.
      expect(find.byIcon(Icons.star), findsNWidgets(7));
      expect(find.byIcon(Icons.star_border), findsNWidgets(8));
    });

    testWidgets('tap star 5: optimistic 5 + one PUT rating=100', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, AlbumTracksScreen(album: album));
      await settle(tester);

      final row = rowWithLabel('Intro, track 1, 0:22, 2 stars');
      await tapStar(tester, row, 5);

      expect(
        adapter.requests,
        contains('PUT /api/library/tracks/2428?rating=100'),
      );
      // The star control shows the optimistic value immediately (the row's
      // semantics label keeps the server value — the `database` event's
      // list reload replaces both with the truth, per the WS test below).
      expect(find.descendant(of: row, matching: starsLabel(5)), findsOneWidget);
    });

    testWidgets('re-tap the set star clears to 0 (all 6 values reachable)', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, AlbumTracksScreen(album: album));
      await settle(tester);

      final row = rowWithLabel('Intro, track 1, 0:22, 2 stars');
      await tapStar(tester, row, 2); // star 2 == the current level → clear
      expect(
        adapter.requests,
        contains('PUT /api/library/tracks/2428?rating=0'),
      );
      expect(find.descendant(of: row, matching: starsLabel(0)), findsOneWidget);
    });

    testWidgets('failed PUT: rollback + typed snackbar', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, AlbumTracksScreen(album: album));
      await settle(tester);
      fx.failPut = true;

      final row = rowWithLabel('Intro, track 1, 0:22, 2 stars');
      await tapStar(tester, row, 4);

      // Rolled back to the server value, error surfaced.
      expect(find.descendant(of: row, matching: starsLabel(2)), findsOneWidget);
      expect(
        find.textContaining('Rating failed — server answered HTTP 500'),
        findsOneWidget,
      );
    });

    testWidgets('WS database event updates the visible row (C4)', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, AlbumTracksScreen(album: album));
      await settle(tester);
      expect(
        rowWithLabel('Apocalypse Please, track 2, 2:58, 0 stars'),
        findsOneWidget,
      );

      // Another client (the web UI) rates it 60 — no app interaction.
      await tester.runAsync(() async {
        fx.ratings[2429] = 60;
        channels.last.serverSend('{"notify":["database"]}');
      });
      await settle(tester);
      expect(
        rowWithLabel('Apocalypse Please, track 2, 2:58, 3 stars'),
        findsOneWidget,
      );
    });
  });

  group('R-12 now playing (C2)', () {
    Finder npStars() => find.byKey(const ValueKey('now-playing-rating'));

    testWidgets('shows the current track rating (floor-quantized)', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const NowPlayingScreen());
      await settle(tester);

      // Fixture: track 42, rating 60 → 3 stars.
      expect(npStars(), findsOneWidget);
      expect(
        find.descendant(of: npStars(), matching: starsLabel(3)),
        findsOneWidget,
      );
    });

    testWidgets('settable: tap star 4 → PUT rating=80 + optimistic', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const NowPlayingScreen());
      await settle(tester);

      await tester.tap(
        find.descendant(
          of: npStars(),
          matching: find.byKey(const ValueKey('rate-4')),
        ),
      );
      await settle(tester);
      expect(
        adapter.requests,
        contains('PUT /api/library/tracks/42?rating=80'),
      );
      expect(
        find.descendant(of: npStars(), matching: starsLabel(4)),
        findsOneWidget,
      );
    });

    testWidgets('WS database event refreshes the now-playing rating', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const NowPlayingScreen());
      await settle(tester);

      await tester.runAsync(() async {
        fx.ratings[42] = 100;
        channels.last.serverSend('{"notify":["database"]}');
      });
      await settle(tester);
      expect(
        find.descendant(of: npStars(), matching: starsLabel(5)),
        findsOneWidget,
      );
    });
  });
}

/// Paused player on track 42 (rating 60); one album with three tracks at
/// ratings 40 / absent / 100; per-track mutable ratings on the server.
class RatingFixture {
  final Map<int, int?> ratings = {42: 60, 2428: 40, 2429: null, 2430: 100};

  bool failPut = false;

  Response<dynamic> handle(RequestOptions o) {
    final p = o.uri.path;
    switch (p) {
      case '/api/config':
        return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
      case '/api/player':
        return jsonResponse(o, {
          'state': 'pause',
          'repeat': 'off',
          'consume': false,
          'shuffle': false,
          'volume': 50,
          'item_id': 196174,
          'item_length_ms': 100000,
          'item_progress_ms': 1000,
        });
      case '/api/queue':
        return jsonResponse(o, {
          'items': [
            {
              'id': '196174',
              'track_id': 42,
              'title': 'Skunk',
              'artist': 'Thundersmack',
              'album': 'Brass',
              'length_ms': 100000,
              'uri': 'library:track:42',
            },
          ],
        });
      case '/api/outputs':
        return jsonResponse(o, {'outputs': []});
      case '/api/library/albums/5741211977103795472/tracks':
        return jsonResponse(o, {
          'items': [
            track(2428, 'Intro', 1, 22177),
            track(2429, 'Apocalypse Please', 2, 178776),
            track(2430, 'Butterflies and Hurricanes', 3, 252000),
          ],
          'total': 3,
          'offset': 0,
          'limit': 50,
        });
    }
    if (p.startsWith('/api/library/tracks/')) {
      final id = int.parse(p.substring('/api/library/tracks/'.length));
      if (o.method == 'PUT') {
        if (failPut) {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 500),
          );
        }
        final q = o.uri.queryParameters;
        ratings[id] = int.parse(q['rating']!);
        return Response(requestOptions: o, statusCode: 204);
      }
      return jsonResponse(o, {
        'id': id,
        'title': 'Track $id',
        'artist': 'A',
        'album': 'B',
        'album_id': '1',
        'length_ms': 100000,
        if (ratings[id] != null) 'rating': ratings[id],
        'uri': 'library:track:$id',
      });
    }
    return Response(requestOptions: o, statusCode: 404);
  }

  Map<String, dynamic> track(int id, String title, int num, int len) => {
    'id': id,
    'title': title,
    'artist': 'Muse',
    'album': 'Absolution',
    'album_id': '5741211977103795472',
    'track_number': num,
    'length_ms': len,
    if (ratings[id] != null) 'rating': ratings[id],
    'uri': 'library:track:$id',
  };
}
