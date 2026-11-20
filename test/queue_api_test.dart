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

    // Issue #21 (R-11, OwnTone web-UI parity): in-place queue advance is
    // the web UI's own row click — `PUT /api/player/play?item_id=<entry
    // id>` (read from the served webplayer JS on 2026-11-19). One call,
    // keyed on the QUEUE-ENTRY id; zero queue writes — the add-with-clear
    // this replaced is what cleared the queue (the defect).
    test('skipToQueueItem: PUT /api/player/play?item_id=<entry id>', () async {
      await api.skipToQueueItem('196176');
      expect(adapter.requests.single, 'PUT /api/player/play?item_id=196176');
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

  // Issue #47 (R-24): per-row Remove + Play Next wire shape. Captured
  // request lines are the contract (the #21/#41/#46 pattern) — the
  // official json-api docs (docs-mcp 2026-11-20) freeze DELETE → 204
  // and `position` = "items are inserted starting from this position".
  group('R-24 wire format (issue #47)', () {
    test('deleteQueueItem: DELETE /api/queue/items/{id} — path + id only, '
        'no query (docs/API.md:95)', () async {
      await api.deleteQueueItem('196176');
      expect(adapter.requests.single, 'DELETE /api/queue/items/196176');
    });

    test('addUris position variant (play-next): uris + playback=add + '
        'exact position, WITHOUT clear=true — the #41 method extended, '
        'not duplicated', () async {
      await api.addUris(['library:track:1193'], position: 1);
      expect(
        adapter.requests.single,
        'POST /api/queue/items/add'
        '?uris=library%3Atrack%3A1193&playback=add&position=1',
      );
    });

    test('addUris without position stays position-free (the #41 tail '
        'caller must keep its request shape)', () async {
      await api.addUris(['library:track:1193'], position: null);
      expect(adapter.requests.single, isNot(contains('position')));
      expect(adapter.requests.single, contains('playback=add'));
      expect(adapter.requests.single, isNot(contains('clear')));
    });
  });

  // R-24 (issue #47), pure: the play-next position mapping. Shares
  // indexOfNowPlaying with the highlight and the hide-cut — one "current"
  // definition; no current entry ⇒ 0 (with nothing playing, "next" is
  // the head — minimal interpretation, recorded in the controller doc).
  group('queuePlayNextPosition (pure, R-24 issue #47)', () {
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
      QueueItem(
        id: '3',
        position: 2,
        trackId: 12,
        title: 'C',
        artist: '',
        album: '',
        lengthMs: 1000,
        uri: 'library:track:12',
      ),
    ];

    test('anchor at index 0 → 1, at index 1 → 2, at the tail → length', () {
      expect(queuePlayNextPosition(queue, 1), 1);
      expect(queuePlayNextPosition(queue, 2), 2);
      expect(queuePlayNextPosition(queue, 3), 3);
    });

    test('no current (stopped) → 0; an itemId the list does not hold → 0', () {
      expect(queuePlayNextPosition(queue, null), 0);
      // Stale/mid-refetch highlight (entry id absent from the list): the
      // head is the honest answer, same unanchorable rule as the hide-cut.
      expect(queuePlayNextPosition(queue, 99), 0);
    });

    test('matches on the ENTRY id, not track_id (shared rule)', () {
      // track_id 11 would be index 1 by coincidence of this fixture;
      // track_id 10 is NOT entry id 10 — no anchor → 0.
      expect(queuePlayNextPosition(queue, 10), 0);
    });
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

  // Issue #23 (OwnTone web-UI parity): the hide-cut view filter, pure.
  // R-11 is the queue requirement (the issue's "R-05 area" label follows
  // the #19/#24 misnumbering precedent).
  group('visibleQueue + indexOfNowPlaying (pure, R-11 issue #23)', () {
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
      QueueItem(
        id: '3',
        position: 2,
        trackId: 12,
        title: 'C',
        artist: '',
        album: '',
        lengthMs: 1000,
        uri: 'library:track:12',
      ),
    ];

    test('off → the very same list (no copy, no mutation)', () {
      expect(visibleQueue(queue, 2, hidePlayed: false), same(queue));
    });

    test('on → everything from the current entry onward (entry-id match)', () {
      // Anchor on entry id 2: A is cut, B (current) + C stay.
      expect(visibleQueue(queue, 2, hidePlayed: true), [queue[1], queue[2]]);
      // A track_id (10/11/12) is NOT an anchor — the match is the entry id.
      expect(visibleQueue(queue, 11, hidePlayed: true), same(queue));
    });

    test('on, unanchorable or index 0 → the full list', () {
      expect(visibleQueue(queue, 1, hidePlayed: true), same(queue)); // head
      expect(visibleQueue(queue, null, hidePlayed: true), same(queue));
      expect(visibleQueue(queue, 99, hidePlayed: true), same(queue));
    });

    test('the input list is never mutated (pure view filter)', () {
      visibleQueue(queue, 3, hidePlayed: true);
      expect(queue.map((i) => i.id), ['1', '2', '3']);
    });

    test('indexOfNowPlaying matches the entry id', () {
      expect(indexOfNowPlaying(queue, 2), 1);
      expect(indexOfNowPlaying(queue, 11), isNull);
      expect(indexOfNowPlaying(queue, null), isNull);
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
