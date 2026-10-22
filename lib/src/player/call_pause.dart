import 'pause_origin.dart';

/// Decides when an incoming call is real enough to pause the server (D9,
/// R-08) and, at call end, whether the app owns the pause.
///
/// Composes a [PauseOriginTracker] for the origin semantics. On top of that
/// it applies the flap filter — a ringing→idle flap shorter than the 500ms
/// window never pauses the server — and defers the resume to the pause ack
/// when the call ends before the ack lands ([resumeAfterAck]).
///
/// Synchronous and pure: the [PlayerController] owns the 500ms timer and the
/// REST calls, and feeds the results back here.
class CallPauseTracker {
  CallPauseTracker();

  final PauseOriginTracker _origin = PauseOriginTracker();

  bool _debouncing = false;
  bool _inCall = false;
  bool _pauseInFlight = false;
  bool _resumeAfterAck = false;

  /// A ringing arrived and the 500ms window has not yet elapsed or been cut
  /// short by idle.
  bool get debouncing => _debouncing;

  /// The call is confirmed real (the window elapsed, or it connected).
  bool get inCall => _inCall;

  /// We issued the pause; its ack has not been reported yet.
  bool get pauseInFlight => _pauseInFlight;

  /// The call ended while the pause was in flight; resume once the ack
  /// lands.
  bool get resumeAfterAck => _resumeAfterAck;

  /// Delegates to the inner [PauseOriginTracker].
  PauseOrigin get origin => _origin.origin;

  /// Delegates to the inner [PauseOriginTracker].
  bool get shouldResumeOnCallEnd => _origin.shouldResumeOnCallEnd;

  /// RINGING: opens the flap window. True only for a NEW call; the caller
  /// must then start the 500ms timer.
  bool onRinging() {
    if (_inCall || _debouncing) return false;
    _debouncing = true;
    return true;
  }

  /// The 500ms window elapsed: the call is real. True means the caller must
  /// pause the server if it is playing.
  bool onFlapWindowElapsed() {
    if (!_debouncing) return false;
    _debouncing = false;
    _inCall = true;
    return true;
  }

  /// OFFHOOK: a connected call is real even without a preceding RINGING
  /// event. True means the caller must pause if playing.
  bool onActive() {
    if (_inCall) return false;
    _debouncing = false;
    _inCall = true;
    return true;
  }

  /// IDLE: the call is over. True means the caller must resume now — this
  /// app paused the server for the call. If the pause is still in flight
  /// the resume is deferred to the ack ([resumeAfterAck]).
  bool onIdle() {
    if (_debouncing) {
      _debouncing = false;
      return false;
    }
    if (!_inCall) return false;
    _inCall = false;
    if (_origin.takeCallResume()) return true;
    if (_pauseInFlight) _resumeAfterAck = true;
    return false;
  }

  /// The pause request was sent (only after confirmation, only while the
  /// server was playing).
  void onPauseIssued() {
    _pauseInFlight = true;
  }

  /// The pause result. True means the caller must resume now — the call
  /// ended while the pause was in flight, so the resume is due.
  bool onPauseFinished(bool ok) {
    _pauseInFlight = false;
    if (!ok) {
      _resumeAfterAck = false;
      return false;
    }
    if (_resumeAfterAck) {
      _resumeAfterAck = false;
      _origin.origin = PauseOrigin.unknown;
      return true;
    }
    _origin.origin = PauseOrigin.call;
    return false;
  }

  void onUserPlay() => _origin.onUserPlay();

  void onUserPause() => _origin.onUserPause();

  void onUserStop() => _origin.onUserStop();

  /// Server state as observed on a refetch (delegates).
  void onServerStateChanged(bool playing) =>
      _origin.onServerStateChanged(playing);
}
