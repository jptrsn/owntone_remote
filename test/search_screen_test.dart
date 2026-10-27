import 'dart:math' show min;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/queue/queue_controller.dart';
import 'package:owntone_remote/src/ui/browse_rows.dart';
import 'package:owntone_remote/src/ui/browse_screens.dart';
import 'package:owntone_remote/src/ui/search_screen.dart';
import 'package:provider/provider.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

/// R-13 (unit 007) fixture: `/api/search` answers one `paging` object per
/// requested type (the shape verified live 2026-10-26), sliced by the
/// per-group `offset`/`limit`. The query `match` hits every group (60
/// tracks — three pages at the app's 25-per-page); anything else returns
/// empty groups. Detail endpoints back the tap-through checks.
class SearchFixture {
  SearchFixture();

  bool failSearch = false;

  final List<Map<String, dynamic>> tracks = [
    for (var i = 1; i <= 60; i++)
      {
        'id': 100 + i,
        'title': 'Song $i',
        'artist': 'The Singer',
        'album': 'Matched Album',
        'album_id': 'alMatch',
        'length_ms': 181000,
        'rating': i == 1 ? 40 : 0,
        'uri': 'library:track:${100 + i}',
      },
  ];

  final List<Map<String, dynamic>> artists = [
    {
      'id': 'aMatch',
      'name': 'Singer One',
      'album_count': 1,
      'track_count': 60,
      'length_ms': 9000000,
    },
    {
      'id': 'aTwo',
      'name': 'Singer Two',
      'album_count': 0,
      'track_count': 2,
      'length_ms': 300000,
    },
  ];

  final List<Map<String, dynamic>> albums = [
    {
      'id': 'alMatch',
      'name': 'Matched Album',
      'artist': 'Singer One',
      'artist_id': 'aMatch',
      'track_count': 2,
      'length_ms': 400000,
      'year': 2021,
      'uri': 'library:album:alMatch',
    },
  ];

  final List<Map<String, dynamic>> playlists = [
    {
      'id': 90,
      'name': 'Matched List',
      'type': 'plain',
      'smart_playlist': false,
      'folder': false,
      'item_count': 1,
      'uri': 'library:playlist:90',
    },
  ];

  /// Tap-through targets (the existing detail screens' endpoints).
  final List<Map<String, dynamic>> alMatchTracks = [
    {
      'id': 7001,
      'title': 'Matched Track',
      'artist': 'Singer One',
      'album': 'Matched Album',
      'album_id': 'alMatch',
      'length_ms': 123000,
      'uri': 'library:track:7001',
    },
  ];

  final List<Map<String, dynamic>> aMatchAlbums = [
    {
      'id': 'alAM',
      'name': 'Matched Artist Album',
      'artist': 'Singer One',
      'artist_id': 'aMatch',
      'track_count': 1,
      'length_ms': 100000,
    },
  ];

  final List<Map<String, dynamic>> pl90Tracks = [
    {
      'id': 7100,
      'title': 'Playlist Match Song',
      'artist': 'Singer One',
      'album': 'Matched Album',
      'album_id': 'alMatch',
      'length_ms': 200000,
      'uri': 'library:track:7100',
    },
  ];

  Map<String, dynamic> _page(
    List<Map<String, dynamic>> all,
    int offset,
    int limit,
  ) => {
    'items': offset < all.length
        ? all.sublist(offset, min(offset + limit, all.length))
        : <Map<String, dynamic>>[],
    'total': all.length,
    'offset': offset,
    'limit': limit,
  };

  Future<Response<dynamic>> handle(RequestOptions o) async {
    // From the URI, not `o.queryParameters`: the search query is embedded in
    // the path (unit 005a C4 encoding), so it is only visible here.
    final q = o.uri.queryParameters;
    switch (o.uri.path) {
      case '/api/config':
        return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
      case '/api/player':
        return jsonResponse(o, {'state': 'stop', 'volume': 36});
      case '/api/search':
        if (failSearch) {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 500),
          );
        }
        final query = q['query']?.toString() ?? '';
        final type = q['type']?.toString() ?? '';
        final off = int.tryParse(q['offset']?.toString() ?? '') ?? 0;
        final lim = int.tryParse(q['limit']?.toString() ?? '') ?? 25;
        final matched = query == 'match';
        final all = switch (type) {
          'tracks' => tracks,
          'artists' => artists,
          'albums' => albums,
          'playlists' => playlists,
          _ => const <Map<String, dynamic>>[],
        };
        return jsonResponse(o, {
          type: _page(matched ? all : const [], off, lim),
        });
      case '/api/library/albums/alMatch/tracks':
        return jsonResponse(o, _page(alMatchTracks, 0, 50));
      case '/api/library/artists/aMatch/albums':
        return jsonResponse(o, _page(aMatchAlbums, 0, 50));
      case '/api/library/playlists/90/tracks':
        return jsonResponse(o, _page(pl90Tracks, 0, 50));
      case '/api/queue':
        return jsonResponse(o, {
          'version': 1,
          'count': 0,
          'items': <Map<String, dynamic>>[],
        });
      case '/api/queue/items/add':
        return jsonResponse(o, {
          'version': 2,
          'count': 0,
          'items': <Map<String, dynamic>>[],
        });
      default:
        return Response(requestOptions: o, statusCode: 404);
    }
  }
}

