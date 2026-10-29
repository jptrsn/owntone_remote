import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';

/// Test-adversary boundary tests for unit 009 (R-02 invariant, unit spec
/// L42): "Reconnect uses the existing Backoff — the 1→2→4→8→16→30 s
/// sequence is an R-02 invariant, unchanged."
void main() {
  group('unit 009 adversary — Backoff boundaries', () {
    test('the default sequence is exactly 1, 2, 4, 8, 16, 30, 30 … s '
        '(spec L42 / backoff.dart:17-18 contract)', () {
      final backoff = Backoff();
      final delays = <int>[
        for (var i = 0; i < 7; i++) backoff.nextDelay().inMilliseconds,
      ];
      expect(delays, [1000, 2000, 4000, 8000, 16000, 30000, 30000]);
    });

    test('the delay never exceeds the 30 s cap over a long failure streak '
        '(no overflow/wrap when the raw doubling grows unbounded — '
        'backoff.dart:23 clamps the *stored* value, so the streak stays '
        'sane forever)', () {
      final backoff = Backoff();
      for (var i = 0; i < 64; i++) {
        final delay = backoff.nextDelay();
        expect(
          delay.inMilliseconds,
          lessThanOrEqualTo(30 * 1000),
          reason: 'call $i exceeded the cap',
        );
        expect(
          delay.inMilliseconds,
          greaterThan(0),
          reason: 'call $i went non-positive',
        );
      }
    });

    test('reset() after a successful connection forgets the streak — the very '
        'next delay is back to 1 s (backoff.dart:27-28; ws_client.dart calls '
        'it on first message and on ready)', () {
      final backoff = Backoff();
      backoff.nextDelay();
      backoff.nextDelay();
      expect(backoff.nextDelay().inMilliseconds, 4000);
      backoff.reset();
      expect(backoff.nextDelay().inMilliseconds, 1000);
      expect(
        backoff.nextDelay().inMilliseconds,
        2000,
        reason:
            'and the '
            'progression restarts from the initial value, not from the old '
            'streak',
      );
    });
  });
}
