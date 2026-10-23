import 'dart:async';
import 'dart:math' show min;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/library/library_models.dart';
import 'package:owntone_remote/src/ui/browse_screens.dart';
import 'package:owntone_remote/src/ui/paged_browse_list.dart';
import 'package:provider/provider.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

/// R-10 (unit 005a) fixture: a stateful OwnTone library server. The
/// genres endpoint ignores paging exactly like the real one (verified
/// live 2026-10-23); the search endpoint decodes the (pre-encoded)
/// expression back out and routes by genre name.
class LibraryFixture {
  LibraryFixture();

  /// All library / search GETs answer 500.
  bool failLibrary = false;

  /// Gates library GETs until completed (loading-state test).
  Completer<void>? gate;

  final List<Map<String, dynamic>> playlists = [
    {
      'id': 10,
      'name': 'All Music',
      'type': 'smart',
      'smart_playlist': true,
      'folder': false,
      'item_count': 1793,
      'uri': 'library:playlist:10',
    },
    {
      'id': 11,
      'name': 'Brass',
      'type': 'smart',
      'smart_playlist': true,
      'folder': false,
      'item_count': 33,
      'uri': 'library:playlist:11',
    },
  ];

  /// 120 artists — three pages at the app's 50-per-page.
  final List<Map<String, dynamic>> artists = [
    for (var i = 1; i <= 120; i++)
      {
        'id': 'a$i',
        'name': 'Artist $i',
        'album_count': 1,
        'track_count': 3,
        'length_ms': 100000,
      },
  ];

  final List<Map<String, dynamic>> albums = [
    for (var i = 1; i <= 60; i++)
      {
        'id': 'al$i',
        'name': 'Album $i',
        'artist': 'Artist 1',
        'artist_id': 'a1',
        'track_count': 2,
        'length_ms': 100000,
        'year': 2020,
      },
  ];

  final List<Map<String, dynamic>> genres = [
    {'name': 'Rock', 'track_count': 10, 'album_count': 2, 'artist_count': 2},
    {'name': 'Jazz', 'track_count': 5, 'album_count': 1, 'artist_count': 1},
  ];

  final List<Map<String, dynamic>> a1Albums = [
    {
      'id': 'alA',
      'name': 'Absolution',
      'artist': 'Artist 1',
      'artist_id': 'a1',
      'track_count': 2,
      'length_ms': 100000,
      'year': 2009,
    },
    {
      'id': 'alB',
      'name': 'Second Album',
      'artist': 'Artist 1',
      'artist_id': 'a1',
      'track_count': 2,
      'length_ms': 100000,
      'year': 2012,
    },
  ];

  final List<Map<String, dynamic>> alATracks = [
    {
      'id': 2428,
      'title': 'Intro',
      'artist': 'Artist 1',
      'album': 'Absolution',
      'album_id': 'alA',
      'track_number': 1,
      'length_ms': 22177,
      'rating': 20,
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
      'rating': 20,
      'uri': 'library:track:2426',
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
      'uri': 'library:track:1196',
    },
  ];

  final List<Map<String, dynamic>> rockAlbums = [
    {
      'id': 'alRock1',
      'name': 'Achtung Baby',
      'artist': 'U2',
      'artist_id': 'a9',
      'track_count': 12,
      'length_ms': 3000000,
      'year': 1991,
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

  bool _isLibrary(RequestOptions o) =>
      o.uri.path.startsWith('/api/library') || o.uri.path == '/api/search';

  Future<Response<dynamic>> handle(RequestOptions o) async {
    final p = o.uri.path;
    // From the URI, not `o.queryParameters`: dio leaves the latter as the
    // map the client passed, so a query embedded in the path (the genre
    // search, unit 005a C4) would be invisible there.
    final q = o.uri.queryParameters;
    final off = int.tryParse((q['offset'] ?? '').toString()) ?? 0;
    final lim = int.tryParse((q['limit'] ?? '').toString()) ?? 50;
    if (_isLibrary(o)) {
      if (gate != null && !gate!.isCompleted) await gate!.future;
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
      case '/api/library/playlists':
        return jsonResponse(o, _page(playlists, off, lim));
      case '/api/library/artists':
        return jsonResponse(o, _page(artists, off, lim));
      case '/api/library/albums':
        return jsonResponse(o, _page(albums, off, lim));
      case '/api/library/genres':
        // Like the real server: offset/limit ignored, everything returned.
        return jsonResponse(
          o,
          _page(genres, 0, genres.isEmpty ? 1 : genres.length),
        );
      case '/api/library/artists/a1/albums':
        return jsonResponse(o, _page(a1Albums, off, lim));
      case '/api/library/albums/alA/tracks':
        return jsonResponse(o, _page(alATracks, off, lim));
      case '/api/library/playlists/10/tracks':
        return jsonResponse(o, _page(pl10Tracks, off, lim));
      case '/api/search':
        // `q['expression']` is already decoded by the URI (the client
        // pre-encodes it, unit 005a C4).
        final expression = q['expression'].toString();
        final m = RegExp(r'genre is "(.*)"').firstMatch(expression);
        final name = m?.group(1) ?? '';
        final albums = name == 'Rock'
            ? rockAlbums
            : const <Map<String, dynamic>>[];
        return jsonResponse(o, {'albums': _page(albums, off, lim)});
      default:
        return Response(requestOptions: o, statusCode: 404);
    }
  }
}

/// One browse list type: screen, expected texts, and the store surgery the
/// state tests need.
class _Spec {
  _Spec({
    required this.name,
    required this.screen,
    required this.what,
    required this.emptyMessage,
    required this.clear,
    required this.firstRow,
    required this.mutate,
    required this.newRow,
  });

  final String name;
  final Widget Function() screen;
  final String what;
  final String emptyMessage;
  final void Function() clear;
  final String firstRow;
  final void Function() mutate;
  final String newRow;
}

void main() {
  late LibraryFixture fx;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;

  Future<void> wireUp() async {
    fx = LibraryFixture();
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
    await conn.connectTo(_cfg);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  Future<void> pumpScreen(WidgetTester tester, Widget screen) =>
      tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ConnectionController>.value(value: conn),
          ],
          child: MaterialApp(home: screen),
        ),
      );

