// TrackRow field-composition contract (R-15 Songs rows) — PR #55 review F3:
// the degraded-field branches of showArtist/showAlbum had no test; every
// Songs fixture populates both fields.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/library/library_models.dart';
import 'package:owntone_remote/src/ui/browse_rows.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Track _track({required String artist, required String album}) => Track(
  id: 1,
  title: 'Song Title',
  artist: artist,
  album: album,
  albumId: 'a1',
  lengthMs: 240000,
  uri: 'file:///x.flac',
);

void main() {
  group('TrackRow field composition (R-15)', () {
    testWidgets('showAlbum without showArtist: only the album shows', (
      tester,
    ) async {
      // Documented at browse_rows.dart field doc ("without it only the
      // album shows") — previously pinned by no test.
      await tester.pumpWidget(
        _host(
          TrackRow(
            track: _track(artist: 'Hidden Artist', album: 'Visible Album'),
            enabled: true,
            onPlay: () {},
            showArtist: false,
            showAlbum: true,
          ),
        ),
      );
      expect(find.text('Visible Album'), findsOneWidget);
      expect(find.textContaining('Hidden Artist'), findsNothing);
      expect(
        tester
            .widgetList<Semantics>(find.byType(Semantics))
            .map((s) => s.properties.label ?? '')
            .firstWhere((l) => l.startsWith('Song Title')),
        startsWith('Song Title, Visible Album, 4:00, 0 stars'),
        reason: 'semantics label composes album only',
      );
    });

    testWidgets('Songs row with BOTH fields empty: no secondary line, no '
        'dangling separator (label "title, M:SS")', (tester) async {
      await tester.pumpWidget(
        _host(
          TrackRow(
            track: _track(artist: '', album: ''),
            enabled: true,
            onPlay: () {},
            showArtist: true,
            showAlbum: true,
          ),
        ),
      );
      expect(find.textContaining(' - '), findsNothing);
      expect(
        tester
            .widgetList<Semantics>(find.byType(Semantics))
            .map((s) => s.properties.label ?? '')
            .firstWhere((l) => l.startsWith('Song Title')),
        startsWith('Song Title, 4:00, 0 stars'),
        reason: 'empty detail drops the secondary line and separators',
      );
    });
  });
}