void main() {
  late SearchFixture fx;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late QueueController queue;

  Future<void> wireUp() async {
    fx = SearchFixture();
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
    queue = QueueController(connection: conn);
    await queue.init();
    await conn.connectTo(_cfg);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  Future<void> pumpScreen(WidgetTester tester, Widget screen) =>
      tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ConnectionController>.value(value: conn),
            ChangeNotifierProvider<QueueController>.value(value: queue),
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

  /// Type a committed query (one burst; the debounce elapses on the pump).
  Future<void> typeQuery(WidgetTester tester, String q) async {
    await tester.enterText(find.byKey(const ValueKey('search-field')), q);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
  }

  /// A tall surface so the grouped ListView builds every row (its children
  /// are lazy below the viewport + cacheExtent — on the default 600 px
  /// height the albums/playlists groups never instantiate).
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(420, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  List<String> searchRequests(String type) => adapter.requests
      .where((r) => r.contains('/api/search') && r.contains('type=$type'))
      .toList();

  Finder rowWithLabel(String label) => find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.label == label,
  );

  tearDown(() {
    queue.dispose();
    conn.dispose();
  });

  group('R-13 entry point + empty query', () {
    testWidgets('library home gains a Search entry → opens SearchScreen', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const LibraryHomeScreen());
      await tester.pump();
      expect(find.text('Search'), findsOneWidget);
      // The four browse sections are untouched.
      for (final s in ['Playlists', 'Artists', 'Albums', 'Genres']) {
        expect(find.text(s), findsOneWidget);
      }
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('search-field')), findsOneWidget);
    });

    testWidgets('empty query: idle hint, zero search requests', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await settle(tester);
      expect(find.text('Type to search the library.'), findsOneWidget);
      expect(
        adapter.requests.where((r) => r.contains('/api/search')),
        isEmpty,
        reason: 'the empty query must never hit the server',
      );
    });

    testWidgets('clearing the query returns to idle', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await typeQuery(tester, 'match');
      expect(find.text('Song 1'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('search-clear')));
      await settle(tester);
      expect(find.text('Type to search the library.'), findsOneWidget);
      expect(find.text('Song 1'), findsNothing);
    });

    testWidgets('typing is debounced — one request burst', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await tester.enterText(find.byKey(const ValueKey('search-field')), 'm');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byKey(const ValueKey('search-field')), 'ma');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const ValueKey('search-field')),
        'match',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(searchRequests('tracks'), hasLength(1));
      expect(find.text('Song 1'), findsOneWidget);
    });
  });

  group('R-13 grouped results (acceptance: "a query returns grouped '
      'results with correct pagination")', () {
    testWidgets('all four groups render, header + rows', (tester) async {
      useTallSurface(tester);
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await typeQuery(tester, 'match');
      // Group headers carry the server total (evidence + dedupe sanity).
      expect(find.byKey(const ValueKey('search-group-tracks')), findsOneWidget);
      expect(find.text('Tracks · 60'), findsOneWidget);
      expect(find.text('Artists · 2'), findsOneWidget);
      expect(find.text('Albums · 1'), findsOneWidget);
      expect(find.text('Playlists · 1'), findsOneWidget);
      // One row from each group.
      expect(find.text('Song 1'), findsOneWidget);
      expect(find.text('Singer One'), findsOneWidget);
      expect(find.text('Matched Album'), findsOneWidget);
      expect(find.text('Matched List'), findsOneWidget);
      // Wire shape: the four type params went out.
      for (final t in ['tracks', 'artists', 'albums', 'playlists']) {
        expect(
          adapter.requests,
          contains('GET /api/search?type=$t&query=match&offset=0&limit=25'),
        );
      }
    });

    testWidgets('track rows reuse BrowseRow: no leading number, stars in '
        'the semantics label', (tester) async {
      useTallSurface(tester);
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await typeQuery(tester, 'match');
      // The unit-006-follow-up row shape, exact: '<title>, <artist>, M:SS, '
      // 'N stars' — no leading track number, no 'track N' in the label.
      expect(rowWithLabel('Song 1, The Singer, 3:01, 2 stars'), findsOneWidget);
      expect(rowWithLabel('Song 2, The Singer, 3:01, 0 stars'), findsOneWidget);
      final row = find.byWidgetPredicate(
        (w) =>
            w is BrowseRow &&
            w.semanticsLabel == 'Song 1, The Singer, 3:01, 2 stars',
      );
      expect(row, findsOneWidget);
      expect(
        tester.widget<BrowseRow>(row).semanticsLabel,
        isNot(contains('track ')),
      );
    });

    testWidgets('pagination per group — load-more pages, no duplicates', (
      tester,
    ) async {
      useTallSurface(tester);
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await typeQuery(tester, 'match');
      expect(searchRequests('tracks'), [
        'GET /api/search?type=tracks&query=match&offset=0&limit=25',
      ]);
      expect(find.text('Song 25'), findsOneWidget);
      expect(find.text('Song 26'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('load-more-tracks')));
      await settle(tester);
      expect(find.text('Song 26'), findsOneWidget);
      expect(find.text('Song 50'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('load-more-tracks')));
      await settle(tester);
      expect(searchRequests('tracks'), [
        'GET /api/search?type=tracks&query=match&offset=0&limit=25',
        'GET /api/search?type=tracks&query=match&offset=25&limit=25',
        'GET /api/search?type=tracks&query=match&offset=50&limit=25',
      ]);
      // Every row present exactly once across the three pages.
      for (final t in ['Song 1', 'Song 26', 'Song 60']) {
        expect(find.text(t), findsOneWidget, reason: '$t rendered once');
      }
      // Exhausted: the button is gone, no fourth page request.
      expect(find.byKey(const ValueKey('load-more-tracks')), findsNothing);
      expect(searchRequests('tracks'), hasLength(3));
      // The other groups did not page along.
      expect(searchRequests('artists'), hasLength(1));
    });
  });

  group('R-13 empty / no-results states (acceptance: "empty query / '
      'no-results states handled")', () {
    testWidgets('no-results is distinct from the empty-query hint', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await typeQuery(tester, 'zzz');
      expect(find.text('No results for "zzz".'), findsOneWidget);
      expect(
        find.text('Type to search the library.'),
        findsNothing,
        reason: 'the two states are never conflated',
      );
      expect(find.byKey(const ValueKey('search-no-results')), findsOneWidget);
    });

    testWidgets('search failure → error state + retry recovers', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await wireUp();
        fx.failSearch = true;
      });
      await pumpScreen(tester, const SearchScreen());
      await typeQuery(tester, 'match');
      expect(find.text('Could not load search results.'), findsOneWidget);
      expect(find.text('Server answered HTTP 500.'), findsOneWidget);
      expect(find.text('Type to search the library.'), findsNothing);
      expect(
        find.text('No results for "match".'),
        findsNothing,
        reason: 'a failure must never read as "no results"',
      );

      await tester.runAsync(() async {
        fx.failSearch = false;
      });
      await tester.tap(find.widgetWithText(FilledButton, 'Retry'));
      await settle(tester);
      expect(find.text('Song 1'), findsOneWidget);
    });
  });

  group('R-13 tap-through', () {
    testWidgets('album result → album tracks screen', (tester) async {
      useTallSurface(tester);
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await typeQuery(tester, 'match');
      await tester.tap(find.text('Matched Album'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(
        adapter.requests,
        contains('GET /api/library/albums/alMatch/tracks?offset=0&limit=50'),
      );
      expect(find.text('Matched Track'), findsOneWidget);
    });

    testWidgets('artist result → artist albums screen', (tester) async {
      useTallSurface(tester);
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await typeQuery(tester, 'match');
      await tester.tap(find.text('Singer One'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(
        adapter.requests,
        contains('GET /api/library/artists/aMatch/albums?offset=0&limit=50'),
      );
      expect(find.text('Matched Artist Album'), findsOneWidget);
    });

    testWidgets('playlist result → playlist tracks screen', (tester) async {
      useTallSurface(tester);
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await typeQuery(tester, 'match');
      await tester.tap(find.text('Matched List'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(
        adapter.requests,
        contains('GET /api/library/playlists/90/tracks?offset=0&limit=50'),
      );
      expect(find.text('Playlist Match Song'), findsOneWidget);
    });

    testWidgets('track row tap → play that track uri (fake — no network)', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await typeQuery(tester, 'match');
      await tester.tap(find.text('Song 1'));
      await settle(tester);
      expect(
        adapter.requests,
        contains(
          'POST /api/queue/items/add?uris=${Uri.encodeComponent('library:track:101')}'
          '&clear=true&playback=start',
        ),
      );
    });
  });

  group('R-13 viewport (unit 004 rule)', () {
    testWidgets('grouped results render at 360 logical px with no overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const SearchScreen());
      await typeQuery(tester, 'match');
      expect(find.text('Tracks · 60'), findsOneWidget);
      // RenderFlex overflow throws in the test binding — reaching here with
      // the results rendered is the assertion.
    });
  });
}
