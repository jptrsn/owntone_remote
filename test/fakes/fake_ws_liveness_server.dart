import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A hermetic loopback WebSocket peer for exercising the *real*
/// `IOWebSocketChannel` that `WsClient`'s default channel factory builds
/// (R-02 hardening, unit 009).
///
/// `FakeWsChannel` cannot serve this job: liveness detection per the unit
/// spec is `IOWebSocketChannel.connect`'s `pingInterval`, i.e. pings sent by
/// dart:io on a real socket — frames that never reach a Dart-level channel
/// fake. And dart:io's own server-side `WebSocket` answers pings internally
/// and never surfaces them, so the app-level liveness traffic is only
/// observable on the wire. This fake therefore speaks raw RFC 6455 over a
/// `ServerSocket` bound to 127.0.0.1 on an ephemeral port:
///
/// - completes the client's upgrade handshake (correct `Sec-WebSocket-Accept`
///   — the dart:io client validates it, see
///   https://api.dart.dev/stable/3.11.5/dart-io/WebSocket/connect.html);
/// - counts ping frames the client sends (`pingsReceived`) — the only
///   externally visible proof that the default factory configured
///   `pingInterval` (criterion 1a);
/// - answers them with a pong when [autoPong] (healthy idle, c1c), or stays
///   silent when it is false — the middlebox/silent-drop simulation at the
///   app layer: dart:io then fails the socket on the first unanswered ping
///   (see https://api.dart.dev/stable/3.11.5/dart-io/WebSocket/pingInterval.html),
///   which must drive `WsClient` to `reconnecting` (c1a detection).
///
/// Loopback only — never the LAN server; the socket pair lives and dies
/// inside the test process.
class FakeWsLivenessServer {
  FakeWsLivenessServer({this.autoPong = true});

  /// When true, incoming ping frames are answered with a pong (a server that
  /// honours RFC 6455, like OwnTone's libwebsockets). When false the peer
  /// accepts the handshake and then goes "silently dark": it reads frames
  /// (so nothing backpressures the client) but never pongs.
  bool autoPong;

  ServerSocket? _server;
  final List<_Conn> _conns = [];

  Uri? _uri;

  /// The ws:// URI clients should connect to (valid after [start]).
  Uri get uri => _uri!;

  /// Successful upgrade handshakes so far (a second one == a client
  /// reconnect).
  int get handshakes => _conns.length;

  /// Ping frames received from the client, in arrival order.
  List<DateTime> get pingTimes => [for (final c in _conns) ...c.pings];

  int get pingsReceived => pingTimes.length;

  /// Data (text/binary) frames received — e.g. the `notify` subscription.
  int get clientDataFrames =>
      _conns.fold(0, (int sum, _Conn c) => sum + c.dataFrames);

  Future<Uri> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((socket) => _conns.add(_Conn(socket, this)), onError: (_) {});
    return _uri = Uri(
      scheme: 'ws',
      host: '127.0.0.1',
      port: server.port,
      path: '/',
    );
  }

  Future<void> stop() async {
    for (final c in _conns) {
      c.destroy();
    }
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close();
    }
  }
}

