import 'dart:math';

/// Exponential reconnect backoff: 1 s, 2 s, 4 s, ... capped at [maximum].
class Backoff {
  Backoff({
    this.initial = const Duration(seconds: 1),
    this.maximum = const Duration(seconds: 30),
    this.factor = 2,
  });

  final Duration initial;
  final Duration maximum;
  final int factor;

  int? _nextDelayMs;

  /// Next delay. First call returns [initial]; each subsequent call multiplies
  /// by [factor] until [maximum] is reached (it never exceeds [maximum]).
  Duration nextDelay() {
    final raw = _nextDelayMs == null
        ? initial.inMilliseconds
        : _nextDelayMs! * factor;
    _nextDelayMs = min(raw, maximum.inMilliseconds);
    return Duration(milliseconds: _nextDelayMs!);
  }

  /// Forget the failure streak (call after a successful connection).
  void reset() => _nextDelayMs = null;
}
