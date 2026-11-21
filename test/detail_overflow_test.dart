import 'dart:math' show min;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/owntone_api.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/library/library_models.dart';
import 'package:owntone_remote/src/queue/queue_controller.dart';
import 'package:owntone_remote/src/ui/browse_screens.dart';
import 'package:provider/provider.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// R-19 (issue #41, diff-list D-06, `docs/retune-capture/09-album-detail/`
/// + `18b-overflow-playlist/`): the detail-screen app-bar overflow —
/// **Play All · Shuffle · Play Next · Add to Up Next** — and the
/// QueueController/OwntoneApi surface behind it.
///
/// Every request is asserted against the [ScriptedAdapter]'s captured
/// request lines (the fake API): Play Next / Add to Up Next must be the
/// NO-clear `playback=add` add; Play All / Shuffle the `clear=true` +
/// `playback=start` replace-and-start (against the fake — these are the
/// supervised paths, never tapped against the real server); Shuffle must
/// leave the server's global shuffle flag untouched (no `?shuffle` on the
/// add, no `PUT /api/player/shuffle`).
///
/// Wire facts pinned here were live-verified on the 29.3 server
/// 2026-11-20: `playback=add` is accepted and never starts audio; the
/// add-time `shuffle` param is the GLOBAL shuffle-mode setter; an
/// omitted/out-of-range `position` inserts at a random slot while server
/// shuffle is on (so the tail add pins `position` = queue length).
void main() {
  const base = 'http://10.0.0.5:3689';
  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);

  // ------------------------------------------------------------- fixture

  late _Fixture fx;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late QueueController queue;

  setUp(() async {
    fx = _Fixture();
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
    await conn.connectTo(cfg);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  });

  tearDown(() {
    queue.dispose();
    conn.dispose();
  });

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
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> openOverflow(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('detail-overflow')));
    await settle(tester);
  }

  Future<void> tapEntry(WidgetTester tester, String label) async {
    // The popup menu route absorbs pointers until its open animation
    // lands — settle twice (two full fake-network rounds) so the tap
    // cannot race the transition (the hit test would land on the
    // AbsorbPointer and be silently dropped).
    await settle(tester);
    await tester.tap(find.text(label));
    await settle(tester);
  }

  /// Captured `POST /api/queue/items/add` request lines (only these
  /// actions are under wire scrutiny).
  List<String> addRequests() => adapter.requests
      .where((r) => r.startsWith('POST /api/queue/items/add'))
      .toList();

  Album album(String id, String name) => Album(
    id: id,
    name: name,
    artist: 'Artist 1',
    artistId: 'a1',
    trackCount: 3,
    lengthMs: 300000,
    uri: 'library:album:$id',
  );

  Playlist playlist(String id, String name) => Playlist(
    id: id,
    name: name,
    type: 'plain',
    smartPlaylist: false,
    folder: false,
    uri: 'library:playlist:$id',
  );

  Artist artist(String id, String name) => Artist(
    id: id,
    name: name,
    albumCount: 2,
    trackCount: 6,
    lengthMs: 600000,
  );

  // ---------------------------------------------------------- wire format

  group('OwntoneApi.addUris wire (R-19)', () {
    late OwntoneApiHolder holder;

    setUp(() => holder = OwntoneApiHolder(base, adapter));

    test('no clear, playback=add, position only when given', () async {
      adapter.requests.clear();
      await holder.api.addUris(['library:album:7', 'library:playlist:3']);
      expect(
        adapter.requests.single,
        'POST /api/queue/items/add'
        '?uris=library%3Aalbum%3A7%2Clibrary%3Aplaylist%3A3&playback=add',
      );
      // No clear, no playback=start, no add-time shuffle param.
      expect(adapter.requests.single, isNot(contains('clear')));
      expect(adapter.requests.single, isNot(contains('playback=start')));
      expect(adapter.requests.single, isNot(contains('shuffle')));
    });

    test('position=0 passthrough (Play Next)', () async {
      adapter.requests.clear();
      await holder.api.addUris(['library:album:7'], position: 0);
      expect(
        adapter.requests.single,
        'POST /api/queue/items/add'
        '?uris=library%3Aalbum%3A7&playback=add&position=0',
      );
    });
  });

  // ----------------------------------------------------------- controller

  group('QueueController.addUris (R-19)', () {
    test(
      'ahead: true → position=0, no clear, playback=add (Play Next)',
      () async {
        final ok = await queue.addUris(['library:album:7'], ahead: true);
        expect(ok, isTrue);
        final add = addRequests().single;
        expect(add, contains('position=0'));
        expect(add, contains('playback=add'));
        expect(add, isNot(contains('clear')));
        expect(add, isNot(contains('playback=start')));
        // Unit-011: the action ends with a trailing GET /api/queue so the
        // queue slice (and the Queue screen) re-syncs even without a WS event.
        expect(
          adapter.requests.last,
          'GET /api/queue',
          reason:
              'the _action trailing refresh must re-read post-commit '
              'queue state',
        );
      },
    );

    test('tail add pins position = current queue length (server-random '
        'insert without it while shuffle is on — live-verified)', () async {
      // The fixture queue has 3 items → position=3 = append past the tail.
      expect(queue.queue, hasLength(3));
      await queue.addUris(['library:album:7']);
      final add = addRequests().single;
      expect(add, contains('position=3'));
      expect(add, contains('playback=add'));
      expect(add, isNot(contains('clear')));
    });

    test('tail add on a NOT-yet-LOADED slice refreshes first, then pins '
        'the loaded length (PR #58 review minor: cold-start tail add '
        'silently pinned position=0 = queue HEAD)', () async {
      final cold = QueueController(connection: conn);
      await cold.init();
      expect(cold.hasLoaded, isFalse, reason: 'pre-first-GET slice');
      addRequests(); // no-op read to keep the helper honest
      final ok = await cold.addUris(['library:album:7']);
      expect(ok, isTrue);
      final add = addRequests().last;
      expect(
        add,
        contains('position=3'),
        reason:
            'pinned against the LOADED slice (fixture length 3), '
            'not the empty cold-start one (would be position=0)',
      );
      cold.dispose();
    });

    test(
      'failed add surfaces a typed error and keeps the known list',
      () async {
        fx.failAdds = true;
        final before = queue.queue;
        final ok = await queue.addUris(['library:album:7'], ahead: true);
        expect(ok, isFalse);
        expect(queue.actionError, contains('Play next failed'));
        expect(queue.queue, same(before));
      },
    );

    test(
      'WS queue event after an add refreshes the queue (R-11 x R-19)',
      () async {
        adapter.requests.clear();
        await queue.addUris(['library:album:7']);
        final after = adapter.requests.last;
        expect(after, 'GET /api/queue');
        // And an arriving `queue` event re-fetches too (UI stays live).
        adapter.requests.clear();
        channels.single.serverSend('{"notify": ["queue"]}');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(adapter.requests, contains('GET /api/queue'));
      },
    );
  });

  group('QueueController.playUrisShuffled (R-19)', () {
    test(
      'clear+start replace, uris a permutation of the input, global '
      'shuffle flag untouched (no ?shuffle on add, no player/shuffle PUT)',
      () async {
        final uris = [for (var i = 1; i <= 8; i++) 'library:track:$i'];
        final ok = await queue.playUrisShuffled(uris);
        expect(ok, isTrue);
        final add = addRequests().single;
        expect(add, contains('clear=true'));
        expect(add, contains('playback=start'));
        expect(
          add,
          isNot(contains('shuffle')),
          reason:
              'R-19: the add-time '
              '?shuffle param is the server GLOBAL shuffle setter (live-verified '
              '2026-11-20) — using it would mutate the flag',
        );
        expect(
          adapter.requests.where((r) => r.contains('/api/player/shuffle')),
          isEmpty,
          reason: 'shuffle-play must never touch the global shuffle mode',
        );
        final sent = Uri.splitQueryString(add.split('?').last)['uris']!;
        expect(sent.split(','), unorderedEquals(uris));
      },
    );
  });

  // --------------------------------------------------------------- widget

  group('detail overflow entries (R-19)', () {
    testWidgets('AlbumTracksScreen offers the four labelled entries', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        AlbumTracksScreen(album: album('alA', 'Absolution')),
      );
      await settle(tester);
      await openOverflow(tester);
      for (final label in [
        'Play All',
        'Shuffle',
        'Play Next',
        'Add to Up Next',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '$label missing');
      }
    });

    testWidgets('PlaylistTracksScreen offers the four labelled entries', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        PlaylistTracksScreen(playlist: playlist('10', 'All Music')),
      );
      await settle(tester);
      await openOverflow(tester);
      for (final label in [
        'Play All',
        'Shuffle',
        'Play Next',
        'Add to Up Next',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('ArtistAlbumsScreen offers the four labelled entries', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        ArtistAlbumsScreen(artist: artist('a1', 'Artist 1')),
      );
      await settle(tester);
      await openOverflow(tester);
      for (final label in [
        'Play All',
        'Shuffle',
        'Play Next',
        'Add to Up Next',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('empty list → the whole overflow is disabled (chosen '
        'minimal rule: every entry would be a no-op)', (tester) async {
      fx.emptyAlbumTracks = true;
      await pumpScreen(tester, AlbumTracksScreen(album: album('alA', 'Empty')));
      await settle(tester);
      expect(find.text('This album is empty.'), findsOneWidget);
      final button = tester.widget<PopupMenuButton<String>>(
        find.byKey(const ValueKey('detail-overflow')),
      );
      expect(button.enabled, isFalse);
    });

    testWidgets('detail screen with the overflow fits 360 logical px '
        '(unit-004 budget: leading pair + title + 2 actions)', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpScreen(
        tester,
        AlbumTracksScreen(album: album('alA', 'Absolution')),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('detail overflow actions hit the expected wire (R-19)', () {
    testWidgets('Play Next → no clear, playback=add, position=0', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        AlbumTracksScreen(album: album('alA', 'Absolution')),
      );
      await settle(tester);
      await openOverflow(tester);
      await tapEntry(tester, 'Play Next');
      final add = addRequests().single;
      expect(add, contains('uris=library%3Aalbum%3AalA'));
      expect(add, contains('position=0'));
      expect(add, contains('playback=add'));
      expect(add, isNot(contains('clear')));
      expect(add, isNot(contains('playback=start')));
    });

    testWidgets('Add to Up Next → no clear, playback=add, position at the '
        'live queue tail (3-item fixture queue)', (tester) async {
      await pumpScreen(
        tester,
        AlbumTracksScreen(album: album('alA', 'Absolution')),
      );
      await settle(tester);
      await openOverflow(tester);
      await tapEntry(tester, 'Add to Up Next');
      final add = addRequests().single;
      expect(add, contains('playback=add'));
      expect(add, contains('position=3'));
      expect(add, isNot(contains('clear')));
      expect(add, isNot(contains('playback=start')));
    });

    testWidgets('Play All → clear=true + playback=start (replace-and-start; '
        'fake API only — supervised path)', (tester) async {
      await pumpScreen(
        tester,
        AlbumTracksScreen(album: album('alA', 'Absolution')),
      );
      await settle(tester);
      await openOverflow(tester);
      await tapEntry(tester, 'Play All');
      final add = addRequests().single;
      expect(add, contains('clear=true'));
      expect(add, contains('playback=start'));
      expect(add, isNot(contains('position')));
    });

    testWidgets('Shuffle → expands the set to track uris, clear+start, '
        'global shuffle untouched (fake API only — supervised path)', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        AlbumTracksScreen(album: album('alA', 'Absolution')),
      );
      await settle(tester);
      await openOverflow(tester);
      await tapEntry(tester, 'Shuffle');
      // The set was expanded via one unbounded page…
      expect(
        adapter.requests.where(
          (r) =>
              r.contains('/api/library/albums/alA/tracks?') &&
              r.contains('limit=-1'),
        ),
        hasLength(1),
      );
      // …then replace-and-started.
      final add = addRequests().single;
      expect(add, contains('clear=true'));
      expect(add, contains('playback=start'));
      expect(add, isNot(contains('shuffle')));
      expect(
        adapter.requests.where((r) => r.contains('/api/player/shuffle')),
        isEmpty,
      );
      final sent = Uri.splitQueryString(add.split('?').last)['uris']!;
      expect(
        sent.split(','),
        unorderedEquals([
          'library:track:2428',
          'library:track:2426',
          'library:track:2427',
        ]),
      );
    });

    testWidgets('playlist Play Next uses the container uri at position=0', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        PlaylistTracksScreen(playlist: playlist('10', 'All Music')),
      );
      await settle(tester);
      await openOverflow(tester);
      await tapEntry(tester, 'Play Next');
      final add = addRequests().single;
      expect(add, contains('uris=library%3Aplaylist%3A10'));
      expect(add, contains('position=0'));
      expect(add, contains('playback=add'));
      expect(add, isNot(contains('clear')));
    });

    testWidgets('artist-albums Add to Up Next uses the artist container uri', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        ArtistAlbumsScreen(artist: artist('a1', 'Artist 1')),
      );
      await settle(tester);
      await openOverflow(tester);
      await tapEntry(tester, 'Add to Up Next');
      final add = addRequests().single;
      expect(add, contains('uris=library%3Aartist%3Aa1'));
      expect(add, contains('playback=add'));
      expect(add, isNot(contains('clear')));
    });
  });
}

