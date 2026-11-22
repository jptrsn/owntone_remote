import 'dart:math' show min;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/library/library_models.dart';
import 'package:owntone_remote/src/library/paged_list.dart';
import 'package:owntone_remote/src/queue/queue_controller.dart';
import 'package:owntone_remote/src/ui/browse_screens.dart';
import 'package:owntone_remote/src/ui/paged_browse_list.dart';
import 'package:owntone_remote/src/ui/rating_stars.dart';
import 'package:provider/provider.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// R-15 (issue #38, diff-list D-02): the Songs (all-tracks) browse view.
/// Tests derived from the R-15 acceptance text — two-line rows
/// (`title` / `artist - album`), paging, the row play accessory calling
/// `playUris` with the track uri, the rating stars riding along (R-12),
/// reconnect refetch — plus the #48 section-header clause for Songs.
/// Network-free: scripted fake server behind the real [OwntoneApi].
const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

/// The fake's page size (the shared `PagedList` default — the same paging
/// contract as every other browse screen).
const _pageSize = 50;

/// R-15 fixture: 120 library tracks in the server's order — `title_sort`
/// sorted (the order `GET /api/search?type=tracks&query=` serves in,
/// source-verified 2026-11-20). The 60 A-block titles all start with
/// "The " (`title_sort` "A List N") so a section header "A" can only come
/// from grouping by the SERVER sort key, never by the display title.
List<Map<String, dynamic>> _library() => [
  for (var i = 1; i <= 120; i++)
    {
      'id': 5000 + i,
      'title': i <= 60 ? 'The A List $i' : 'Bee Line ${i - 60}',
      'title_sort': i <= 60 ? 'A List $i' : 'Bee Line ${i - 60}',
      'artist': 'Artist 1',
      'album': 'Album 1',
      'album_id': 'al1',
      'track_number': 1,
      'length_ms': 180000 + i * 1000,
      // Row 5 deviates (60 → 3 stars) so the star test can prove the
      // drawn star count follows the per-row server value (R-12), not a
      // hard-coded 1.
      'rating': i == 5 ? 60 : 20,
      'uri': 'library:track:${5000 + i}',
    },
];

class TracksFixture {
  TracksFixture();

  bool failLibrary = false;
  final List<Map<String, dynamic>> tracks = _library();

  Map<String, dynamic> _page(int offset, int limit) => {
    'items': offset < tracks.length
        ? tracks.sublist(offset, min(offset + limit, tracks.length))
        : <Map<String, dynamic>>[],
    'total': tracks.length,
    'offset': offset,
    'limit': limit,
  };

