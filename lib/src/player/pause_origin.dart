/// Tracks *why* the server is paused, so call-end can decide whether to
/// auto-resume (D9: pause on incoming call, resume on call end — but only if
/// the call caused the pause).
enum PauseOrigin {
  /// A human (app UI, web UI, or otherwise) paused it.
  user,

  /// This app paused it because of a phone call.
  call,

  /// Not paused, or unknown.
  unknown,
}

class PauseOriginTracker {
  PauseOrigin origin = PauseOrigin.unknown;

  /// The app pauses because a call arrived. Only claims the pause if the
  /// server was actually playing ([wasPlaying]) — a call arriving while the
  /// user had paused must NOT own the pause (no auto-resume).
  void onCallStart({required bool wasPlaying}) {
    if (wasPlaying) origin = PauseOrigin.call;
  }

  void onUserPlay() => origin = PauseOrigin.unknown;
  void onUserPause() => origin = PauseOrigin.user;
  void onUserStop() => origin = PauseOrigin.unknown;

  /// Server state as observed on a refetch (covers app actions, web-UI
  /// changes and reconnect refetches alike).
  void onServerStateChanged(bool playing) {
    if (playing) {
      origin = PauseOrigin.unknown;
    } else if (origin != PauseOrigin.call) {
      origin = PauseOrigin.user;
    }
  }

  /// True if the call caused the current pause and playback should resume
  /// when the call ends. Pure query.
  bool get shouldResumeOnCallEnd => origin == PauseOrigin.call;

  /// Consuming variant: claims the resume (clears the origin) if — and only
  /// if — the call caused the pause.
  bool takeCallResume() {
    if (origin != PauseOrigin.call) return false;
    origin = PauseOrigin.unknown;
    return true;
  }
}
