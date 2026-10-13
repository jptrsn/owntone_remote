import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/audio/mirror_handler.dart';
import 'package:owntone_remote/src/player/player_state.dart';

/// R-07: the notification's metadata/controls mapping (title/artist/album,
/// artwork, transport controls, progress) — pure functions in
/// mirror_handler.dart, so the mapping is proven without a platform.
void main() {
  final webRoot = Uri.parse('http://192.168.1.13:3689/');

  PlayerState state({
    String s = 'pause',
    int? progress = 26368,
    int? length = 353512,
  }) => PlayerState(
    state: s,
    repeat: Repeat.off,
    consume: false,
    shuffle: false,
    volume: 75,
    itemId: 196000,
    itemLengthMs: length,
    itemProgressMs: progress,
  );

  NowPlayingItem item({String? title = 'Killing Me Softly'}) =>
      NowPlayingItem.fromJson({
        'id': '1',
        'track_id': 196000,
        'title': title,
        'artist': 'Fugees',
        'album': 'The Score',
        'length_ms': 353512,
        'uri': 'library:track:196000',
        'artwork_url': './artwork/item/196000',
      }, webRoot);

  group('mediaItemFor (R-07 metadata)', () {
    test('maps title/artist/album/artwork/duration', () {
      final mi = mediaItemFor(item: item(), p: state());
      expect(mi, isNotNull);
      expect(mi!.id, 'library:track:196000');
      expect(mi.title, 'Killing Me Softly');
      expect(mi.artist, 'Fugees');
      expect(mi.album, 'The Score');
      expect(
        mi.artUri,
        Uri.parse('http://192.168.1.13:3689/artwork/item/196000'),
      );
      expect(mi.duration, const Duration(milliseconds: 353512));
    });

    test('no item → null (stopped / empty queue)', () {
      expect(
        mediaItemFor(item: null, p: state(s: 'stop', progress: 0)),
        isNull,
      );
    });

    test('missing title/artist fall back to Unknown (no crash)', () {
      final mi = mediaItemFor(
        item: NowPlayingItem.fromJson({'id': '7'}, webRoot),
        p: state(),
      );
      expect(mi!.title, 'Unknown title');
      expect(mi.artist, 'Unknown artist');
      expect(mi.artUri, isNull);
      expect(mi.duration, isNull);
    });
  });

  group('controlsFor (R-07 transport controls)', () {
    test('playing → pause/next/previous', () {
      expect(controlsFor(state(s: 'play')), [
        MediaControl.pause,
        MediaControl.skipToNext,
        MediaControl.skipToPrevious,
      ]);
    });

    test('paused/stopped → play/next/previous', () {
      expect(controlsFor(state(s: 'pause')), [
        MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.skipToPrevious,
      ]);
      expect(controlsFor(state(s: 'stop')).first, MediaControl.play);
    });
  });

  group('playbackStateFor (R-07 progress + playing flag)', () {
    test('paused: playing=false, position from server progress', () {
      final ps = playbackStateFor(state(s: 'pause', progress: 26368));
      expect(ps.playing, isFalse);
      expect(ps.updatePosition, const Duration(milliseconds: 26368));
      expect(ps.speed, 1.0);
    });

    test('playing: playing=true', () {
      expect(playbackStateFor(state(s: 'play')).playing, isTrue);
    });

    test('ticker override: positionMs wins over the server value', () {
      final ps = playbackStateFor(
        state(s: 'play', progress: 1000),
        positionMs: 1500,
      );
      expect(ps.updatePosition, const Duration(milliseconds: 1500));
    });

    test('absent progress → 0 (stopped)', () {
      final ps = playbackStateFor(state(s: 'stop', progress: null));
      expect(ps.updatePosition, Duration.zero);
    });
  });
}
