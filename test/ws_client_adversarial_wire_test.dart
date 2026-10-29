import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/ws_client.dart';

import 'fakes/fake_ws_liveness_server.dart';

/// Test-adversary wire suite for unit 009 (R-02 silent-drop hardening),
/// run against the real `IOWebSocketChannel` built by `WsClient`'s default
/// channel factory — dart:io pings live below the Dart channel layer, so a
/// raw-TCP RFC-6455 peer is the only honest oracle
/// (`fakes/fake_ws_liveness_server.dart`, loopback only).
///
/// Contract sources (regenerated, not copied from the existing liveness
/// suite):
///  * unit spec L39-42: detect a silent death in ≤ 30 s; the 1→2→4→8→16→30 s
///    backoff sequence is an R-02 invariant;
///  * c1b (L71-72): one error/close on an `open` channel → `reconnecting` +
///    *a* reconnect attempt at the next backoff delay;
///  * c1d (L76): stop() cancels every timer — no reconnect after stop;
///  * L43-44 / docs/API.md § Websocket: re-subscribe `notify` after every
///    reconnect;
///  * dart:io ping semantics: first ping one interval after assignment, the
///    next timer re-armed on each pong, pong must land within one interval —
///    https://api.dart.dev/stable/3.11.5/dart-io/WebSocket/pingInterval.html
///  * IOWebSocketChannel (web_socket_channel 3.0.3):
///    https://pub.dev/documentation/web_socket_channel/3.0.3/io/IOWebSocketChannel-class.html
///  * flutter_test timeout parameter:
///    https://api.flutter.dev/flutter/flutter_test/test.html
///
/// Empirically established with a scratch probe before writing assertions
/// (so these tests do not encode assumptions about dart:io): a silently-dark
/// peer (pongs stop) fails the socket with a *done* event only, and a
/// handshake refusal surfaces *error then done*.

class _Recorder {
  _Recorder(WsClient ws) {
    statusSub = ws.status.listen(statuses.add);
    eventSub = ws.events.listen(events.add);
  }

  final List<String> statuses = [];
  final List<List<String>> events = [];
  late final StreamSubscription<String> statusSub;
  late final StreamSubscription<List<String>> eventSub;

  Future<void> dispose() async {
    await statusSub.cancel();
    await eventSub.cancel();
  }
}

