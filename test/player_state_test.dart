import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/player/player_state.dart';

/// R-03: player-state JSON mapping (fixtures = live /api/player +
/// /api/queue?id=now_playing responses recorded in docs/API.md).
void main() {
  final webRoot = Uri.parse('http://192.168.1.13:3689/');

  group('PlayerState.fromJson', () {
    test('maps the live paused example', () {
      final p = PlayerState.fromJson(const {
        'state': 'pause',
        'repeat': 'off',
        'consume': false,
        'shuffle': false,
        'volume': 75,
        'item_id': 196000,
        'item_length_ms': 353512,
        'item_progress_ms': 26368,
        'artwork_url': './artwork/nowplaying',
      });
      expect(p.isPaused, isTrue);
      expect(p.isPlaying, isFalse);
      expect(p.isStopped, isFalse);
      expect(p.repeat, Repeat.off);
      expect(p.consume, isFalse);
      expect(p.shuffle, isFalse);
      expect(p.volume, 75);
      expect(p.itemId, 196000);
      expect(p.itemLengthMs, 353512);
      expect(p.itemProgressMs, 26368);
    });

    test('maps play state and repeat modes', () {
      final p = PlayerState.fromJson(const {
        'state': 'play',
        'repeat': 'single',
        'consume': true,
        'shuffle': true,
        'volume': 42,
      });
      expect(p.isPlaying, isTrue);
      expect(p.repeat, Repeat.single);
      expect(p.consume, isTrue);
      expect(p.shuffle, isTrue);
      expect(p.volume, 42);
      expect(p.itemId, isNull);
    });

    test('repeat: all -> Repeat.all', () {
      expect(
        PlayerState.fromJson(const {'state': 'play', 'repeat': 'all'}).repeat,
        Repeat.all,
      );
    });

    test('unknown/absent repeat falls back to off (defensive parse)', () {
      expect(PlayerState.fromJson(const {'state': 'play'}).repeat, Repeat.off);
      expect(
        PlayerState.fromJson(const {'state': 'play', 'repeat': 'bogus'}).repeat,
        Repeat.off,
      );
    });

    test('absent fields default safely (no item, no artwork)', () {
      final p = PlayerState.fromJson(const {'state': 'stop'});
      expect(p.isStopped, isTrue);
      expect(p.volume, 0);
      expect(p.itemProgressMs, isNull);
      expect(p.artworkUrl, isNull);
    });
  });

  group('artwork URL resolution (R-03 placeholder on 404)', () {
    test('relative URL resolves against the web root', () {
      expect(
        PlayerState.resolveArtwork(webRoot, './artwork/nowplaying'),
        Uri.parse('http://192.168.1.13:3689/artwork/nowplaying'),
      );
    });

    test('absolute URL passes through', () {
      expect(
        PlayerState.resolveArtwork(webRoot, 'https://example.com/cov.jpg'),
        Uri.parse('https://example.com/cov.jpg'),
      );
    });

    test('null/empty -> null (placeholder)', () {
      expect(PlayerState.resolveArtwork(webRoot, null), isNull);
      expect(PlayerState.resolveArtwork(webRoot, ''), isNull);
    });
  });

  group('NowPlayingItem.fromJson', () {
    test('maps a live queue item (docs/API.md object shape)', () {
      final item = NowPlayingItem.fromJson(const {
        'id': '1',
        'position': 0,
        'track_id': 196000,
        'title': 'Live Fixture',
        'artist': 'Fixture Artist',
        'album': 'Fixture Album',
        'album_id': '7',
        'length_ms': 353512,
        'uri': 'library:track:196000',
        'artwork_url': './artwork/item/196000',
      }, webRoot);
      expect(item.id, '1');
      expect(item.trackId, 196000);
      expect(item.title, 'Live Fixture');
      expect(item.artist, 'Fixture Artist');
      expect(item.album, 'Fixture Album');
      expect(item.lengthMs, 353512);
      expect(item.uri, 'library:track:196000');
      expect(
        item.artworkUrl,
        Uri.parse('http://192.168.1.13:3689/artwork/item/196000'),
      );
    });

    test('missing artwork falls back to the album artwork path', () {
      final item = NowPlayingItem.fromJson(const {
        'title': 'T',
        'album_id': '9',
      }, webRoot);
      expect(
        item.artworkUrl,
        Uri.parse('http://192.168.1.13:3689/artwork/album/9'),
      );
    });
  });
}
