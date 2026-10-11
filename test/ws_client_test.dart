import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'fakes/fake_ws_channel.dart';

void main() {
  group('WsClient (R-02)', () {
    test('subscribes after the handshake and re-emits event names', () async {
      final fake = FakeWsChannel();
      final client = WsClient(
        uri: Uri.parse('ws://x:3688/'),
        subscriptions: ['player', 'volume'],
        channelFactory: (uri) => fake,
      );
      final statuses = <String>[];
      client.status.listen(statuses.add);

      client.start();
      await Future<void>.delayed(Duration.zero);

      expect(statuses, contains('open'));
      expect(fake.clientSent, hasLength(1));
      expect(fake.clientSent.single, '{"notify":["player","volume"]}');

      fake.serverSend('{"notify":["player"]}');
      final events = await client.events.first;
      expect(events, ['player']);
    });

    test('ignores malformed and non-notify frames', () async {
      final fake = FakeWsChannel();
      final client = WsClient(
        uri: Uri.parse('ws://x:3688/'),
        subscriptions: ['player'],
        channelFactory: (uri) => fake,
      );
      final received = <List<String>>[];
      client.events.listen(received.add);

      client.start();
      await Future<void>.delayed(Duration.zero);
      fake.serverSend('not json');
      fake.serverSend('{"unrelated": true}');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(received, isEmpty);
    });

    test(
      'reconnects with backoff after the server drops the connection',
      () async {
        final channels = <FakeWsChannel>[];
        final client = WsClient(
          uri: Uri.parse('ws://x:3688/'),
          subscriptions: ['player'],
          backoff: Backoff(initial: const Duration(milliseconds: 5)),
          channelFactory: (uri) {
            final c = FakeWsChannel();
            channels.add(c);
            return c;
          },
        );
        final statuses = <String>[];
        client.status.listen(statuses.add);

        client.start();
        await Future<void>.delayed(Duration.zero);
        expect(channels, hasLength(1));

        channels.first.serverClose();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(statuses, contains('reconnecting'));
        expect(channels, hasLength(2));
        // Re-subscribed on the fresh connection.
        expect(channels[1].clientSent, isNotEmpty);
      },
    );
  });
}