Future<bool> _waitUntil(bool Function() cond, Duration max) async {
  final deadline = DateTime.now().add(max);
  while (!cond()) {
    if (!DateTime.now().isBefore(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return true;
}

/// Bring [ws] up against [server] until the first ping frame is on the wire
/// (dart:io sends it one `pingInterval` after assignment, so ~10 s + slack).
Future<void> _upToFirstPing(WsClient ws, FakeWsLivenessServer server) async {
  ws.start();
  expect(
    await _waitUntil(
      () => server.completedHandshakes >= 1,
      const Duration(seconds: 10),
    ),
    isTrue,
    reason: 'the default factory must complete the RFC-6455 handshake',
  );
  expect(
    await _waitUntil(
      () => server.pingsReceived >= 1,
      const Duration(seconds: 13),
    ),
    isTrue,
    reason:
        'the default factory must put a ping on the wire within one '
        'interval + slack (unit 009 c1a — liveness detection configured)',
  );
}

void main() {
  test('peer goes silent MID-SESSION (after answered pongs): detected within '
      'the ≤ 30 s bound, exactly ONE reconnect attempt, and the reconnect '
      're-subscribes notify on the wire (unit 009 Goal 1 / L39-42, c1b, '
      'L43-44; dart:io re-arms the ping timer on each pong, so detection '
      'starts from the last pong)', () async {
    final server = FakeWsLivenessServer(autoPong: true);
    await server.start();
    final ws = WsClient(
      uri: server.uri,
      subscriptions: const ['player', 'volume'],
    );
    final rec = _Recorder(ws);
    await _upToFirstPing(ws, server);

    final tDark = DateTime.now();
    server.setAutoPongFor(0, false); // dark just after a pong was answered
    final found = await _waitUntil(
      () => rec.statuses.contains('reconnecting'),
      const Duration(seconds: 35),
    );
    final detectMs = DateTime.now()
        .difference(tDark)
        .inMilliseconds; // upper bound
    expect(
      found,
      isTrue,
      reason:
          'a peer that stops ponging must be discovered while the '
          'socket still claims to be open — the dv-002 blind spot unit '
          '009 exists to close (unit spec L18-22)',
    );
    expect(
      detectMs,
      lessThanOrEqualTo(30 * 1000),
      reason:
          'silent death must be detected within the unit\'s ≤ 30 s '
          'bound (spec L41); observed upper bound $detectMs ms',
    );
    expect(
      rec.statuses.where((s) => s == 'reconnecting').length,
      1,
      reason:
          'one dead socket → "a reconnect attempt", not a doubled '
          'schedule (c1b L71-72)',
    );

    expect(
      await _waitUntil(
        () => server.completedHandshakes >= 2,
        const Duration(seconds: 12),
      ),
      isTrue,
      reason: 'the reconnect attempt (backoff 1 s) must reach the peer',
    );
    expect(
      await _waitUntil(
        () =>
            server.textFramesPerConnection.length >= 2 &&
            server.textFramesPerConnection[1].isNotEmpty,
        const Duration(seconds: 10),
      ),
      isTrue,
      reason:
          'the reconnect connection must receive the notify '
          're-subscribe (spec L43-44; docs/API.md § Websocket "On connect '
          '(and after every reconnect) send")',
    );
    expect(
      server.textFramesPerConnection[1].first,
      '{"notify":["player","volume"]}',
      reason: 'the re-subscribe payload must be the exact subscribe frame',
    );
    expect(
      rec.statuses.where((s) => s == 'open').length,
      2,
      reason: 'first open + post-reconnect open, no duplicates',
    );

    // Settled: the reconnect connection pongs normally, so nothing may
    // flap further.
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(
      server.completedHandshakes,
      2,
      reason:
          'healthy reconnect connection must not flap (0 spurious '
          'reconnects — spec c1c/healthy-idle criterion at wire level)',
    );
    ws.stop();
    await server.stop();
    await rec.dispose();
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('stop() during the backoff window of a ping-detected drop: no socket '
      'ever reaches the peer afterwards (unit 009 c1d L76 "stop() cancels '
      'every timer — no reconnect after stop", real transport)', () async {
    final server = FakeWsLivenessServer(autoPong: true);
    await server.start();
    final ws = WsClient(uri: server.uri, subscriptions: const ['player']);
    final rec = _Recorder(ws);
    await _upToFirstPing(ws, server);

    server.setAutoPongFor(0, false);
    expect(
      await _waitUntil(
        () => rec.statuses.contains('reconnecting'),
        const Duration(seconds: 35),
      ),
      isTrue,
      reason: 'detection must have fired for this test to be meaningful',
    );
    ws.stop();
    await pumpEventQueue(); // the broadcast 'stopped' arrives async
    final marker = rec.statuses.length;

    // The armed reconnect timer would have fired at +1 s; give it 3.5×
    // the delay plus margin.
    await Future<void>.delayed(const Duration(milliseconds: 3500));
    expect(
      server.completedHandshakes,
      1,
      reason: 'no reconnect may reach the wire after stop() (c1d)',
    );
    expect(
      rec.statuses.sublist(marker),
      isEmpty,
      reason: 'and no status after stop() — "stopped" is terminal',
    );
    await server.stop();
    await rec.dispose();
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('stop() racing a withheld handshake: nothing resurrects the client — '
      'no "open" after "stopped", no notify frame on the wire (task '
      'invariant "events after stop must not resurrect the client"; c1d). '
      'The 101 is released only AFTER stop() to expose any late '
      'ready-completion path (ws_client.dart _open subscribes after '
      '`await channel.ready` with no stopped-guard)', () async {
    final server = FakeWsLivenessServer()..holdHandshake = true;
    await server.start();
    final ws = WsClient(
      uri: server.uri,
      subscriptions: const ['player', 'volume'],
    );
    final rec = _Recorder(ws);
    ws.start();
    expect(
      await _waitUntil(
        () => server.upgradeRequested,
        const Duration(seconds: 5),
      ),
      isTrue,
      reason: 'the peer must have seen the upgrade request (ready pending)',
    );
    expect(rec.statuses, ['connecting'], reason: 'still handshaking');

    ws.stop();
    await pumpEventQueue(); // 'stopped' is delivered asynchronously
    expect(rec.statuses, ['connecting', 'stopped']);

    server.releaseHandshake(); // the server completes the handshake now
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(
      rec.statuses,
      ['connecting', 'stopped'],
      reason:
          'a handshake completing after stop() must not emit "open" — '
          'the app must never present `sync: live` over a stopped client '
          '(unit spec L18-22)',
    );
    expect(
      server.clientDataFrames,
      0,
      reason: 'nor send the notify frame post-stop on the wire',
    );
    expect(rec.events, isEmpty);

    ws.stop(); // double stop — may repeat 'stopped' but must stay inert
    await pumpEventQueue();
    expect(
      rec.statuses.where((s) => s != 'stopped').toList(),
      ['connecting'],
      reason:
          'nothing but the (repeatable) "stopped" emission may appear '
          'after the first stop — no resurrection',
    );
    expect(rec.statuses.last, 'stopped');
    await server.stop();
    await rec.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('reconnect storm against a TCP-accepting but handshake-refusing peer: '
      'attempt cadence follows the 1 s first backoff step (not before, not '
      'immediately doubled), the status stream alternates '
      'connecting/reconnecting once per failure, and stop() freezes the '
      'storm (c1b L71-72 + c1d L76 + spec L42 R-02 backoff invariant, on the '
      'real transport — this exercises the error→done failure path a '
      'handshake refusal produces)', () async {
    final server = FakeWsLivenessServer()..rejectHandshake = true;
    await server.start();
    final ws = WsClient(uri: server.uri, subscriptions: const ['player']);
    final rec = _Recorder(ws);
    ws.start();
    expect(
      await _waitUntil(
        () => server.acceptTimes.length >= 2,
        const Duration(seconds: 3),
      ),
      isTrue,
      reason:
          'the first backoff step must produce exactly one reconnect '
          'attempt (c1b)',
    );
    final firstGap = server.acceptTimes[1].difference(server.acceptTimes[0]);
    expect(
      firstGap.inMilliseconds,
      greaterThanOrEqualTo(850),
      reason:
          'the attempt must not arrive before the 1 s backoff delay '
          '(the existing c1b timing gate, re-derived on the wire)',
    );
    expect(
      firstGap.inMilliseconds,
      lessThanOrEqualTo(2000),
      reason: 'nor drift far past it (Backoff initial = 1 s, spec L42)',
    );

    // Hold until just before the second step (failure #2 arms +2 s).
    while (DateTime.now().difference(server.acceptTimes[1]).inMilliseconds <
        1500) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(
      server.acceptTimes.length,
      2,
      reason:
          'one failure = one attempt: a doubled schedule (error AND '
          'done each arming a timer) would show 3 accepts by now — '
          'violating "a reconnect attempt" (c1b) and leaving a timer '
          'stop() cannot cancel (c1d)',
    );
    expect(
      rec.statuses,
      ['connecting', 'reconnecting', 'connecting', 'reconnecting'],
      reason:
          'status alternates exactly once per connect/failure — no '
          'duplicated emissions for one event',
    );

    ws.stop();
    final marker = rec.statuses.length;
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(
      server.acceptTimes.length,
      2,
      reason:
          'stop() must cancel the armed reconnect timer(s) — the '
          'storm must not touch the peer again (c1d)',
    );
    expect(
      rec.statuses.sublist(marker),
      ['stopped'],
      reason: 'only the "stopped" emission may follow stop()',
    );
    await server.stop();
    await rec.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
