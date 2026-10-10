import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// In-memory stand-in for an OwnTone websocket server. The [serverSend]
/// method plays the server side of the connection.
class _FakeWsChannel implements WebSocketChannel {
  _FakeWsChannel() {
    // Frames the client sends are recorded in [clientSent] only; they must
    // not be echoed back into the client's own stream.
    _sink = _FakeWsSink((_) {});
  }

  final _controller = StreamController<Object?>();
  late final _FakeWsSink _sink;

  @override
  Stream get stream => _controller.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  String? get protocol => 'notify';

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready async {}

  /// Frames the client sent, in order.
  List<Object?> get clientSent => _sink.sent;

  /// Server → client frame.
  void serverSend(Object? frame) => _controller.sink.add(frame);

  /// The server dropped the connection.
  void serverClose() => _controller.sink.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWsSink implements WebSocketSink {
  _FakeWsSink(this._onAdd);

  final void Function(Object? frame) _onAdd;

  /// Every frame the client sent, in order.
  final List<Object?> sent = [];

  bool closed = false;

  @override
  void add(Object? data) {
    sent.add(data);
    _onAdd(data);
  }

  @override
  Future<void> addStream(Stream stream) async {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future close([int? closeCode, String? closeReason]) async {
    closed = true;
  }

  @override
  Future get done async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('WsClient (R-02)', () {
    test('subscribes after the handshake and re-emits event names', () async {
      final fake = _FakeWsChannel();
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
      final fake = _FakeWsChannel();
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
        final channels = <_FakeWsChannel>[];
        final client = WsClient(
          uri: Uri.parse('ws://x:3688/'),
          subscriptions: ['player'],
          backoff: Backoff(initial: const Duration(milliseconds: 5)),
          channelFactory: (uri) {
            final c = _FakeWsChannel();
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
