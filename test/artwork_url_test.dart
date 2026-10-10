import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';

/// Artwork downsizing (spike unit: `?maxwidth=600` on server-hosted art).
void main() {
  group('ArtworkBox.withMaxWidth', () {
    test('null stays null', () {
      expect(ArtworkBox.withMaxWidth(null), isNull);
    });

    test('appends maxwidth=600 to a bare URL', () {
      final url = Uri.parse('http://192.168.1.13:3689/artwork/nowplaying');
      expect(
        ArtworkBox.withMaxWidth(url),
        Uri.parse('http://192.168.1.13:3689/artwork/nowplaying?maxwidth=600'),
      );
    });

    test('keeps an explicit maxwidth', () {
      final url = Uri.parse('http://x/artwork?maxwidth=128&foo=bar');
      expect(ArtworkBox.withMaxWidth(url), url);
    });

    test('preserves existing query parameters', () {
      final url = Uri.parse('http://x/artwork?foo=bar');
      expect(
        ArtworkBox.withMaxWidth(url),
        Uri.parse('http://x/artwork?maxwidth=600&foo=bar'),
      );
    });
  });
}
