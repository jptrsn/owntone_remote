import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/audio/mirror_handler.dart';

/// `rockerStepFor` (R-06, R-14): volume-rocker direction → relative step.
/// `same` is Android's key-release / end-of-sequence marker and must stay a
/// no-op (spike Finding 10).
void main() {
  test('raise maps to the configured step (R-06)', () {
    expect(rockerStepFor(AndroidVolumeDirection.raise, step: 5), 5);
  });

  test('lower maps to the negated step (R-06)', () {
    expect(rockerStepFor(AndroidVolumeDirection.lower, step: 5), -5);
  });

  test('same is the key-release marker and maps to null — a step here '
      'silently cancels every press (spike Finding 10)', () {
    expect(rockerStepFor(AndroidVolumeDirection.same, step: 5), isNull);
  });

  test('the step is configurable, not hardcoded to 5 (R-14)', () {
    expect(rockerStepFor(AndroidVolumeDirection.raise, step: 10), 10);
    expect(rockerStepFor(AndroidVolumeDirection.lower, step: 10), -10);
  });
}