  /// Lets the (fake) network futures complete, then renders frames.
  /// Several duration-carrying pumps: after a `runAsync` round trip the
  /// dio microtask chain needs a few event-loop turns to land (one
  /// zero-duration pump is not enough — verified empirically).
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Jumps the list to the bottom — the load-more threshold fires.
  Future<void> scrollToEnd(WidgetTester tester) async {
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    position.jumpTo(position.maxScrollExtent);
    await settle(tester);
  }

  /// The eight in-scope list types (unit 005a C1–C3).
  List<_Spec> buildSpecs() => [
    _Spec(
      name: 'playlists',
      screen: () => const PlaylistsScreen(),
      what: 'playlists',
      emptyMessage: 'No playlists in the library.',
      clear: () => fx.playlists.clear(),
      firstRow: 'All Music',
      mutate: () => fx.playlists.insert(0, {
        'id': 99,
        'name': 'New List',
        'type': 'plain',
        'smart_playlist': false,
        'folder': false,
        'item_count': 1,
        'uri': 'library:playlist:99',
      }),
      newRow: 'New List',
    ),
    _Spec(
      name: 'artists',
      screen: () => const ArtistsScreen(),
      what: 'artists',
      emptyMessage: 'No artists in the library.',
      clear: () => fx.artists.clear(),
      firstRow: 'Artist 1',
      mutate: () => fx.artists.insert(0, {
        'id': 'aNew',
        'name': 'New Artist',
        'album_count': 0,
        'track_count': 0,
        'length_ms': 0,
      }),
      newRow: 'New Artist',
    ),
    _Spec(
      name: 'albums',
      screen: () => const AlbumsScreen(),
      what: 'albums',
      emptyMessage: 'No albums in the library.',
      clear: () => fx.albums.clear(),
      firstRow: 'Album 1',
      mutate: () => fx.albums.insert(0, {
        'id': 'alNew',
        'name': 'New Album',
        'artist': 'Artist 1',
        'artist_id': 'a1',
        'track_count': 0,
        'length_ms': 0,
        'year': 2026,
      }),
      newRow: 'New Album',
    ),
    _Spec(
      name: 'genres',
      screen: () => const GenresScreen(),
      what: 'genres',
      emptyMessage: 'No genres in the library.',
      clear: () => fx.genres.clear(),
      firstRow: 'Rock',
      mutate: () => fx.genres.insert(0, {
        'name': 'New Genre',
        'track_count': 1,
        'album_count': 1,
        'artist_count': 1,
      }),
      newRow: 'New Genre',
    ),
    _Spec(
      name: 'artist albums',
      screen: () => ArtistAlbumsScreen(
        artist: const Artist(
          id: 'a1',
          name: 'Artist 1',
          albumCount: 2,
          trackCount: 6,
          lengthMs: 200000,
        ),
      ),
      what: 'albums',
      emptyMessage: 'No albums for Artist 1.',
      clear: () => fx.a1Albums.clear(),
      firstRow: 'Absolution',
      mutate: () => fx.a1Albums.insert(0, {
        'id': 'alNewA',
        'name': 'New Album A',
        'artist': 'Artist 1',
        'artist_id': 'a1',
        'track_count': 0,
        'length_ms': 0,
        'year': 2026,
      }),
      newRow: 'New Album A',
    ),
    _Spec(
      name: 'genre albums',
      screen: () => GenreAlbumsScreen(
        genre: const Genre(
          name: 'Rock',
          trackCount: 10,
          albumCount: 2,
          artistCount: 2,
        ),
      ),
      what: 'albums',
      emptyMessage: 'No albums in Rock.',
      clear: () => fx.rockAlbums.clear(),
      firstRow: 'Achtung Baby',
      mutate: () => fx.rockAlbums.insert(0, {
        'id': 'alNewR',
        'name': 'New Album R',
        'artist': 'U2',
        'artist_id': 'a9',
        'track_count': 0,
        'length_ms': 0,
        'year': 2026,
      }),
      newRow: 'New Album R',
    ),
    _Spec(
      name: 'album tracks',
      screen: () => AlbumTracksScreen(
        album: const Album(
          id: 'alA',
          name: 'Absolution',
          artist: 'Artist 1',
          artistId: 'a1',
          trackCount: 2,
          lengthMs: 100000,
          year: 2009,
        ),
      ),
      what: 'tracks',
      emptyMessage: 'This album is empty.',
      clear: () => fx.alATracks.clear(),
      firstRow: 'Intro',
      mutate: () => fx.alATracks.insert(0, {
        'id': 9999,
        'title': 'New Track',
        'artist': 'Artist 1',
        'album': 'Absolution',
        'album_id': 'alA',
        'track_number': 0,
        'length_ms': 100000,
        'uri': 'library:track:9999',
      }),
      newRow: 'New Track',
    ),
    _Spec(
      name: 'playlist tracks',
      screen: () => PlaylistTracksScreen(
        playlist: const Playlist(
          id: '10',
          name: 'All Music',
          type: 'smart',
          smartPlaylist: true,
          folder: false,
          itemCount: 1793,
          uri: 'library:playlist:10',
        ),
      ),
      what: 'tracks',
      emptyMessage: 'This playlist is empty.',
      clear: () => fx.pl10Tracks.clear(),
      firstRow: 'Good People',
      mutate: () => fx.pl10Tracks.insert(0, {
        'id': 9998,
        'title': 'New Playlist Track',
        'artist': 'Artist 9',
        'album': 'Brass',
        'album_id': 'alB',
        'length_ms': 100000,
        'uri': 'library:track:9998',
      }),
      newRow: 'New Playlist Track',
    ),
  ];