/// OwntoneApi under the wire-format group (same scripted adapter).
class OwntoneApiHolder {
  OwntoneApiHolder(String base, ScriptedAdapter adapter)
    : api = OwntoneApi(
        dio: Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter,
        baseUrl: Uri.parse('$base/'),
      );
  final OwntoneApi api;
}

/// Album/playlist/artist-album fixture + a 3-item queue (so the tail-add
/// position is deterministic) + scriptable add failure.
class _Fixture {
  bool failAdds = false;
  bool emptyAlbumTracks = false;

  final List<Map<String, dynamic>> alATracks = [
    {
      'id': 2428,
      'title': 'Intro',
      'artist': 'Artist 1',
      'album': 'Absolution',
      'album_id': 'alA',
      'track_number': 1,
      'length_ms': 22177,
      'rating': 0,
      'uri': 'library:track:2428',
    },
    {
      'id': 2426,
      'title': 'Apocalypse Please',
      'artist': 'Artist 1',
      'album': 'Absolution',
      'album_id': 'alA',
      'track_number': 2,
      'length_ms': 252917,
      'rating': 0,
      'uri': 'library:track:2426',
    },
    {
      'id': 2427,
      'title': 'Hysteria',
      'artist': 'Artist 1',
      'album': 'Absolution',
      'album_id': 'alA',
      'track_number': 3,
      'length_ms': 252917,
      'rating': 0,
      'uri': 'library:track:2427',
    },
  ];

