import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';
import 'fakes/fake_ws_liveness_server.dart';

const _configJson = {
  'library_name': 'Test',
  'websocket_port': 3688,
  'version': '29.3',
  'buildoptions': <String>[],
};

const _goodConfig = ServerConfig(host: '10.0.0.5', port: 3689);

Future<void> pump([int ms = 50]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

/// User-reported bug (2026-11-17): app backgrounded during a server-idle
/// window, device entered deep Doze (per-uid firewall black-holes the app's
/// packets), then reopen → banner stuck at "Server unreachable — retrying"
/// forever while the server is in fact reachable (`curl /api/config` fine).
///
/// Two independent wedges, both about unbounded waits on the WS path:
///
///  1. [WsClient._open] built `IOWebSocketChannel.connect` without
///     `connectTimeout` — the package documents (lib/io.dart:31-32) that a
///     null timeout means "the connection process will never time-out". A
///     black-holed handshake (Doze firewall drops SYNs — no RST) leaves the
///     channel silent forever: no `ready`, no `onDone`/`onError`, and NO
///     reconnect timer was ever scheduled, so the chain stops dead.
///  2. While [ConnectionPhase.offline] the *only* path back to
///     [ConnectionPhase.connected] was the WS status stream ('open', or
///     'reconnecting' → REST probe). Once (1) wedges that stream, nothing
///     ever re-probes REST and the offline banner never clears — the UI
///     says "retrying" while nothing retries.
///
/// R-01: the offline banner must reflect reachability — a reachable server
/// clears it. R-02: WS failure never blocks REST control.
void main() {
  group('offline recovery after a wedged WS handshake (R-01, R-02)', () {
    test('R-01: server reachable again after Doze blackout must clear offline '
        'even while the WS handshake hangs forever', () async {
      var serverDown = false;
      var hangHandshakes = false;
      final adapter = ScriptedAdapter(
        responder: (o) {
          if (o.path == '/api/config') {
            if (serverDown) {
              throw networkError(o, 'connection refused');
            }
            return jsonResponse(o, _configJson);
          }
          return jsonResponse(o, <String, dynamic>{});
        },
      );
      final channels = <FakeWsChannel>[];
      final conn = ConnectionController(
        dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
        // The controller-side safety net (fix 2) is injected at test speed.
        offlineProbeInterval: const Duration(milliseconds: 50),
        wsFactory: (uri, subscriptions, backoff) => WsClient(
          uri: uri,
          subscriptions: subscriptions,
          backoff: Backoff(
            initial: const Duration(milliseconds: 5),
            maximum: const Duration(milliseconds: 20),
          ),
          channelFactory: (u) {
            final c = FakeWsChannel();
            channels.add(c);
            if (serverDown) {
              c.handshakeFails = true;
            } else if (hangHandshakes) {
              c.handshakeHangs = true;
            }
            return c;
          },
        ),
      );
      addTearDown(conn.dispose);

      // 1. Connect while everything is up.
      await conn.connectTo(_goodConfig);
      await pump();
      expect(conn.phase, ConnectionPhase.connected);
      expect(conn.wsPhase, WsPhase.open);

      // 2. Full blackout: the live WS drops and both REST and WS fail —
      // like the Doze firewall dropping the app uid's packets.
      serverDown = true;
      channels.first.serverClose();
      await pump(300);
      expect(
        conn.phase,
        ConnectionPhase.offline,
        reason: 'REST unreachable while WS down must show the banner',
      );

      // 3. Server comes back for REST — but a WS handshake in flight (or
      // the next one) is black-holed: hangs forever, no error, no done.
      serverDown = false;
      hangHandshakes = true;
      final configReqsBefore = adapter.requests
          .where((r) => r.endsWith('/api/config'))
          .length;

      // Pre-fix this never happens: the ws chain died on the hanging
      // handshake (no reconnect timer scheduled) and offline probes rode
      // only on WS status events.
      await expectLater(() async {
        while (conn.phase != ConnectionPhase.connected) {
          await pump(20);
          if (adapter.requests.where((r) => r.endsWith('/api/config')).length >
              configReqsBefore + 40) {
            fail('probe loop is running but phase never recovered');
          }
        }
      }(), completes);
      // R-02: REST controls are live again even though the WS is still
      // stuck mid-handshake — the banner must not gate REST.
      expect(conn.wsPhase, isNot(WsPhase.open));
      expect(conn.isConnected, isTrue);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('WsClient handshake has a bounded attempt (R-02)', () {
    test('R-02: a peer that accepts TCP but never answers the WS upgrade '
        '(black-holed handshake) must NOT wedge the reconnect chain — the '
        'default channel factory bounds the handshake (connectTimeout) so '
        'the client re-attempts instead of sitting in _open forever', () async {
      final server = FakeWsLivenessServer()..holdHandshake = true;
      final uri = await server.start();
      addTearDown(server.stop);

      final client = WsClient(
        uri: uri,
        subscriptions: const ['player'],
        backoff: Backoff(
          initial: const Duration(milliseconds: 10),
          maximum: const Duration(milliseconds: 50),
        ),
        // Injected timeout models the production bound at test speed.
        connectTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(client.stop);
      final statuses = <String>[];
      client.status.listen(statuses.add);

      client.start();

      // The handshake hangs; the bounded attempt must surface 'reconnecting'
      // (pre-fix: the client sits in _open — 'connecting' forever, no
      // reconnect timer, the chain is dead — this await never completes).
      await expectLater(() async {
        while (!statuses.contains('reconnecting')) {
          await pump(20);
        }
      }(), completes);

      // And it keeps trying: a second upgrade request reaches the peer.
      final first = server.acceptTimes.length;
      expect(first, greaterThanOrEqualTo(1));
      await expectLater(() async {
        while (server.acceptTimes.length <= first) {
          await pump(20);
        }
      }(), completes);
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
