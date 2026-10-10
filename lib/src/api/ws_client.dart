import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'backoff.dart';

/// OwnTone websocket (R-02): on connect (and after every reconnect) sends the
/// `notify` subscription and re-emits event names as they arrive. Reconnects
/// with exponential backoff. Events are invalidation signals only — the
/// controller refetches.
class WsClient {
  WsClient({
    required Uri uri,
    required List<String> subscriptions,
    Backoff? backoff,
    WebSocketChannel Function(Uri uri)? channelFactory,
  }) : _uri = uri,
       _subscriptions = subscriptions,
       _backoff = backoff ?? Backoff() {
    // web_socket_channel v3's top-level connect() is the (web) adapter and
    // cannot send Maps; on the VM the IO channel is required. The `notify`
    // subprotocol is mandatory: OwnTone's libwebsockets server accepts the
    // handshake without it but silently registers the client as
    // unsubscribed, so no events ever arrive.
    _channelFactory =
        channelFactory ??
        (uri) => IOWebSocketChannel.connect(uri, protocols: ['notify']);
  }

  final Uri _uri;
  final List<String> _subscriptions;
  final Backoff _backoff;
  late final WebSocketChannel Function(Uri uri) _channelFactory;

  final StreamController<List<String>> _events =
      StreamController<List<String>>.broadcast();
  final StreamController<String> _status = StreamController<String>.broadcast();

  /// Event names from the server, e.g. `["player"]`.
  Stream<List<String>> get events => _events.stream;

  /// `disconnected` | `connecting` | `open` | `reconnecting` | `stopped`.
  Stream<String> get status => _status.stream;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  bool _stopped = true;

  bool get isConnected => _sub != null;

  void start() {
    _stopped = false;
    _open();
  }

  void stop() {
    _stopped = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
    _status.add('stopped');
  }

  void _open() {
    if (_stopped) return;
    _status.add('connecting');
    WebSocketChannel channel;
    try {
      channel = _channelFactory(_uri);
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _channel = channel;
    _sub = channel.stream.listen(
      (data) {
        _backoff.reset();
        _handleMessage(data);
      },
      onDone: () => _teardownAndReconnect(),
      onError: (Object _) => _teardownAndReconnect(),
    );
    // OwnTone sends no traffic until an event happens, so "open" must come
    // from the handshake, not from the first data frame. (Re)subscribe once
    // the connection is established — D2. web_socket_channel 3.x sends raw
    // values: JSON-encode by hand.
    unawaited(() async {
      try {
        await channel.ready;
        channel.sink.add(jsonEncode(subscriptionMessage()));
        _backoff.reset();
        _status.add('open');
      } catch (_) {
        // stream onDone/onError will drive the reconnect.
      }
    }());
  }

  void _handleMessage(dynamic data) {
    // Incoming frames arrive as JSON strings in 3.x — decode by hand.
    Object? parsed = data;
    if (data is String) {
      try {
        parsed = jsonDecode(data);
      } on FormatException {
        return;
      }
    }
    if (parsed is! Map) return;
    final notify = parsed['notify'];
    if (notify is! List) return;
    final names = notify.whereType<String>().toList();
    if (names.isNotEmpty) _events.add(names);
  }

  void _teardownAndReconnect() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (_stopped) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    final delay = _backoff.nextDelay();
    _status.add('reconnecting');
    _reconnectTimer = Timer(delay, _open);
  }

  /// The subscription payload sent on connect/reconnect.
  Map<String, dynamic> subscriptionMessage() => {'notify': _subscriptions};
}
