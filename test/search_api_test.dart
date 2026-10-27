import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/owntone_api.dart';
import 'fakes/fake_owntone_server.dart';

/// R-13 (unit 007): the search API surface — one `paging` object per
/// requested type (shape verified live against 192.168.1.13: `tracks`,
/// `artists`, `albums`, `playlists` keys), per-group offset/limit, and the
/// pre-encoded query (spaces as `%20`, never `+` — the unit 005a C4 dio
/// trap).
void main() {
  late ScriptedAdapter adapter;
  late OwntoneApi api;
  late Map<String, Object?> reply;

  const base = 'http://10.0.0.5:3689';

  setUp(() {
    reply = {};
    adapter = ScriptedAdapter(responder: (o) => jsonResponse(o, reply));
    api = OwntoneApi(
      dio: Dio(BaseOptions(baseUrl: base))..httpClientAdapter = adapter,
      baseUrl: Uri.parse('$base/'),
    );
  });

  Map<String, dynamic> page(List<Map<String, dynamic>> items, int total) => {
    'items': items,
    'total': total,
    'offset': 0,
    'limit': 25,
  };

  group('R-13 search wire format', () {
    test('searchTracks: type/query/offset/limit on the wire', () async {
      reply = {
        'tracks': page([
          {
            'id': 1195,
            'title': 'Skunk',
            'artist': 'Thundersmack',
            'album': 'Brass',
            'album_id': '8442824499383327534',
            'length_ms': 361800,
            'rating': 60,
            'uri': 'library:track:1195',
          },
        ], 1),
      };
      final result = await api.searchTracks('skunk', offset: 25, limit: 25);
      expect(
        adapter.requests.single,
        'GET /api/search?type=tracks&query=skunk&offset=25&limit=25',
      );
      expect(result.total, 1);
      expect(result.items.single.id, 1195);
      expect(result.items.single.title, 'Skunk');
      expect(
        result.items.single.rating,
        60,
        reason: 'R-12 stars read from here',
      );
      expect(result.items.single.uri, 'library:track:1195');
    });

    test('query encoding: space → %20, & and " escaped — never +', () async {
      reply = {'tracks': page(const [], 0)};
      await api.searchTracks('Drum & Bass "live"');
      expect(
        adapter.requests.single,
        'GET /api/search?type=tracks'
        '&query=Drum%20%26%20Bass%20%22live%22&offset=0&limit=25',
        reason:
            'dio encodeQueryComponent would write + for spaces — the '
            'server does not decode those (unit 005a C4)',
      );
    });

    test('searchArtists: parses the artists group', () async {
      reply = {
        'artists': page([
          {
            'id': '5285872250650137906',
            'name': 'Thundersmack',
            'album_count': 2,
            'track_count': 17,
            'length_ms': 4000000,
          },
        ], 1),
      };
      final result = await api.searchArtists('thund');
      expect(
        adapter.requests.single,
        'GET /api/search?type=artists&query=thund&offset=0&limit=25',
      );
      expect(result.items.single.id, '5285872250650137906');
      expect(result.items.single.name, 'Thundersmack');
      expect(result.items.single.albumCount, 2);
    });

    test('searchAlbums: parses the albums group', () async {
      reply = {
        'albums': page([
          {
            'id': '6251730645465251649',
            'name': 'Brass',
            'artist': 'Thundersmack',
            'artist_id': '5285872250650137906',
            'track_count': 12,
            'length_ms': 3000000,
            'year': 2020,
          },
        ], 1),
      };
      final result = await api.searchAlbums('brass');
      expect(
        adapter.requests.single,
        'GET /api/search?type=albums&query=brass&offset=0&limit=25',
      );
      expect(result.items.single.name, 'Brass');
      expect(result.items.single.trackCount, 12);
    });

    test('searchPlaylists: parses the playlists group', () async {
      reply = {
        'playlists': page([
          {
            'id': 11,
            'name': 'Brass',
            'type': 'smart',
            'smart_playlist': true,
            'folder': false,
            'item_count': 33,
            'uri': 'library:playlist:11',
          },
        ], 1),
      };
      final result = await api.searchPlaylists('brass');
      expect(
        adapter.requests.single,
        'GET /api/search?type=playlists&query=brass&offset=0&limit=25',
      );
      expect(result.items.single.id, '11', reason: 'int wire id → string');
      expect(result.items.single.smartPlaylist, isTrue);
      expect(result.items.single.itemCount, 33);
    });

    test(
      'missing group key parses as empty (server omitted the type)',
      () async {
        reply = {'tracks': page(const [], 0)};
        final albums = await api.searchAlbums('anything');
        expect(albums.items, isEmpty);
        expect(albums.total, 0);
      },
    );
  });
}
