import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';

/// WS reconnect backoff (R-02): 1 s doubling, capped at 30 s, resettable.
void main() {
  group('Backoff', () {
    test('doubles from 1s to the 30s cap', () {
      final b = Backoff();
      expect(b.nextDelay(), const Duration(seconds: 1));
      expect(b.nextDelay(), const Duration(seconds: 2));
      expect(b.nextDelay(), const Duration(seconds: 4));
      expect(b.nextDelay(), const Duration(seconds: 8));
      expect(b.nextDelay(), const Duration(seconds: 16));
      // 32s would exceed the cap -> 30s.
      expect(b.nextDelay(), const Duration(seconds: 30));
      expect(b.nextDelay(), const Duration(seconds: 30));
      expect(b.nextDelay(), const Duration(seconds: 30));
    });

    test('reset returns to the initial delay', () {
      final b = Backoff();
      b.nextDelay();
      b.nextDelay();
      b.reset();
      expect(b.nextDelay(), const Duration(seconds: 1));
    });

    test('honours custom initial/factor/maximum', () {
      final b = Backoff(
        initial: const Duration(seconds: 5),
        maximum: const Duration(seconds: 12),
        factor: 3,
      );
      expect(b.nextDelay(), const Duration(seconds: 5));
      expect(b.nextDelay(), const Duration(seconds: 12)); // 15 capped to 12
      expect(b.nextDelay(), const Duration(seconds: 12));
    });
  });
}
