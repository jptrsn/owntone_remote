import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/owntone_api.dart';
import 'package:owntone_remote/src/library/library_models.dart';
import 'fakes/fake_owntone_server.dart';

/// R-10 (unit 005a C4): the browse API surface — wire shape, query
/// parameters, and the genre-expression encoding table (`Rock/Pop` →
/// `Rock%2FPop`, `Drum & Bass` → `Drum%20%26%20Bass`).
void main() {
  late ScriptedAdapter adapter;
  late OwntoneApi api;

  const base = 'http://10.0.0.5:3689';

  setUp(() {
    adapter = ScriptedAdapter(responder: (o) => jsonResponse(o, dataFor(o)));
    api = OwntoneApi(
      dio: Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter,
      baseUrl: Uri.parse('$base/'),
    );
  });

  group('genreExpression (pure)', () {
    test('quoting + escaping table', () {
      expect(genreExpression('Rock'), 'genre is "Rock"');
      expect(genreExpression('Rock/Pop'), 'genre is "Rock/Pop"');
      expect(genreExpression('Drum & Bass'), 'genre is "Drum & Bass"');
      expect(genreExpression(r'Ac"dc'), r'genre is "Ac\"dc"');
    });
  });

  group('wire format', () {
    test('playlists: paging params + model fields', () async {
      final page = await api.playlists();
      expect(
        adapter.requests.single,
        'GET /api/library/playlists?offset=0&limit=50',
      );
      expect(page.total, 13);
      expect(page.items, hasLength(2));
      expect(page.items[0].id, '10', reason: 'int wire id → string');
      expect(page.items[0].name, 'All Music');
      expect(page.items[0].type, 'smart');
      expect(page.items[0].smartPlaylist, isTrue);
      expect(page.items[0].itemCount, 1793);
      expect(page.items[0].uri, 'library:playlist:10');
    });

    test('playlistTracks: id path segment + offset/limit', () async {
      final page = await api.playlistTracks('11', offset: 25, limit: 10);
      expect(
        adapter.requests.single,
        'GET /api/library/playlists/11/tracks?offset=25&limit=10',
      );
      expect(page.items.single.id, 1196, reason: 'track id stays int');
      expect(page.items.single.title, 'Good People');
      expect(page.items.single.artist, 'Thundersmack feat.Honeycomb');
      expect(page.items.single.trackNumber, 1);
      expect(page.items.single.rating, 100);
      expect(page.items.single.uri, 'library:track:1196');
    });

    test('artists: paging + counts', () async {
      final page = await api.artists();
      expect(
        adapter.requests.single,
        'GET /api/library/artists?offset=0&limit=50',
      );
      expect(page.items.single.name, 'Alabama Shakes');
      expect(page.items.single.albumCount, 1);
      expect(page.items.single.trackCount, 7);
      expect(page.items.single.lengthMs, 1487436);
    });

    test('artistAlbums: id path segment', () async {
      final page = await api.artistAlbums('2025221010526333778');
      expect(
        adapter.requests.single,
        'GET /api/library/artists/2025221010526333778/albums?offset=0&limit=50',
      );
      expect(page.items.single.name, 'Absolution');
      expect(page.items.single.artist, 'Muse');
      expect(page.items.single.year, 2009);
    });

    test('albums: paging + model fields', () async {
      final page = await api.albums();
      expect(
        adapter.requests.single,
        'GET /api/library/albums?offset=0&limit=50',
      );
      expect(page.total, 497);
      expect(page.items.single.name, 'Absolution');
      expect(page.items.single.artistId, '2025221010526333778');
      expect(page.items.single.trackCount, 15);
    });

    test('albumTracks: id path segment', () async {
      final page = await api.albumTracks('5741211977103795472');
      expect(
        adapter.requests.single,
        'GET /api/library/albums/5741211977103795472/tracks?offset=0&limit=50',
      );
      expect(page.items.single.title, 'Intro');
      expect(page.items.single.trackNumber, 1);
      expect(page.items.single.rating, 20);
    });

    test('genres: no paging params (the server ignores them)', () async {
      final page = await api.genres();
      expect(adapter.requests.single, 'GET /api/library/genres');
      expect(page.items.single.name, 'Acoustic');
      expect(page.items.single.trackCount, 200);
      expect(page.items.single.albumCount, 35);
      expect(page.items.single.artistCount, 14);
    });

    test('genreAlbums: the search endpoint, albums key', () async {
      final page = await api.genreAlbums('Rock');
      expect(page.items.single.name, 'Achtung Baby');
      expect(page.total, 38);
    });
  });

  group('genreAlbums expression encoding (C4 table)', () {
    // The unit's encoding table: what the wire must carry.
    final cases = <String, String>{
      'Rock': 'genre%20is%20%22Rock%22',
      'Rock/Pop': 'genre%20is%20%22Rock%2FPop%22',
      'Drum & Bass': 'genre%20is%20%22Drum%20%26%20Bass%22',
      r'Ac"dc': r'genre%20is%20%22Ac%5C%22dc%22',
    };

    test('each name percent-encodes as specified', () async {
      for (final e in cases.entries) {
        adapter.requests.clear();
        await api.genreAlbums(e.key);
        expect(
          adapter.requests.single,
          'GET /api/search?type=albums&expression=${e.value}&offset=0&limit=50',
          reason: 'genre: ${e.key}',
        );
      }
    });
  });
}

