import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

const _configJson = {
  'library_name': 'Test',
  'websocket_port': 3688,
  'version': '29.3',
  'buildoptions': <String>[],
};

const _goodConfig = ServerConfig(host: '10.0.0.5', port: 3689);

Future<void> pump([int ms = 50]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// Records `phase/wsPhase` on construction and on every change.
void track(ConnectionController conn, List<String> transitions) {
  transitions.add('${conn.phase.name}/${conn.wsPhase.name}');
  conn.addListener(
    () => transitions.add('${conn.phase.name}/${conn.wsPhase.name}'),
  );
}

/// Builds a controller whose REST goes through [adapter] and whose WS
/// channels come from [channels] (fail fast while [serverDown] is set —
/// like a real server restart drops both REST and WS).
ConnectionController makeController({
  required ScriptedAdapter adapter,
  required List<FakeWsChannel> channels,
  required bool Function() serverDown,
}) {
  return ConnectionController(
    dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
    wsFactory: (uri, subscriptions, backoff) {
      return WsClient(
        uri: uri,
        subscriptions: subscriptions,
        backoff: Backoff(
          initial: const Duration(milliseconds: 5),
          maximum: const Duration(milliseconds: 20),
        ),
        channelFactory: (u) {
          final c = FakeWsChannel();
          channels.add(c);
          if (serverDown()) c.handshakeFails = true;
          return c;
        },
      );
    },
  );
}

void main() {
  group('ConnectionController state machine (R-01, R-02)', () {
    test('R-01: connecting → connected; WS port derived from /api/config; '
        'full subscription sent', () async {
      final adapter = ScriptedAdapter(
        responder: (o) {
          if (o.path == '/api/config') return jsonResponse(o, _configJson);
          return jsonResponse(o, <String, dynamic>{});
        },
      );
      final channels = <FakeWsChannel>[];
      final conn = makeController(
        adapter: adapter,
        channels: channels,
        serverDown: () => false,
      );
      final t = <String>[];
      track(conn, t);

      await conn.connectTo(_goodConfig);

      expect(conn.phase, ConnectionPhase.connected);
      // WS port 3688 comes from /api/config, not from the JSON port.
      expect(conn.wsUri, Uri.parse('ws://10.0.0.5:3688/'));
      expect(conn.serverVersion, '29.3');
      expect(t.first, 'idle/none');

      await pump();
      expect(conn.wsPhase, WsPhase.open);
      expect(channels, hasLength(1));
      expect(
        channels.single.clientSent.single,
        '{"notify":["player","volume","outputs","queue","options","database","update"]}',
      );
      conn.dispose();
    });

    test(
      'R-01: DNS failure → error phase with a DNS-specific message',
      () async {
        // On this SDK a DNS failure is a SocketException("Failed host
        // lookup: …", errno 8) — verified against the VM.
        final adapter = ScriptedAdapter(
          responder: (o) => throw networkError(
            o,
            SocketException(
              "Failed host lookup: 'nope.invalid'",
              osError: const OSError('nodename nor servname provided', 8),
            ),
          ),
        );
        final conn = makeController(
          adapter: adapter,
          channels: [],
          serverDown: () => false,
        );

        await conn.connectTo(
          const ServerConfig(host: 'nope.invalid', port: 3689),
        );

        expect(conn.phase, ConnectionPhase.error);
        expect(conn.errorMessage, isNotNull);
        expect(conn.errorMessage!.toLowerCase(), contains('resolve'));
        expect(conn.errorMessage, contains('nope.invalid'));
        expect(conn.api, isNull);
        conn.dispose();
      },
    );

    test(
      'R-01: refused connection → error phase with a refused message',
      () async {
        final adapter = ScriptedAdapter(
          responder: (o) => throw networkError(
            o,
            socketFailure('Connection refused (ECONNREFUSED)', 111),
          ),
        );
        final conn = makeController(
          adapter: adapter,
          channels: [],
          serverDown: () => false,
        );

        await conn.connectTo(_goodConfig);

        expect(conn.phase, ConnectionPhase.error);
        expect(conn.errorMessage, contains('refused'));
        conn.dispose();
      },
    );

    test('R-01: HTTP 401 → error phase naming 401', () async {
      // Body must be valid JSON: dio 5.11 runs the JSON transformer over
      // non-2xx bodies too, and a FormatException would mask the 401.
      final adapter = ScriptedAdapter(
        responder: (o) => Response(
          requestOptions: o,
          statusCode: 401,
          data: <String, dynamic>{'error': 'authentication required'},
        ),
      );
      final conn = makeController(
        adapter: adapter,
        channels: [],
        serverDown: () => false,
      );

      await conn.connectTo(_goodConfig);

      expect(conn.phase, ConnectionPhase.error);
      expect(conn.errorMessage, contains('401'));
      conn.dispose();
    });

    test('R-01/R-02: websocket_port 0 → connected, REST-only mode, no WS '
        'attempted', () async {
      final adapter = ScriptedAdapter(
        responder: (o) {
          if (o.path == '/api/config') {
            return jsonResponse(o, {..._configJson, 'websocket_port': 0});
          }
          return jsonResponse(o, <String, dynamic>{});
        },
      );
      final channels = <FakeWsChannel>[];
      final conn = makeController(
        adapter: adapter,
        channels: channels,
        serverDown: () => false,
      );

      await conn.connectTo(_goodConfig);
      await pump();

      expect(conn.phase, ConnectionPhase.connected);
      expect(conn.wsPhase, WsPhase.disabled);
      expect(conn.isWsDisabled, isTrue);
      expect(channels, isEmpty);
      conn.dispose();
    });

    test(
      'R-02: server restart → offline while down, backoff reconnect, '
      'refetchAll exactly once on reopen, resubscribed on the fresh channel',
      () async {
        var serverDown = false;
        final adapter = ScriptedAdapter(
          responder: (o) {
            if (serverDown) {
              throw networkError(
                o,
                socketFailure('Connection refused (ECONNREFUSED)', 111),
              );
            }
            if (o.path == '/api/config') return jsonResponse(o, _configJson);
            return jsonResponse(o, <String, dynamic>{});
          },
        );
        final channels = <FakeWsChannel>[];
        final conn = makeController(
          adapter: adapter,
          channels: channels,
          serverDown: () => serverDown,
        );
        final refetches = <void>[];
        conn.refetchAll.listen(refetches.add);
        final t = <String>[];
        track(conn, t);

        await conn.connectTo(_goodConfig);
        await pump();
        expect(conn.wsPhase, WsPhase.open);
        expect(conn.phase, ConnectionPhase.connected);
        expect(refetches, isEmpty); // first open is not a reconnect

        // The server restarts: WS drops and REST goes down.
        serverDown = true;
        channels.first.serverClose();
        await pump(30);
        expect(conn.phase, ConnectionPhase.offline, reason: t.join(' → '));
        expect(t.any((s) => s.startsWith('offline/')), isTrue);

        // The server comes back: a probe flips us to connected, the WS
        // reopens, and the full refetch fires exactly once.
        serverDown = false;
        await pump(400);
        expect(conn.phase, ConnectionPhase.connected, reason: t.join(' → '));
        expect(conn.wsPhase, WsPhase.open);
        expect(channels.length, greaterThan(1));
        expect(refetches, hasLength(1));
        expect(channels.last.clientSent, isNotEmpty); // resubscribed
        conn.dispose();
      },
    );

    test('R-02: WS events pass through to the events stream', () async {
      final adapter = ScriptedAdapter(
        responder: (o) {
          if (o.path == '/api/config') return jsonResponse(o, _configJson);
          return jsonResponse(o, <String, dynamic>{});
        },
      );
      final channels = <FakeWsChannel>[];
      final conn = makeController(
        adapter: adapter,
        channels: channels,
        serverDown: () => false,
      );

      await conn.connectTo(_goodConfig);
      await pump();

      final events = <List<String>>[];
      conn.events.listen(events.add);
      channels.single.serverSend('{"notify":["volume"]}');
      await pump();
      expect(events, [
        ['volume'],
      ]);
      conn.dispose();
    });

    test('disconnect → idle; api dropped', () async {
      final adapter = ScriptedAdapter(
        responder: (o) {
          if (o.path == '/api/config') return jsonResponse(o, _configJson);
          return jsonResponse(o, <String, dynamic>{});
        },
      );
      final channels = <FakeWsChannel>[];
      final conn = makeController(
        adapter: adapter,
        channels: channels,
        serverDown: () => false,
      );

      await conn.connectTo(_goodConfig);
      expect(conn.api, isNotNull);
      conn.disconnect();
      expect(conn.phase, ConnectionPhase.idle);
      expect(conn.api, isNull);
      expect(conn.wsPhase, WsPhase.none);
      conn.dispose();
    });

    test(
      'retry after error → connected once the server is reachable',
      () async {
        var down = true;
        final adapter = ScriptedAdapter(
          responder: (o) {
            if (down) {
              throw networkError(
                o,
                socketFailure('Connection refused (ECONNREFUSED)', 111),
              );
            }
            if (o.path == '/api/config') return jsonResponse(o, _configJson);
            return jsonResponse(o, <String, dynamic>{});
          },
        );
        final conn = makeController(
          adapter: adapter,
          channels: [],
          serverDown: () => down,
        );

        await conn.connectTo(_goodConfig);
        expect(conn.phase, ConnectionPhase.error);

        down = false;
        await conn.retry();
        expect(conn.phase, ConnectionPhase.connected);
        conn.dispose();
      },
    );
  });
}
