import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';

/// R-03, device-found: the progress the now-playing screen displays.
///
/// Device incident: the screen's ticker extrapolates progress while
/// playing and freezes on pause (it only runs then). When the item
/// changes while paused, the frozen value belongs to the *previous*
/// item — observed on-device as a 03:17 elapsed label on a 02:25 track
/// whose server progress was 392 ms. This pure mapping is pinned here;
/// the ticker itself uses the wall clock, which a fake-async widget
/// test cannot advance, so the mapping is the testable seam.
void main() {
  group('NowPlayingBody.displayedProgressMs', () {
    test('paused: the server progress wins over a stale ticker value', () {
      expect(
        NowPlayingBody.displayedProgressMs(
          dragMs: null,
          isPlaying: false,
          tickerMs: 197000,
          serverMs: 392,
        ),
        392,
      );
    });

    test('playing: the ticker extrapolation wins over the server value', () {
      expect(
        NowPlayingBody.displayedProgressMs(
          dragMs: null,
          isPlaying: true,
          tickerMs: 5200,
          serverMs: 1000,
        ),
        5200,
      );
    });

    test('dragging: the finger wins over everything', () {
      expect(
        NowPlayingBody.displayedProgressMs(
          dragMs: 42000,
          isPlaying: true,
          tickerMs: 5200,
          serverMs: 1000,
        ),
        42000,
      );
    });

    test('nothing known: zero', () {
      expect(
        NowPlayingBody.displayedProgressMs(
          dragMs: null,
          isPlaying: false,
          tickerMs: null,
          serverMs: null,
        ),
        0,
      );
    });
  });
}