/// Wire-shaped responses mirroring the live server (docs/API.md § Objects).
Map<String, dynamic> dataFor(RequestOptions o) {
  switch (o.uri.path) {
    case '/api/library/playlists':
      return const {
        'items': [
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
        ],
        'total': 13,
        'offset': 0,
        'limit': 50,
      };
    case '/api/library/playlists/11/tracks':
      return const {
        'items': [
          {
            'id': 1196,
            'title': 'Good People',
            'artist': 'Thundersmack feat.Honeycomb',
            'album': 'Brass',
            'album_id': '193995476750353277',
            'track_number': 1,
            'length_ms': 178776,
            'rating': 100,
            'uri': 'library:track:1196',
          },
        ],
        'total': 33,
        'offset': 25,
        'limit': 10,
      };
    case '/api/library/artists':
      return const {
        'items': [
          {
            'id': '135541244834957787',
            'name': 'Alabama Shakes',
            'album_count': 1,
            'track_count': 7,
            'length_ms': 1487436,
          },
        ],
        'total': 217,
        'offset': 0,
        'limit': 50,
      };
    case '/api/library/artists/2025221010526333778/albums':
      return const {
        'items': [
          {
            'id': '5741211977103795472',
            'name': 'Absolution',
            'artist': 'Muse',
            'artist_id': '2025221010526333778',
            'track_count': 15,
            'length_ms': 3438359,
            'year': 2009,
          },
        ],
        'total': 12,
        'offset': 0,
        'limit': 50,
      };
    case '/api/library/albums':
      return const {
        'items': [
          {
            'id': '5741211977103795472',
            'name': 'Absolution',
            'artist': 'Muse',
            'artist_id': '2025221010526333778',
            'track_count': 15,
            'length_ms': 3438359,
            'year': 2009,
          },
        ],
        'total': 497,
        'offset': 0,
        'limit': 50,
      };
    case '/api/library/albums/5741211977103795472/tracks':
      return const {
        'items': [
          {
            'id': 2428,
            'title': 'Intro',
            'artist': 'Muse',
            'album': 'Absolution',
            'album_id': '5741211977103795472',
            'track_number': 1,
            'length_ms': 22177,
            'rating': 20,
            'uri': 'library:track:2428',
          },
        ],
        'total': 15,
        'offset': 0,
        'limit': 50,
      };
    case '/api/library/genres':
      return const {
        'items': [
          {
            'name': 'Acoustic',
            'track_count': 200,
            'album_count': 35,
            'artist_count': 14,
          },
        ],
        'total': 79,
        'offset': 0,
        'limit': -1,
      };
    case '/api/search':
      return const {
        'albums': {
          'items': [
            {
              'id': '506809146730174',
              'name': 'Achtung Baby',
              'artist': 'U2',
              'artist_id': '3816761391151250234',
              'track_count': 12,
              'length_ms': 3000000,
              'year': 1991,
            },
          ],
          'total': 38,
          'offset': 0,
          'limit': 50,
        },
      };
    default:
      return <String, dynamic>{};
  }
}
