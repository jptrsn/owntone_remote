import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/player/pause_origin.dart';

/// D9 / R-14: pause-origin logic — a call auto-resumes only if the call
/// caused the pause; a user pause is never resumed by the app.
void main() {
  group('PauseOriginTracker', () {
    test('call while playing -> resume on call end', () {
      final t = PauseOriginTracker();
      t.onServerStateChanged(true); // server is playing
      t.onCallStart(wasPlaying: true);
      t.onServerStateChanged(false); // the app's own pause is observed
      expect(t.shouldResumeOnCallEnd, isTrue);
      expect(t.takeCallResume(), isTrue);
      expect(t.takeCallResume(), isFalse); // claim is consumed
    });

    test('call while user-paused -> NO auto-resume', () {
      final t = PauseOriginTracker();
      t.onUserPause();
      t.onServerStateChanged(false);
      t.onCallStart(wasPlaying: false); // nothing was playing
      expect(t.shouldResumeOnCallEnd, isFalse);
      expect(t.takeCallResume(), isFalse);
    });

    test('externally paused (web UI) -> treated as user, no resume', () {
      final t = PauseOriginTracker();
      t.onServerStateChanged(true);
      t.onServerStateChanged(false); // nobody in the app did this
      expect(t.origin, PauseOrigin.user);
      expect(t.takeCallResume(), isFalse);
    });

    test('play clears the origin (call ends after user resumed)', () {
      final t = PauseOriginTracker();
      t.onServerStateChanged(true);
      t.onCallStart(wasPlaying: true);
      t.onServerStateChanged(false);
      t.onServerStateChanged(true); // someone played in the web UI
      expect(t.shouldResumeOnCallEnd, isFalse);
    });

    test('user pause after call start is not claimed by the call', () {
      final t = PauseOriginTracker();
      t.onServerStateChanged(true);
      t.onCallStart(wasPlaying: true);
      // The call pause is ours; a *new* user pause on an already-paused
      // server keeps origin=call only if the state never flipped to user.
      expect(t.shouldResumeOnCallEnd, isTrue);
      t.onUserPause(); // user re-asserts pause (idempotent on server)
      // Origin is now user: the app must not "resume" on call end.
      expect(t.shouldResumeOnCallEnd, isFalse);
    });
  });
}
