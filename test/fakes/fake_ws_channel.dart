import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';

/// In-memory stand-in for an OwnTone websocket server. The [serverSend] /
/// [serverClose] / [serverFail] methods play the server side of the
/// connection.
class FakeWsChannel implements WebSocketChannel {
  FakeWsChannel() {
    // Frames the client sends are recorded in [clientSent] only; they must
    // not be echoed back into the client's own stream.
    _sink = _FakeWsSink((_) {});
  }

  final _controller = StreamController<Object?>();
  late final _FakeWsSink _sink;
  bool _handshakeFails = false;

  /// The server is down: the handshake fails, like a real one — [ready]
  /// errors AND the stream emits an error (both, as `IOWebSocketChannel`
  /// does). Set before the client starts listening.
  set handshakeFails(bool v) {
    _handshakeFails = v;
    if (v) {
      // Buffered until the client listens (a pre-listen event on a
      // single-subscription controller is delivered on subscription).
      scheduleMicrotask(() {
        _controller.sink.addError('handshake failed (server down)');
      });
    }
  }

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
  Future<void> get ready async {
    if (_handshakeFails) {
      throw SocketException('handshake failed (server down)');
    }
  }

  /// Frames the client sent, in order.
  List<Object?> get clientSent => _sink.sent;

  /// Server → client frame.
  void serverSend(Object? frame) => _controller.sink.add(frame);

  /// The server dropped the connection.
  void serverClose() => _controller.sink.close();

  /// The handshake / connection failed (server down).
  void serverFail() =>
      _controller.sink.addError('handshake failed (server down)');

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