  final List<Map<String, dynamic>> pl10Tracks = [
    {
      'id': 1196,
      'title': 'Good People',
      'artist': 'Artist 2',
      'album': 'Brass',
      'album_id': 'alB',
      'length_ms': 178776,
      'rating': 0,
      'uri': 'library:track:1196',
    },
  ];

  final List<Map<String, dynamic>> a1Albums = [
    {
      'id': 'alA',
      'name': 'Absolution',
      'artist': 'Artist 1',
      'artist_id': 'a1',
      'track_count': 3,
      'length_ms': 100000,
      'year': 2009,
      'uri': 'library:album:alA',
    },
    {
      'id': 'alB',
      'name': 'Second Album',
      'artist': 'Artist 1',
      'artist_id': 'a1',
      'track_count': 2,
      'length_ms': 100000,
      'year': 2012,
      'uri': 'library:album:alB',
    },
  ];

  static const _queueItems = [
    {
      'id': 1,
      'position': 0,
      'track_id': 10,
      'title': 'Q One',
      'artist': 'A',
      'album': 'B',
      'length_ms': 1000,
      'uri': 'library:track:10',
    },
    {
      'id': 2,
      'position': 1,
      'track_id': 11,
      'title': 'Q Two',
      'artist': 'A',
      'album': 'B',
      'length_ms': 1000,
      'uri': 'library:track:11',
    },
    {
      'id': 3,
      'position': 2,
      'track_id': 12,
      'title': 'Q Three',
      'artist': 'A',
      'album': 'B',
      'length_ms': 1000,
      'uri': 'library:track:12',
    },
  ];

