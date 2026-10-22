import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/player/call_pause.dart';
import 'package:owntone_remote/src/player/pause_origin.dart';

/// D9 / R-08: a call pauses the server only once it is confirmed (500ms
/// flap filter), and call end auto-resumes only if the call caused the
/// pause — including when the call ends before the pause acks.
void main() {
  group('CallPauseTracker', () {
    group('flap filter', () {
      test(
        'ringing->idle flap is ignored, machine recovers for the real call',
        () {
          final t = CallPauseTracker();
          expect(t.onRinging(), isTrue);
          expect(t.onIdle(), isFalse); // flap < 500ms: nothing was ever claimed
          expect(t.origin, PauseOrigin.unknown);
          expect(t.inCall, isFalse);
          expect(t.debouncing, isFalse);
          expect(t.onRinging(), isTrue); // the real call
          expect(t.onFlapWindowElapsed(), isTrue);
        },
      );

      test('repeated ringing during the window is not a new call', () {
        final t = CallPauseTracker();
        expect(t.onRinging(), isTrue);
        expect(t.onRinging(), isFalse);
      });

      test('stray idle with no call is a no-op', () {
        final t = CallPauseTracker();
        expect(t.onIdle(), isFalse);
      });
    });

    group('confirmation', () {
      test('active during the window confirms immediately', () {
        final t = CallPauseTracker();
        expect(t.onRinging(), isTrue);
        expect(t.onActive(), isTrue);
        expect(t.onFlapWindowElapsed(), isFalse); // already confirmed
        expect(t.onIdle(), isFalse); // no pause was ever reported
      });

      test('active without ringing confirms', () {
        final t = CallPauseTracker();
        expect(t.onActive(), isTrue);
      });
    });

    group('origin claims', () {
      test('happy path: call pauses, call end resumes', () {
        final t = CallPauseTracker();
        t.onServerStateChanged(true); // server is playing
        expect(t.onRinging(), isTrue);
        expect(t.onFlapWindowElapsed(), isTrue);
        t.onPauseIssued();
        expect(t.onPauseFinished(true), isFalse); // the call is still on
        expect(t.origin, PauseOrigin.call);
        expect(t.shouldResumeOnCallEnd, isTrue);
        expect(t.onIdle(), isTrue); // the call caused the pause
        expect(t.origin, PauseOrigin.unknown);
        expect(t.onIdle(), isFalse); // nothing left to resume
      });

      test('call while user-paused: the pause is not claimed (R-08 no-op)', () {
        final t = CallPauseTracker();
        t.onUserPause();
        expect(t.onRinging(), isTrue);
        expect(t.onFlapWindowElapsed(), isTrue);
        // The server was not playing, so the controller never issued a
        // pause — nothing is claimed.
        expect(t.onIdle(), isFalse);
        expect(t.origin, PauseOrigin.user);
      });

      test('call during stop: no call origin', () {
        final t = CallPauseTracker();
        t.onServerStateChanged(false); // a stop observation
        expect(t.onRinging(), isTrue);
        expect(t.onFlapWindowElapsed(), isTrue);
        expect(t.onIdle(), isFalse);
        expect(t.origin, isNot(PauseOrigin.call));
      });

      test('user pause after the call-pause claim: user wins', () {
        final t = CallPauseTracker();
        t.onServerStateChanged(true);
        t.onRinging();
        t.onFlapWindowElapsed();
        t.onPauseIssued();
        t.onPauseFinished(true);
        expect(t.origin, PauseOrigin.call);
        t.onUserPause(); // user re-asserts pause
        expect(t.onIdle(), isFalse); // no resume of a user pause
      });

      test('server played externally after the claim: no resume', () {
        final t = CallPauseTracker();
        t.onServerStateChanged(true);
        t.onRinging();
        t.onFlapWindowElapsed();
        t.onPauseIssued();
        t.onPauseFinished(true);
        expect(t.origin, PauseOrigin.call);
        t.onServerStateChanged(true); // someone played (web UI, etc.)
        expect(t.onIdle(), isFalse);
      });
    });

    group('races', () {
      test('call ends before the pause acks: resume on the ack', () {
        final t = CallPauseTracker();
        t.onServerStateChanged(true);
        t.onRinging();
        t.onFlapWindowElapsed();
        t.onPauseIssued();
        expect(t.onIdle(), isFalse); // pause still in flight
        expect(t.resumeAfterAck, isTrue);
        expect(t.onPauseFinished(true), isTrue); // resume now
        expect(t.origin, PauseOrigin.unknown); // no lingering call origin
      });

      test(
        'call ends before the pause acks AND the pause fails: no resume',
        () {
          final t = CallPauseTracker();
          t.onServerStateChanged(true);
          t.onRinging();
          t.onFlapWindowElapsed();
          t.onPauseIssued();
          t.onIdle();
          expect(t.onPauseFinished(false), isFalse);
          expect(t.origin, PauseOrigin.unknown);
          expect(t.resumeAfterAck, isFalse);
        },
      );

      test('failed pause, call still on: no resume on idle', () {
        final t = CallPauseTracker();
        t.onServerStateChanged(true);
        t.onRinging();
        t.onFlapWindowElapsed();
        t.onPauseIssued();
        expect(t.onPauseFinished(false), isFalse);
        expect(t.origin, PauseOrigin.unknown);
        expect(t.inCall, isTrue);
        expect(t.onIdle(), isFalse); // the server never paused
      });

      test('second call while a call is on: its end resumes the call-caused '
          'pause', () {
        final t = CallPauseTracker();
        t.onServerStateChanged(true);
        t.onRinging();
        t.onFlapWindowElapsed();
        t.onPauseIssued();
        t.onPauseFinished(true);
        expect(t.origin, PauseOrigin.call); // the first call is still on
        expect(t.onRinging(), isFalse); // not a new call
        expect(t.onIdle(), isTrue);
      });

      test('double idle: the resume is claimed once', () {
        final t = CallPauseTracker();
        t.onServerStateChanged(true);
        t.onRinging();
        t.onFlapWindowElapsed();
        t.onPauseIssued();
        t.onPauseFinished(true);
        expect(t.onIdle(), isTrue);
        expect(t.onIdle(), isFalse);
      });
    });
  });
}
