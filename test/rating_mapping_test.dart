import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/library/rating.dart';

/// R-12 (unit 006 C5): the 0–100 ↔ 0–5 mapping — table-driven, incl. the
/// unit's boundary values 19/21/39/41 (they straddle the floor thresholds
/// at 20 and 40, pinning floor-vs-round), all six canonical server values,
/// and out-of-range clamps.
void main() {
  group('starsForRating (display, floor-quantized)', () {
    // (server 0–100, stars) — the unit's mapping table.
    const cases = <(int?, int)>[
      // the six canonical values
      (null, 0), // unrated (absent field) == 0
      (0, 0),
      (20, 1),
      (40, 2),
      (60, 3),
      (80, 4),
      (100, 5),
      // the unit's boundary pairs: each straddles a floor threshold
      (19, 0),
      (21, 1),
      (39, 1),
      (41, 2),
      // mid-band values (never round up)
      (10, 0),
      (30, 1),
      (50, 2),
      (70, 3),
      (90, 4),
      (99, 4),
      // clamps (defensive: a hand-crafted value must not crash or overfill)
      (-10, 0),
      (120, 5),
    ];

    for (final (input, expected) in cases) {
      test('rating $input → $expected stars', () {
        expect(starsForRating(input), expected);
      });
    }
  });

  group('ratingForStars (writes, canonical values only)', () {
    const cases = <(int, int)>[
      (0, 0),
      (1, 20),
      (2, 40),
      (3, 60),
      (4, 80),
      (5, 100),
      // clamps
      (-1, 0),
      (6, 100),
    ];

    for (final (stars, expected) in cases) {
      test('$stars stars → rating $expected', () {
        expect(ratingForStars(stars), expected);
      });
    }

    test('round-trip: a value the app wrote always reads back the same', () {
      for (var s = 0; s <= 5; s++) {
        expect(starsForRating(ratingForStars(s)), s);
      }
    });
  });
}