class _Conn {
  _Conn(this._socket, this._srv) {
    _socket.listen(
      _onData,
      onError: (Object _) => _closed = true,
      onDone: () => _closed = true,
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final FakeWsLivenessServer _srv;
  final BytesBuilder _buf = BytesBuilder(copy: true);

  bool _upgraded = false;
  bool _closed = false;

  final List<DateTime> pings = [];
  int dataFrames = 0;

  void _onData(Uint8List bytes) {
    if (_closed) return;
    _buf.add(bytes);
    if (!_upgraded) {
      final all = _buf.toBytes();
      final sep = _indexOfHeaderEnd(all);
      if (sep < 0) return; // headers still in flight
      final headers = latin1.decode(all.sublist(0, sep));
      _buf.clear();
      _buf.add(all.sublist(sep + 4));
      final key = _headerValue(headers, 'sec-websocket-key');
      if (key == null) {
        destroy();
        return;
      }
      final response = StringBuffer()
        ..write('HTTP/1.1 101 Switching Protocols\r\n')
        ..write('Upgrade: websocket\r\n')
        ..write('Connection: Upgrade\r\n')
        ..write('Sec-WebSocket-Accept: ${_acceptToken(key)}\r\n');
      final protocol = _headerValue(headers, 'sec-websocket-protocol');
      if (protocol != null && protocol.trim().isNotEmpty) {
        // Echo the first offered subprotocol (the client asks for `notify`
        // and dart:io records what the server selected).
        response.write(
          'Sec-WebSocket-Protocol: ${protocol.split(',').first.trim()}\r\n',
        );
      }
      response.write('\r\n');
      _socket.add(latin1.encode(response.toString()));
      _upgraded = true;
    }
    _parseFrames();
  }

  /// Parse whatever whole frames are buffered (client frames are masked per
  /// RFC 6455; unmasked ones are tolerated too).
  void _parseFrames() {
    while (true) {
      final b = _buf.toBytes();
      if (b.length < 2) return;
      final opcode = b[0] & 0x0F;
      final masked = (b[1] & 0x80) != 0;
      var len = b[1] & 0x7F;
      var off = 2;
      if (len == 126) {
        if (b.length < off + 2) return;
        len = (b[off] << 8) | b[off + 1];
        off += 2;
      } else if (len == 127) {
        if (b.length < off + 8) return;
        var wide = 0;
        for (var i = 0; i < 8; i++) {
          wide = (wide << 8) | b[off + i];
        }
        len = wide;
        off += 8;
      }
      List<int>? mask;
      if (masked) {
        if (b.length < off + 4) return;
        mask = b.sublist(off, off + 4);
        off += 4;
      }
      if (b.length < off + len) return;
      final payload = b.sublist(off, off + len);
      if (mask != null) {
        for (var i = 0; i < payload.length; i++) {
          payload[i] ^= mask[i % 4];
        }
      }
      _buf.clear();
      _buf.add(b.sublist(off + len));

      if (opcode == 0x9) {
        // ping
        pings.add(DateTime.now());
        if (_srv.autoPong && payload.length < 126) {
          // Server→client frames are never masked (RFC 6455 §5.1).
          _socket.add(
            Uint8List.fromList(<int>[0x8A, payload.length, ...payload]),
          );
        }
      } else if (opcode == 0x1 || opcode == 0x2) {
        dataFrames++;
      } else if (opcode == 0x8) {
        // close from the client (WsClient.stop()) — hang up.
        destroy();
        return;
      }
      // Pongs (0xA) from the client are irrelevant here: we never ping.
    }
  }

  void destroy() {
    if (_closed) return;
    _closed = true;
    _socket.destroy();
  }
}

int _indexOfHeaderEnd(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 0x0D &&
        bytes[i + 1] == 0x0A &&
        bytes[i + 2] == 0x0D &&
        bytes[i + 3] == 0x0A) {
      return i;
    }
  }
  return -1;
}

String? _headerValue(String headers, String name) {
  final prefix = '$name:';
  for (final line in headers.split('\r\n')) {
    if (line.toLowerCase().startsWith(prefix)) {
      return line.substring(prefix.length).trim();
    }
  }
  return null;
}

String _acceptToken(String webSocketKey) =>
    base64Encode(_sha1(utf8.encode(webSocketKey + _rfc6455Guid)));

const _rfc6455Guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// --- SHA-1 -----------------------------------------------------------------
// dart:io's client validates `Sec-WebSocket-Accept`, so the peer must be
// able to compute SHA-1; no hashing dependency is declared in this project
// (and one must not be added for a test fake), so the 6455-mandated digest is
// implemented here. Verified against the RFC 3174 test vectors by
// test/fakes' usage: a wrong digest fails the dart:io handshake instantly
// (HandshakeException), which fails the liveness tests loudly.
Uint8List _sha1(List<int> input) {
  final bitLen = input.length * 8;
  final msg = BytesBuilder(copy: false)
    ..add(input)
    ..addByte(0x80);
  while (msg.length % 64 != 56) {
    msg.addByte(0);
  }
  final lenBytes = ByteData(8)..setUint64(0, bitLen);
  msg.add(lenBytes.buffer.asUint8List());
  final bytes = msg.toBytes();
  final words = ByteData.sublistView(bytes);

  var h0 = 0x67452301,
      h1 = 0xEFCDAB89,
      h2 = 0x98BADCFE,
      h3 = 0x10325476,
      h4 = 0xC3D2E1F0;
  final w = List<int>.filled(80, 0);
  for (var chunk = 0; chunk < bytes.length; chunk += 64) {
    for (var j = 0; j < 16; j++) {
      w[j] = words.getUint32(chunk + j * 4);
    }
    for (var j = 16; j < 80; j++) {
      w[j] = _rotl32(w[j - 3] ^ w[j - 8] ^ w[j - 14] ^ w[j - 16], 1);
    }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (var j = 0; j < 80; j++) {
      int f, k;
      if (j < 20) {
        f = (b & c) | (~b & d);
        k = 0x5A827999;
      } else if (j < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (j < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final temp = (_rotl32(a, 5) + f + e + k + w[j]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = _rotl32(b, 30);
      b = a;
      a = temp;
    }
    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
  }

  final out = Uint8List(20);
  final outData = ByteData.sublistView(out);
  for (final (i, h) in <int>[h0, h1, h2, h3, h4].indexed) {
    outData.setUint32(i * 4, h);
  }
  return out;
}

int _rotl32(int v, int n) => ((v << n) & 0xFFFFFFFF) | (v >> (32 - n));
