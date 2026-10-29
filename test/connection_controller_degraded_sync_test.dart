import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// Degraded-sync contract while the WS is down but REST lives (R-02,
/// unit 009 c2): unit 009 changes only *how fast WS-down is discovered* —
/// whoever discovers it, the phase contract must hold:
///
/// * WS `reconnecting` + REST reachable → [ConnectionPhase.connected],
///   controls enabled, no offline banner (R-02 "WS failure never blocks REST
///   control"; banner = UI rendering of [ConnectionPhase.offline], unit 001);
/// * REST also unreachable → the REST probe (not the WS) decides
///   [ConnectionPhase.offline];
/// * recovery → connected + WS open + exactly one full refetch (D2).
///
/// Delta over `connection_controller_test.dart`: the existing suite drives
/// this via a full server restart (REST and WS die together). Here the two
/// failures are **decoupled** — the shape unit 009's ping detection
/// produces (the socket dies on :3688, :3689 stays fine).
void main() {
  const configJson = {
    'library_name': 'Test',
    'websocket_port': 3688,
    'version': '29.3',
    'buildoptions': <String>[],
  };
  const goodConfig = ServerConfig(host: '10.0.0.5', port: 3689);

  Future<void> pump([int ms = 50]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  test('R-02 unit 009 c2: WS reconnecting while REST reachable → phase stays '
      'connected (controls enabled, no offline banner); REST also dead → '
      'offline; recovery → connected + one full refetch', () async {
    var wsDown = false;
    var restDown = false;
    final adapter = ScriptedAdapter(
      responder: (o) {
        if (restDown) {
          throw networkError(
            o,
            socketFailure('Connection refused (ECONNREFUSED)', 111),
          );
        }
        if (o.path == '/api/config') return jsonResponse(o, configJson);
        return jsonResponse(o, <String, dynamic>{});
      },
    );
    final channels = <FakeWsChannel>[];
    final conn = ConnectionController(
      dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
      wsFactory: (uri, subscriptions, backoff) => WsClient(
        uri: uri,
        subscriptions: subscriptions,
        backoff: Backoff(
          initial: const Duration(milliseconds: 10),
          maximum: const Duration(milliseconds: 40),
        ),
        channelFactory: (u) {
          final c = FakeWsChannel();
          channels.add(c);
          if (wsDown) c.handshakeFails = true;
          return c;
        },
      ),
    );
    final refetches = <void>[];
    conn.refetchAll.listen(refetches.add);
    final transitions = <String>[];
    transitions.add('${conn.phase.name}/${conn.wsPhase.name}');
    conn.addListener(
      () => transitions.add('${conn.phase.name}/${conn.wsPhase.name}'),
    );

    await conn.connectTo(goodConfig);
    await pump();
    expect(conn.phase, ConnectionPhase.connected);
    expect(conn.wsPhase, WsPhase.open);

    // The WS goes silently dark (socket dies on :3688); REST stays fine.
    wsDown = true;
    channels.first.serverClose();
    await pump(200); // several backoff cycles (10/20/40/40 ms)

    expect(conn.wsPhase, WsPhase.reconnecting);
    expect(
      conn.phase,
      ConnectionPhase.connected,
      reason:
          'R-02: WS failure never blocks REST control — ${transitions.join(' → ')}',
    );
    expect(conn.isConnected, isTrue);
    expect(
      conn.api,
      isNotNull,
      reason: 'controls stay enabled (the REST client is kept alive)',
    );
    expect(
      transitions.any((s) => s.startsWith('offline/')),
      isFalse,
      reason:
          'no offline banner while REST is reachable — ${transitions.join(' → ')}',
    );
    expect(
      adapter.requests.where((r) => r == 'GET /api/config').length,
      greaterThan(1),
      reason:
          'the REST probe must run on reconnect attempts — the probe, '
          'not the WS, is who decides offline (unit 001 contract).',
    );

    // REST also dies → probe fails → offline (banner). The WS sub-state
    // stays reconnecting.
    restDown = true;
    await pump(200);
    expect(
      conn.phase,
      ConnectionPhase.offline,
      reason:
          'REST unreachable while WS down → offline — '
          '${transitions.join(' → ')}',
    );
    expect(conn.wsPhase, WsPhase.reconnecting);

    // Recovery: full refetch exactly once (not on the first open), WS
    // re-subscribed on the fresh channel.
    wsDown = false;
    restDown = false;
    await pump(300);
    expect(
      conn.phase,
      ConnectionPhase.connected,
      reason: transitions.join(' → '),
    );
    expect(conn.wsPhase, WsPhase.open);
    expect(
      refetches,
      hasLength(1),
      reason: 'full refetch once per reconnect (D2)',
    );
    expect(
      channels.last.clientSent,
      isNotEmpty,
      reason: 'notify re-subscribed',
    );
    conn.dispose();
  });
}
