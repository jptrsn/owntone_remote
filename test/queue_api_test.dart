import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/owntone_api.dart';
import 'package:owntone_remote/src/queue/queue_controller.dart';
import 'package:owntone_remote/src/queue/queue_item.dart';
import 'fakes/fake_owntone_server.dart';

/// R-11 (unit 005b C3): the queue/play API surface — wire shape for
/// `GET /api/queue`, `PUT /api/queue/clear`, and the single-call queue play
/// `POST /api/queue/items/add?uris=…&clear=true&playback=start`.
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

  group('wire format', () {
    test('getQueue: the full items[] in server order', () async {
      final items = await api.getQueue();
      expect(adapter.requests.single, 'GET /api/queue');
      expect(items, hasLength(3));
      expect(items.first.id, '196174');
      expect(items.first.position, 0);
      expect(items.first.trackId, 1195);
      expect(items.first.uri, 'library:track:1195');
      expect(items.first.title, 'Skunk');
      expect(items.last.position, 2);
      // Artwork resolves against the web root; the album fallback applies
      // when artwork_url is absent.
      expect(items.first.artworkUrl, Uri.parse('$base/./artwork/track/1195'));
      expect(
        items[1].artworkUrl,
        Uri.parse('$base/./artwork/album/5741211977103795472'),
      );
    });

    test('clearQueue: PUT /api/queue/clear', () async {
      await api.clearQueue();
      expect(adapter.requests.single, 'PUT /api/queue/clear');
    });

    test('playUris: one add call, uris comma-joined', () async {
      final items = await api.playUris([
        'library:track:1195',
        'library:track:1194',
      ]);
      // dio form-encodes the value: `:` → %3A and the separator `,` → %2C
      // (the server URL-decodes before splitting on commas, same as the
      // web UI's browser-encoded request).
      expect(
        adapter.requests.single,
        'POST /api/queue/items/add'
        '?uris=library%3Atrack%3A1195%2Clibrary%3Atrack%3A1194',
      );
      expect(items, hasLength(2));
    });

    test(
      'playUris: clear + startPlayback flags (the supervised call)',
      () async {
        await api.playUris(
          ['library:album:5741211977103795472'],
          clear: true,
          startPlayback: true,
        );
        expect(
          adapter.requests.single,
          'POST /api/queue/items/add'
          '?uris=library%3Aalbum%3A5741211977103795472'
          '&clear=true&playback=start',
        );
      },
    );
  });

  group('QueueItem model', () {
    test('fromJson: the live wire shape (verified 2026-10-23)', () {
      final item = QueueItem.fromJson({
        'id': 196174,
        'position': 0,
        'track_id': 1195,
        'title': 'Skunk',
        'artist': 'Muse',
        'album': 'Absolution',
        'length_ms': 343835,
        'uri': 'library:track:1195',
      }, Uri.parse('$base/'));
      expect(item.id, '196174');
      expect(item.trackId, 1195);
    });
  });

  group('findNowPlaying (pure, R-11 highlight)', () {
    final queue = <QueueItem>[
      QueueItem(
        id: '1',
        position: 0,
        trackId: 10,
        title: 'A',
        artist: '',
        album: '',
        lengthMs: 1000,
        uri: 'library:track:10',
      ),
      QueueItem(
        id: '2',
        position: 1,
        trackId: 11,
        title: 'B',
        artist: '',
        album: '',
        lengthMs: 1000,
        uri: 'library:track:11',
      ),
    ];

    test('matches on the queue-entry id, not track_id', () {
      // item_id 196174 style: the entry id — the live-verified comparison.
      expect(findNowPlaying(queue, 1), queue.first);
      // A track_id that no entry id matches: no highlight.
      expect(findNowPlaying(queue, 10), isNull);
      expect(findNowPlaying(queue, null), isNull);
    });
  });
}

Map<String, dynamic> dataFor(RequestOptions o) {
  final p = o.uri.path;
  switch (p) {
    case '/api/queue':
      return {
        'version': 1341,
        'count': 3,
        'items': [
          {
            'id': 196174,
            'position': 0,
            'track_id': 1195,
            'title': 'Skunk',
            'artist': 'Muse',
            'album': 'Absolution',
            'length_ms': 343835,
            'artwork_url': './artwork/track/1195',
            'uri': 'library:track:1195',
          },
          {
            'id': 196175,
            'position': 1,
            'track_id': 1194,
            'title': 'Blues in the Attic',
            'artist': 'Muse',
            'album': 'Absolution',
            'length_ms': 242640,
            'album_id': 5741211977103795472,
            'uri': 'library:track:1194',
          },
          {
            'id': 196176,
            'position': 2,
            'track_id': 1193,
            'title': 'House Party',
            'artist': 'Muse',
            'album': 'Absolution',
            'length_ms': 250720,
            'uri': 'library:track:1193',
          },
        ],
      };
    case '/api/queue/items/add':
      // Echo the added uris back as a fresh single-item queue.
      final uris = (o.uri.queryParameters['uris'] ?? '').split(',');
      return {
        'version': 1342,
        'count': uris.length,
        'items': [
          for (var i = 0; i < uris.length; i++)
            {
              'id': 200000 + i,
              'position': i,
              'track_id': 0,
              'title': 'Added',
              'artist': '',
              'album': '',
              'length_ms': 0,
              'uri': uris[i],
            },
        ],
      };
    default:
      return <String, dynamic>{};
  }
}
