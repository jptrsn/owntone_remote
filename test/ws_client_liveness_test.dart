import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';

import 'fakes/fake_ws_liveness_server.dart';

/// Liveness detection on the open WS (unit 009, R-02 blind spot): the default
/// channel factory must hand the open socket a ping interval so a peer that
/// goes silently dark (no FIN/RST, no frames) is discovered and drives the
/// reconnect path — the app must never present `sync: live` over a dead
/// connection.
///
/// These tests point `WsClient` at [FakeWsLivenessServer] (hermetic loopback
/// socket, never the LAN server) with the **default** channel factory — no
/// `channelFactory` is injected, so what runs is exactly the production
/// `IOWebSocketChannel.connect` configuration. dart:io semantics per
/// https://api.dart.dev/stable/3.11.5/dart-io/WebSocket/pingInterval.html :
/// the first ping is sent one `pingInterval` after it is assigned, and if a
/// ping goes unponged the socket is closed (goingAway) at 2× the interval.
/// Hence: ping observed ⇒ `pingInterval` configured; ≤ 13 s budget enforces
/// the ≤ 10 s cap; silent peer ⇒ `reconnecting` within ≤ 25 s (spec: ≤ 30 s).
///
/// Kill-check: deleting `pingInterval:` from the default factory in
/// `lib/src/api/ws_client.dart` makes all three tests fail (no ping frame is
/// ever observed on the wire).
void main() {
  group(
    'WsClient liveness — default channel factory (R-02, unit 009 c1a/c1c)',
    () {
      test('R-02 unit 009 c1a: default factory configures liveness detection — '
          'client pings the idle peer within pingInterval (≤ 10 s)', () async {
        final server = FakeWsLivenessServer(autoPong: true);
        final uri = await server.start();
        final statuses = <String>[];
        // No channelFactory: production default factory under test. Long
        // backoff so nothing reconnects during the observation window.
        final client = WsClient(
          uri: uri,
          subscriptions: ['player'],
          backoff: Backoff(initial: const Duration(minutes: 5)),
        );
        client.status.listen(statuses.add);
        client.start();

        final opened = await _until(
          () => statuses.contains('open'),
          const Duration(seconds: 5),
        );
        final sawPing = await _until(
          () => server.pingsReceived >= 1,
          const Duration(seconds: 13),
        );
        client.stop();
        await server.stop();

        expect(
          opened,
          isTrue,
          reason:
              'handshake with the loopback peer should reach open; '
              'statuses=$statuses',
        );
        expect(
          sawPing,
          isTrue,
          reason:
              'the default channel factory must set pingInterval ≤ 10 s on '
              'the opened socket: dart:io sends the first ping one interval '
              'after assignment, but the peer saw no ping frame within 13 s '
              '(no liveness detection = the dv-002 silent-drop blind spot).',
        );
      }, timeout: const Timeout(Duration(seconds: 60)));

      test(
        'R-02 unit 009 c1c: healthy idle with answered pings — no reconnect '
        'within 3× pingInterval (liveness traffic on the wire proves pings land)',
        () async {
          final server = FakeWsLivenessServer(autoPong: true);
          final uri = await server.start();
          final statuses = <String>[];
          final client = WsClient(
            uri: uri,
            subscriptions: ['player'],
            backoff: Backoff(initial: const Duration(minutes: 5)),
          );
          client.status.listen(statuses.add);
          client.start();
          expect(
            await _until(
              () => statuses.contains('open'),
              const Duration(seconds: 5),
            ),
            isTrue,
            reason: 'handshake should reach open; statuses=$statuses',
          );

          // 3× the ≤ 10 s cap + margin: if pongs did not land, the socket
          // would already have died on the first unanswered ping (≤ 2×10 s).
          await Future<void>.delayed(const Duration(seconds: 34));
          client.stop();
          await server.stop();

          expect(
            server.pingsReceived,
            greaterThanOrEqualTo(2),
            reason:
                'expected liveness traffic while idle: dart:io pings every '
                'interval (≤ 10 s) and the next timer starts on each pong, so '
                '≥ 2 pings belong on the wire in 3× the cap (the server '
                'pongs like OwnTone does).',
          );
          expect(
            statuses,
            isNot(contains('reconnecting')),
            reason:
                'answered pings must never trigger a spurious reconnect; '
                'statuses=$statuses',
          );
          expect(
            server.handshakes,
            1,
            reason:
                'healthy idle must not re-handshake (0 spurious reconnects)',
          );
        },
        timeout: const Timeout(Duration(seconds: 90)),
      );

      test(
        'R-02 unit 009 c1a: peer goes silently dark (pings unanswered) — '
        'reconnecting within 2× pingInterval + margin (≤ 25 s, spec ≤ 30 s)',
        () async {
          final server = FakeWsLivenessServer(autoPong: false);
          final uri = await server.start();
          final statuses = <String>[];
          final client = WsClient(
            uri: uri,
            subscriptions: ['player'],
            // Long initial delay: a reconnect attempt during the window would
            // add handshakes; we only assert the *transition*.
            backoff: Backoff(initial: const Duration(minutes: 5)),
          );
          client.status.listen(statuses.add);
          client.start();
          expect(
            await _until(
              () => statuses.contains('open'),
              const Duration(seconds: 5),
            ),
            isTrue,
            reason: 'handshake should reach open; statuses=$statuses',
          );

          final detected = await _until(
            () => statuses.contains('reconnecting'),
            const Duration(seconds: 25),
          );
          final pings = server.pingsReceived;
          client.stop();
          await server.stop();

          expect(
            pings,
            greaterThanOrEqualTo(1),
            reason:
                'the client must probe an idle socket: the peer never pongs, '
                'so detection starts only once a ping is in flight — no ping '
                'frame reached the peer at all.',
          );
          expect(
            detected,
            isTrue,
            reason:
                'a silent drop (no FIN/RST, pings unanswered) must be '
                'discovered and drive the reconnect path within ≤ 30 s '
                '(unit 009): dart:io closes the socket on the first '
                'unanswered ping, which must surface as reconnecting. '
                'statuses=$statuses',
          );
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );
    },
  );
}

/// Polls [cond] every 100 ms until it is true or [limit] elapses.
Future<bool> _until(bool Function() cond, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return cond();
}