  tearDown(() {
    conn.dispose();
  });

  group('R-10 rendering (C1)', () {
    for (final spec in buildSpecs()) {
      testWidgets('${spec.name}: first rows render live fields', (
        tester,
      ) async {
        await tester.runAsync(wireUp);
        await pumpScreen(tester, spec.screen());
        await settle(tester);
        expect(find.text(spec.firstRow), findsOneWidget);
      });
    }

    testWidgets('playlists: name, kind + item count on one line', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const PlaylistsScreen());
      await settle(tester);
      expect(find.text('All Music'), findsOneWidget);
      expect(find.text('smart playlist · 1793 items'), findsOneWidget);
      expect(find.text('Brass'), findsOneWidget);
    });

    testWidgets('album tracks: number, title, length', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(
        tester,
        AlbumTracksScreen(
          album: const Album(
            id: 'alA',
            name: 'Absolution',
            artist: 'Artist 1',
            artistId: 'a1',
            trackCount: 2,
            lengthMs: 100000,
            year: 2009,
          ),
        ),
      );
      await settle(tester);
      expect(find.text('Intro'), findsOneWidget);
      expect(find.text('Apocalypse Please'), findsOneWidget);
      expect(find.text('0:22'), findsOneWidget);
      expect(find.text('4:12'), findsOneWidget);
    });

    testWidgets('playlist tracks: artist shown, length', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(
        tester,
        PlaylistTracksScreen(
          playlist: const Playlist(
            id: '10',
            name: 'All Music',
            type: 'smart',
            smartPlaylist: true,
            folder: false,
            itemCount: 1793,
            uri: 'library:playlist:10',
          ),
        ),
      );
      await settle(tester);
      expect(find.text('Good People'), findsOneWidget);
      expect(find.text('Artist 2'), findsOneWidget);
      expect(find.text('2:58'), findsOneWidget);
    });
  });

  group('R-10 pagination (C2)', () {
    testWidgets(
      'artists: 120 items load pages 2 and 3 on scroll, no duplicates',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpScreen(tester, const ArtistsScreen());
        await settle(tester);
        expect(
          adapter.requests,
          contains('GET /api/library/artists?offset=0&limit=50'),
        );

        await scrollToEnd(tester); // page 2
        await scrollToEnd(tester); // page 3
        await scrollToEnd(tester); // exhausted: no-op

        final requests = adapter.requests
            .where((r) => r.startsWith('GET /api/library/artists'))
            .toList();
        expect(requests, [
          'GET /api/library/artists?offset=0&limit=50',
          'GET /api/library/artists?offset=50&limit=50',
          'GET /api/library/artists?offset=100&limit=50',
        ]);
        final list = tester
            .widget<PagedBrowseList<Artist>>(
              find.byWidgetPredicate((w) => w is PagedBrowseList<Artist>),
            )
            .list;
        expect(list.items, hasLength(120));
        expect(
          list.items.map((a) => a.id).toSet(),
          hasLength(120),
          reason: 'no duplicates',
        );
        expect(list.items.first.name, 'Artist 1');
        expect(list.items[50].name, 'Artist 51');
        expect(list.items.last.name, 'Artist 120');
      },
    );

    testWidgets('no scroll → exactly one request', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const ArtistsScreen());
      await settle(tester);
      expect(
        adapter.requests.where((r) => r.contains('/api/library/artists')),
        hasLength(1),
      );
    });
  });

  group('R-10 states (C3), every list type', () {
    for (final spec in buildSpecs()) {
      testWidgets('${spec.name}: loading shows the skeleton', (tester) async {
        await tester.runAsync(() async {
          await wireUp();
          fx.gate = Completer<void>();
        });
        await pumpScreen(tester, spec.screen());
        await tester.pump();
        expect(find.byKey(const ValueKey('skeleton-row')), findsNWidgets(8));
        expect(find.text(spec.firstRow), findsNothing);

        await tester.runAsync(() async {
          fx.gate!.complete();
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await settle(tester);
        expect(find.text(spec.firstRow), findsOneWidget);
      });

      testWidgets('${spec.name}: empty slice → icon + text', (tester) async {
        await tester.runAsync(() async {
          await wireUp();
          spec.clear();
        });
        await pumpScreen(tester, spec.screen());
        await settle(tester);
        expect(find.text(spec.emptyMessage), findsOneWidget);
      });

      testWidgets('${spec.name}: error state + retry', (tester) async {
        await tester.runAsync(() async {
          await wireUp();
          fx.failLibrary = true;
        });
        await pumpScreen(tester, spec.screen());
        await settle(tester);
        expect(find.text('Could not load ${spec.what}.'), findsOneWidget);
        expect(find.text('Server answered HTTP 500.'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);

        await tester.runAsync(() async {
          fx.failLibrary = false;
        });
        await tester.tap(find.text('Retry'));
        await settle(tester);
        expect(find.text(spec.firstRow), findsOneWidget);
      });

      testWidgets(
        '${spec.name}: offline banner + stale rows, reconnect refetches',
        (tester) async {
          await tester.runAsync(wireUp);
          await pumpScreen(tester, spec.screen());
          await settle(tester);
          expect(find.text(spec.firstRow), findsOneWidget);

          conn.disconnect();
          await tester.pump();
          expect(
            find.text('Server unreachable — retrying. Browsing disabled.'),
            findsOneWidget,
          );
          expect(
            find.text(spec.firstRow),
            findsOneWidget,
            reason: 'stale rows stay visible',
          );

          await tester.runAsync(() async {
            spec.mutate();
            await conn.connectTo(_cfg);
            await Future<void>.delayed(const Duration(milliseconds: 60));
          });
          await settle(tester);
          expect(
            find.text(spec.newRow),
            findsOneWidget,
            reason: 'refetched after the reconnect',
          );
        },
      );
    }
  });

  group('R-10 navigation', () {
    testWidgets('home: the four sections', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const LibraryHomeScreen());
      await tester.pump();
      for (final label in ['Playlists', 'Artists', 'Albums', 'Genres']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('chain: home → artists → albums → tracks', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const LibraryHomeScreen());
      await tester.pump();

      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text('Artist 1'), findsOneWidget);

      await tester.tap(find.text('Artist 1'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text('Absolution'), findsOneWidget);

      await tester.tap(find.text('Absolution'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text('Intro'), findsOneWidget);
      expect(find.text('0:22'), findsOneWidget);
    });

    testWidgets('chain: home → playlists → tracks', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const LibraryHomeScreen());
      await tester.pump();

      await tester.tap(find.text('Playlists'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text('All Music'), findsOneWidget);

      await tester.tap(find.text('All Music'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text('Good People'), findsOneWidget);
    });

    testWidgets('chain: home → genres → albums (search expression)', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const LibraryHomeScreen());
      await tester.pump();

      await tester.tap(find.text('Genres'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text('Rock'), findsOneWidget);

      await tester.tap(find.text('Rock'));
      await tester.pumpAndSettle();
      await settle(tester);
      expect(find.text('Achtung Baby'), findsOneWidget);
      expect(
        adapter.requests,
        contains(
          'GET /api/search?type=albums&expression=genre%20is%20%22Rock%22&offset=0&limit=50',
        ),
        reason: 'the encoded expression went out on the wire',
      );
    });
  });
}
