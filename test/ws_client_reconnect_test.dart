import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';

import 'fakes/fake_ws_channel.dart';

/// Reconnect contract on `WsClient` (R-02, unit 009 c1b/c1d), in-memory via
/// [FakeWsChannel].
///
/// Delta over the pre-existing `ws_client_test.dart` (which already covers
/// "server drops the connection → reconnecting + reconnect + resubscribe"):
/// these tests add the *error* path on an already-**open** channel and the
/// backoff **timing gate** — no attempt may fire before the delay, which is
/// what stops a detected-silent socket from becoming a connect storm.
/// c1d guards that `stop()` cancels the scheduled attempt: a reconnect that
/// outlives `stop()` reopens a connection the caller (e.g.
/// `ConnectionController.disconnect`) has deliberately put down.
void main() {
  Future<void> pump([int ms = 20]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  group('WsClient reconnect contract (R-02, unit 009 c1b/c1d)', () {
    (WsClient, List<FakeWsChannel>, List<String>) startClient({
      required Duration initial,
    }) {
      final channels = <FakeWsChannel>[];
      final client = WsClient(
        uri: Uri.parse('ws://x:3688/'),
        subscriptions: ['player'],
        backoff: Backoff(initial: initial),
        channelFactory: (uri) {
          final c = FakeWsChannel();
          channels.add(c);
          return c;
        },
      );
      final statuses = <String>[];
      client.status.listen(statuses.add);
      client.start();
      return (client, channels, statuses);
    }

    test(
      'R-02 unit 009 c1b: close on an open channel → reconnecting, next '
      'attempt only at the backoff delay (not before), resubscribed',
      () async {
        final (client, channels, statuses) = startClient(
          initial: const Duration(milliseconds: 60),
        );
        await pump(10);
        expect(statuses, contains('open'));

        channels.first.serverClose();
        await pump(20);
        expect(statuses, contains('reconnecting'));
        expect(
          channels,
          hasLength(1),
          reason:
              'no reconnect attempt may fire before the 60 ms backoff '
              'delay (R-02 invariant 1 s → 30 s cap sequence)',
        );

        await pump(120);
        expect(channels, hasLength(2));
        expect(
          channels[1].clientSent,
          isNotEmpty,
          reason: 're-subscribe on the fresh connection (D2)',
        );
        expect(statuses, contains('open'));
        client.stop();
      },
    );

    test(
      'R-02 unit 009 c1b: error on an open channel (socket failure) → '
      'reconnecting, next attempt only at the backoff delay (not before)',
      () async {
        final (client, channels, statuses) = startClient(
          initial: const Duration(milliseconds: 60),
        );
        await pump(10);
        expect(statuses, contains('open'));

        // This is the path a dart:io ping timeout walks into (unponged ping
        // → socket failure): the error must drive reconnect, not silence.
        channels.first.serverFail();
        await pump(20);
        expect(statuses, contains('reconnecting'));
        expect(
          channels,
          hasLength(1),
          reason:
              'no reconnect attempt may fire before the 60 ms backoff delay',
        );

        await pump(120);
        expect(channels, hasLength(2));
        expect(
          channels[1].clientSent,
          isNotEmpty,
          reason: 're-subscribe on the fresh connection (D2)',
        );
        client.stop();
      },
    );

    test('R-02 unit 009 c1d: stop() with a reconnect pending cancels the timer '
        '— no attempt after stop', () async {
      final (client, channels, statuses) = startClient(
        initial: const Duration(milliseconds: 100),
      );
      await pump(10);
      expect(statuses, contains('open'));

      channels.first.serverClose();
      await pump(10);
      expect(statuses, contains('reconnecting')); // attempt is scheduled

      client.stop();
      await pump(300); // 3× the pending delay
      expect(
        channels,
        hasLength(1),
        reason:
            'stop() must cancel the pending reconnect timer — no '
            'channel may be created after stop',
      );
      expect(statuses, contains('stopped'));
    });

    test('R-02 unit 009 c1d: stop() while open, then the server drops the '
        'stale channel → no reconnect, no reconnecting status', () async {
      final (client, channels, statuses) = startClient(
        initial: const Duration(milliseconds: 60),
      );
      await pump(10);
      expect(statuses, contains('open'));

      client.stop();
      channels.first.serverClose(); // late drop of the abandoned socket
      await pump(200);
      expect(
        channels,
        hasLength(1),
        reason:
            'a drop on a channel the client already stopped must never '
            'schedule a reconnect',
      );
      expect(
        statuses.where((s) => s == 'reconnecting'),
        isEmpty,
        reason:
            'a stopped client must not report reconnecting; '
            'statuses=$statuses',
      );
      expect(statuses, contains('stopped'));
    });
  });
}