  Future<Response<dynamic>> handle(RequestOptions o) async {
    final p = o.uri.path;
    final q = o.uri.queryParameters;
    final off = int.tryParse((q['offset'] ?? '').toString()) ?? 0;
    final lim = int.tryParse((q['limit'] ?? '').toString()) ?? 50;
    if (p.startsWith('/api/library') || p == '/api/search') {
      if (failLibrary) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: o, statusCode: 500),
        );
      }
    }
    switch (p) {
      case '/api/config':
        return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
      case '/api/player':
        return jsonResponse(o, {'state': 'stop', 'volume': 36});
      case '/api/search':
        // The Songs endpoint (R-15): only the empty-query tracks group
        // answers; the wire shape (type/query/offset/limit) is asserted
        // from the outside via [ScriptedAdapter.requests].
        if (q['type'] != 'tracks' || q['query'] != '') {
          return jsonResponse(o, const {
            'tracks': {'items': [], 'total': 0, 'offset': 0, 'limit': 0},
          });
        }
        return jsonResponse(o, {'tracks': _page(off, lim)});
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
  late TracksFixture fx;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  // Null until [wireUp] — the pure model cases below never wire, and the
  // tearDown must not re-dispose the previous widget test's objects.
  ConnectionController? conn;
  QueueController? queue;

  Future<void> wireUp() async {
    fx = TracksFixture();
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
    final q = QueueController(connection: conn!);
    queue = q;
    await q.init();
    await conn!.connectTo(_cfg);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  Future<void> pumpScreen(WidgetTester tester, Widget screen) =>
      tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ConnectionController>.value(value: conn!),
            ChangeNotifierProvider<QueueController>.value(value: queue!),
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

  Future<void> scrollToEnd(WidgetTester tester) async {
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.jumpTo(position.maxScrollExtent);
    await settle(tester);
  }

  PagedList<Track> loadedList(WidgetTester tester) => tester
      .widget<PagedBrowseList<Track>>(
        find.byWidgetPredicate((w) => w is PagedBrowseList<Track>),
      )
      .list;

  /// dio form-encodes the uris value (`:` → %3A).
  String addReq(String uri) =>
      'POST /api/queue/items/add?uris=${Uri.encodeComponent(uri)}'
      '&clear=true&playback=start';

  tearDown(() {
    queue?.dispose();
    conn?.dispose();
    queue = null;
    conn = null;
  });

  group('R-15 Songs view', () {
    testWidgets('library home offers the Songs section', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const LibraryHomeScreen());
      await tester.pump();
      expect(find.text('Songs'), findsOneWidget);
    });

    testWidgets('Songs renders two-line rows: title / artist - album', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const LibraryHomeScreen());
      await tester.pump();
      await tester.tap(find.text('Songs'));
      await tester.pumpAndSettle();
      await settle(tester);

      expect(find.text('Songs'), findsOneWidget, reason: 'app bar title');
      expect(find.text('The A List 1'), findsOneWidget, reason: 'line 1');
      expect(
        find.text('Artist 1 - Album 1'),
        findsWidgets,
        reason: 'line 2 = "artist - album" (R-15)',
      );
      expect(find.text('3:01'), findsOneWidget, reason: 'row length');
    });

    testWidgets('row play accessory calls playUris with the track uri '
        '(R-15 / R-10, frozen repro)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const TracksScreen());
      await settle(tester);

      await tester.tap(find.text('The A List 1'));
      await settle(tester);
      expect(
        adapter.requests,
        contains(addReq('library:track:5001')),
        reason: 'row tap replaces the queue and starts (supervised wire)',
      );
    });

    testWidgets('rating stars ride on the rows (R-12, visual presence)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const TracksScreen());
      await settle(tester);

      expect(
        find.byWidgetPredicate((w) => w is RatingStars),
        findsWidgets,
        reason: 'the existing star control (R-12) is on the rows',
      );
      // The control's own semantics label must show the per-row server
      // value: fixture row 1 carries rating 20 → 1 star, row 5 carries
      // 60 → 3 stars (never tapped — display-only, no mutation).
      expect(
        find.semantics.byLabel('Rating: 1 of 5 stars'),
        findsWidgets,
        reason: 'rating 20 → 1 star (R-12 mapping)',
      );
      expect(
        find.semantics.byLabel('Rating: 3 of 5 stars'),
        findsWidgets,
        reason: 'rating 60 → 3 stars (value follows the row)',
      );
      handle.dispose();
    });

    testWidgets('page 2 loads at the fake page boundary; exhausted list '
        'stops requesting (R-15 paging)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const TracksScreen());
      await settle(tester);
      expect(
        adapter.requests,
        contains('GET /api/search?type=tracks&query=&offset=0&limit=50'),
      );

      await scrollToEnd(tester); // page 2
      await scrollToEnd(tester); // page 3
      await scrollToEnd(tester); // exhausted: no-op

      final requests = adapter.requests
          .where((r) => r.startsWith('GET /api/search?type=tracks'))
          .toList();
      expect(requests, [
        'GET /api/search?type=tracks&query=&offset=0&limit=$_pageSize',
        'GET /api/search?type=tracks&query=&offset=50&limit=$_pageSize',
        'GET /api/search?type=tracks&query=&offset=100&limit=$_pageSize',
      ]);
      final list = loadedList(tester);
      expect(list.items, hasLength(120));
      expect(list.items.map((t) => t.id).toSet(), hasLength(120));
      expect(list.items[50].title, 'The A List 51', reason: 'page-2 content');
      expect(list.items.last.title, 'Bee Line 60');
    });

    testWidgets('offline banner keeps stale rows; reconnect refetches '
        '(R-15 paging/reconnect contract)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const TracksScreen());
      await settle(tester);
      expect(find.text('The A List 1'), findsOneWidget);

      conn!.disconnect();
      await tester.pump();
      expect(
        find.text('Server unreachable — retrying. Browsing disabled.'),
        findsOneWidget,
      );
      expect(find.text('The A List 1'), findsOneWidget, reason: 'stale rows');

      await tester.runAsync(() async {
        fx.tracks.insert(0, {
          'id': 9999,
          'title': 'Aardvark Song',
          'title_sort': 'Aardvark Song',
          'artist': 'Artist 1',
          'album': 'Album 1',
          'album_id': 'al1',
          'length_ms': 200000,
          'uri': 'library:track:9999',
        });
        await conn!.connectTo(_cfg);
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await settle(tester);
      expect(
        find.text('Aardvark Song'),
        findsOneWidget,
        reason: 'refetched after the reconnect',
      );
    });

    testWidgets('empty library → empty state', (tester) async {
      await tester.runAsync(() async {
        await wireUp();
        fx.tracks.clear();
      });
      await pumpScreen(tester, const TracksScreen());
      await settle(tester);
      expect(find.text('No tracks in the library.'), findsOneWidget);
    });

    testWidgets('first-page failure → error state, retry recovers', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await wireUp();
        fx.failLibrary = true;
      });
      await pumpScreen(tester, const TracksScreen());
      await settle(tester);
      expect(find.text('Could not load tracks.'), findsOneWidget);
      expect(find.text('Server answered HTTP 500.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await tester.runAsync(() async {
        fx.failLibrary = false;
      });
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.text('The A List 1'), findsOneWidget);
    });

    testWidgets('Songs renders the A section header — by title_sort, not '
        'the display title (R-25 via the #48 Songs clause)', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const TracksScreen());
      await settle(tester);

      // One "A" header over the first (all-A) page — and NOT a "T" one:
      // grouping uses title_sort, the order the server serves in. (The
      // boundary-emission rule itself — once per transition across pages
      // and reloads — is pinned in paged_browse_headers_test.dart.)
      expect(find.text('A'), findsOneWidget);
      expect(find.text('T'), findsNothing);
      final data = tester.getSemantics(find.text('A')).getSemanticsData();
      expect(data.flagsCollection.isHeader, isTrue);
      handle.dispose();
    });

    testWidgets('page-2 A→B boundary renders a B header on Songs (R-25)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const TracksScreen());
      await settle(tester);
      // Bring page 2 in (rows 51–100: the A→B boundary sits at 61).
      await tester.runAsync(() => loadedList(tester).loadNext());
      await settle(tester);

      await tester.dragUntilVisible(
        find.text('B'),
        find.byType(Scrollable),
        const Offset(0, -300),
      );
      await settle(tester);
      // Exactly one built "B" header row at the boundary (a duplicated
      // boundary header would render two adjacent B rows here), and it is
      // a semantics heading. (Counting all isHeader nodes would also see
      // the app-bar title node — checked via the node's own label instead,
      // same pattern as the A-header case above.)
      expect(find.text('B'), findsOneWidget);
      final data = tester.getSemantics(find.text('B')).getSemanticsData();
      expect(data.flagsCollection.isHeader, isTrue);
      handle.dispose();
    });
  });

  group('R-15/R-25 Track sort key', () {
    test('sortTitle = title_sort when present, title otherwise', () {
      const sorted = Track(
        id: 1488,
        title: 'The A Team',
        artist: 'Ed Sheeran',
        album: '+',
        albumId: '1',
        lengthMs: 1000,
        uri: 'library:track:1488',
        titleSort: 'A Team',
      );
      expect(sorted.sortTitle, 'A Team');
      const bare = Track(
        id: 1,
        title: 'Zephyr',
        artist: 'a',
        album: 'b',
        albumId: '2',
        lengthMs: 1000,
        uri: 'library:track:1',
      );
      expect(bare.sortTitle, 'Zephyr');
    });

    test('browseSectionKey on the Songs sort key groups under A, not T', () {
      // "The A List 1" (title) is served in the A block (title_sort
      // "A List 1") — the live probe shape verified 2026-11-20.
      expect(browseSectionKey('A List 1'), 'A');
      expect(browseSectionKey('The A List 1'), 'T');
      // PR #54 review F3 (expansion hypothesis DISPROVED — Dart's
      // toUpperCase is simple 1:1; pinned so a future ICU/full-mapping
      // switch that WOULD expand still has to decide the header shape):
      expect(browseSectionKey('\u00dfweinen'), '\u00df'); // ß stays single
      expect(browseSectionKey('\uFB00luss'), '\uFB00'); // ﬀ ligature intact
    });
  });
}