  Map<String, dynamic> _page(
    List<Map<String, dynamic>> all,
    int off,
    int lim,
  ) => {
    'items': off < all.length
        ? all.sublist(off, lim < 0 ? all.length : min(off + lim, all.length))
        : <Map<String, dynamic>>[],
    'total': all.length,
    'offset': off,
    'limit': lim,
  };

  Response<dynamic> handle(RequestOptions o) {
    final p = o.uri.path;
    final q = o.uri.queryParameters;
    final off = int.tryParse((q['offset'] ?? '').toString()) ?? 0;
    final lim = int.tryParse((q['limit'] ?? '').toString()) ?? 50;
    switch (p) {
      case '/api/config':
        return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
      case '/api/player':
        return jsonResponse(o, {'state': 'pause', 'volume': 40});
      case '/api/queue':
        return jsonResponse(o, {
          'version': 1,
          'count': _queueItems.length,
          'items': _queueItems,
        });
      case '/api/queue/items/add':
        if (failAdds) {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 500),
          );
        }
        return jsonResponse(o, {
          'version': 2,
          'count': 0,
          'items': <Map<String, dynamic>>[],
        });
      case '/api/library/albums/alA/tracks':
        return jsonResponse(
          o,
          _page(emptyAlbumTracks ? const [] : alATracks, off, lim),
        );
      case '/api/library/playlists/10/tracks':
        return jsonResponse(o, _page(pl10Tracks, off, lim));
      case '/api/library/artists/a1/albums':
        return jsonResponse(o, _page(a1Albums, off, lim));
      default:
        return Response(requestOptions: o, statusCode: 404);
    }
  }
}
