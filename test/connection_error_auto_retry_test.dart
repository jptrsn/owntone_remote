import 'dart:async';
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

/// The injected error-retry cadence (production default stays
/// `kOfflineProbeInterval` = 10 s; tests run at ms scale like
/// `connection_offline_recovery_test.dart`).
const _interval = Duration(milliseconds: 50);

Future<void> pump([int ms = 50]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

int _configCount(ScriptedAdapter adapter) =>
    adapter.requests.where((r) => r.endsWith('/api/config')).length;

Future<void> waitUntil(
  bool Function() condition, {
  int budgetMs = 1500,
  required String reason,
}) async {
  final deadline = DateTime.now().add(Duration(milliseconds: budgetMs));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail(reason);
    await pump(20);
  }
}

/// Controller with the error-retry timer at test speed and a fake WS server.
ConnectionController _controller(
  ScriptedAdapter adapter,
  List<FakeWsChannel> channels,
) => ConnectionController(
  dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
  errorProbeInterval: _interval,
  offlineProbeInterval: _interval,
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
      return c;
    },
  ),
);

/// Issue #93: cold boot while the server is unreachable landed in
/// [ConnectionPhase.error] and stayed there — the `offline` probe timer only
/// exists in `offline`, and no connectivity listener exists, so recovery
/// waited on a Retry tap (host observation 2026-11-26: 60 s on the error
/// screen after wifi came back; `conn.retry()` recovered instantly).
///
/// ACs from the frozen spec (.ai-dlc/night-2026-11-27/issues/93.md):
/// AC-1 typed error entry preserved · AC-2 error keeps re-driving the
/// attempt after a network-y failure · AC-3 server returns ⇒ recovered
/// without a tap · AC-4 offline path intact (existing suite) · AC-5 no UI
/// change (diff-based, see the PR). R-01/R-02 per docs/REQUIREMENTS.md.
void main() {
  group('issue #93 error-phase auto-retry (AC-2, AC-3, R-01)', () {
    test('issue #93 AC-2/AC-3: refused failure lands in error, the timer keeps '
        're-driving connectTo while still down, and the server coming back '
        'reaches connected WITHOUT any retry() call', () async {
      var down = true;
      final adapter = ScriptedAdapter(
        responder: (o) {
          if (o.path == '/api/config') {
            if (down) {
              throw networkError(o, socketFailure('Connection refused', 61));
            }
            return jsonResponse(o, _configJson);
          }
          return jsonResponse(o, <String, dynamic>{});
        },
      );
      final channels = <FakeWsChannel>[];
      final conn = _controller(adapter, channels);
      addTearDown(conn.dispose);

      await conn.connectTo(_goodConfig);
      // AC-1 leg: existing behaviour preserved — typed error entry.
      expect(conn.phase, ConnectionPhase.error);
      expect(conn.errorMessage, contains('refused'));
      final atError = _configCount(adapter);
      expect(atError, 1);

      // AC-2: still unreachable — the timer keeps attempting on its own.
      await pump(160); // ~3× interval
      expect(
        _configCount(adapter),
        greaterThanOrEqualTo(atError + 2),
        reason: 'error phase must keep re-driving the attempt',
      );
      // A tick may be milliseconds from landing when pump returns —
      // wait for the in-flight attempt to settle; with `down` still true
      // it can only land back in error.
      await waitUntil(
        () => conn.phase == ConnectionPhase.error,
        reason: 'must settle back in error while the server stays down',
      );

      // AC-3: server returns — recovery with NO user action (no conn
      // .retry() call anywhere in this test; deleting the timer hangs
      // here until waitUntil fails).
      down = false;
      await waitUntil(
        () => conn.phase == ConnectionPhase.connected,
        reason: 'error must self-recover to connected once reachable',
      );
      expect(conn.wsPhase, WsPhase.open);
      expect(channels, isNotEmpty, reason: 'WS created by the timer retry');
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('issue #93 AC-2: a connectTimeout failure counts as network-y — '
        'error → timer re-attempts → auto connected (the black-holed-network '
        'shape)', () async {
      var down = true;
      final adapter = ScriptedAdapter(
        responder: (o) {
          if (o.path == '/api/config') {
            if (down) {
              throw networkError(
                o,
                'connect timed out',
                type: DioExceptionType.connectionTimeout,
              );
            }
            return jsonResponse(o, _configJson);
          }
          return jsonResponse(o, <String, dynamic>{});
        },
      );
      final channels = <FakeWsChannel>[];
      final conn = _controller(adapter, channels);
      addTearDown(conn.dispose);

      await conn.connectTo(_goodConfig);
      expect(conn.phase, ConnectionPhase.error);
      expect(conn.errorMessage, contains('timed out'));
      final atError = _configCount(adapter);

      await pump(120);
      expect(_configCount(adapter), greaterThan(atError));

      down = false;
      await waitUntil(
        () => conn.phase == ConnectionPhase.connected,
        reason: 'timeout-reason error must auto-recover',
      );
      expect(conn.wsPhase, WsPhase.open);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test(
      'issue #93 AC-2: a DNS failure (SocketException host lookup) counts as '
      'network-y — error → timer re-attempts → auto connected',
      () async {
        var down = true;
        final adapter = ScriptedAdapter(
          responder: (o) {
            if (o.path == '/api/config') {
              if (down) {
                throw networkError(
                  o,
                  SocketException(
                    'Failed host lookup: own-tone.invalid',
                    osError: OSError(
                      'nodename nor servname provided, or not known',
                      8,
                    ),
                  ),
                );
              }
              return jsonResponse(o, _configJson);
            }
            return jsonResponse(o, <String, dynamic>{});
          },
        );
        final channels = <FakeWsChannel>[];
        final conn = _controller(adapter, channels);
        addTearDown(conn.dispose);

        await conn.connectTo(_goodConfig);
        expect(conn.phase, ConnectionPhase.error);
        expect(conn.errorMessage, contains('DNS'));
        final atError = _configCount(adapter);

        await pump(120);
        expect(_configCount(adapter), greaterThan(atError));

        down = false;
        await waitUntil(
          () => conn.phase == ConnectionPhase.connected,
          reason: 'dns-reason error must auto-recover',
        );
        expect(conn.wsPhase, WsPhase.open);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('issue #93 AC-2 (negative): a 401 does NOT arm the retry timer — no '
        'credential hammering, Retry stays the only path', () async {
      final adapter = ScriptedAdapter(
        responder: (o) {
          if (o.path == '/api/config') {
            return Response(
              requestOptions: o,
              statusCode: 401,
              data: <String, dynamic>{'error': 'authentication required'},
            );
          }
          return jsonResponse(o, <String, dynamic>{});
        },
      );
      final channels = <FakeWsChannel>[];
      final conn = _controller(adapter, channels);
      addTearDown(conn.dispose);

      await conn.connectTo(_goodConfig);
      expect(conn.phase, ConnectionPhase.error);
      expect(conn.errorMessage, contains('401'));
      final atError = _configCount(adapter);

      await pump(250); // 5× interval
      expect(
        _configCount(adapter),
        atError,
        reason: 'a wrong-credentials error must not re-attempt',
      );
      expect(conn.phase, ConnectionPhase.error);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test(
      'issue #93 AC-2 (negative): a non-Dio client bug (raw TypeError from a '
      'malformed config payload → generic catch) does NOT spin the loop',
      () async {
        final adapter = ScriptedAdapter(
          responder: (o) {
            if (o.path == '/api/config') {
              // List payload → getConfig's `as Map<String, dynamic>` throws
              // a raw TypeError outside dio's DioException normalization.
              return jsonResponse(o, <String>['not', 'a', 'map']);
            }
            return jsonResponse(o, <String, dynamic>{});
          },
        );
        final channels = <FakeWsChannel>[];
        final conn = _controller(adapter, channels);
        addTearDown(conn.dispose);

        await conn.connectTo(_goodConfig);
        expect(conn.phase, ConnectionPhase.error);
        expect(conn.errorMessage, startsWith('Connection failed:'));
        final atError = _configCount(adapter);

        await pump(250); // 5× interval
        expect(
          _configCount(adapter),
          atError,
          reason: 'client bugs must not drive a 10 s attempt loop',
        );
        expect(conn.phase, ConnectionPhase.error);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('issue #93 AC-2 (lifecycle): disconnect() while the error timer runs '
        'is final — phase idle, no further attempts', () async {
      final adapter = ScriptedAdapter(
        responder: (o) {
          if (o.path == '/api/config') {
            throw networkError(o, socketFailure('Connection refused', 61));
          }
          return jsonResponse(o, <String, dynamic>{});
        },
      );
      final channels = <FakeWsChannel>[];
      final conn = _controller(adapter, channels);
      addTearDown(conn.dispose);

      await conn.connectTo(_goodConfig);
      expect(conn.phase, ConnectionPhase.error);
      final atError = _configCount(adapter);
      await pump(120);
      // Prove the timer was armed before tearing it down (otherwise the
      // post-disconnect assertion below would pass vacuously).
      expect(_configCount(adapter), greaterThan(atError));

      conn.disconnect();
      final atDisconnect = _configCount(adapter);
      await pump(200); // 4× interval
      expect(conn.phase, ConnectionPhase.idle);
      expect(
        _configCount(adapter),
        atDisconnect,
        reason: 'an explicit disconnect is final — timer must stop',
      );
    }, timeout: const Timeout(Duration(seconds: 10)));

    test(
      'issue #93 AC-2 (stop-on-recovery): after the automatic recovery the '
      'timer is cancelled — no probe storm behind a connected phase',
      () async {
        var down = true;
        final adapter = ScriptedAdapter(
          responder: (o) {
            if (o.path == '/api/config') {
              if (down) {
                throw networkError(o, socketFailure('Connection refused', 61));
              }
              return jsonResponse(o, _configJson);
            }
            return jsonResponse(o, <String, dynamic>{});
          },
        );
        final channels = <FakeWsChannel>[];
        final conn = _controller(adapter, channels);
        addTearDown(conn.dispose);

        await conn.connectTo(_goodConfig);
        expect(conn.phase, ConnectionPhase.error);
        down = false;
        await waitUntil(
          () => conn.phase == ConnectionPhase.connected,
          reason: 'must auto-recover first (T1 shape)',
        );

        final atConnected = _configCount(adapter);
        await pump(200); // 4× interval
        expect(
          _configCount(adapter),
          atConnected,
          reason: 'leaving error must cancel the retry timer',
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'issue #93 AC-2 (no overlap): ticks during an in-flight attempt never '
      'start a second connectTo — concurrent /api/config attempts max is 1',
      () async {
        var down = true;
        var gating = true;
        var inFlight = 0;
        var inflightMax = 0;
        final gate = Completer<void>();
        final adapter = ScriptedAdapter(
          responder: (o) async {
            if (o.path == '/api/config') {
              inFlight++;
              if (inFlight > inflightMax) inflightMax = inFlight;
              try {
                if (gating) await gate.future;
                if (down) {
                  throw networkError(
                    o,
                    socketFailure('Connection refused', 61),
                  );
                }
                return jsonResponse(o, _configJson);
              } finally {
                inFlight--;
              }
            }
            return jsonResponse(o, <String, dynamic>{});
          },
        );
        final channels = <FakeWsChannel>[];
        final conn = _controller(adapter, channels);
        addTearDown(conn.dispose);

        unawaited(conn.connectTo(_goodConfig));
        // Held mid-flight: pump well past several intervals.
        await pump(300); // 6× interval
        expect(conn.phase, ConnectionPhase.connecting);
        expect(_configCount(adapter), 1);
        expect(inflightMax, 1, reason: 'no second attempt during an attempt');

        // Release → the held attempt fails → error (timer arms) → server up
        // → auto recovery, still never overlapping.
        gating = false;
        gate.complete();
        await waitUntil(
          () => conn.phase == ConnectionPhase.error,
          reason: 'held attempt must land in error',
        );
        down = false;
        await waitUntil(
          () => conn.phase == ConnectionPhase.connected,
          reason: 'must auto-recover after release',
        );
        expect(
          inflightMax,
          1,
          reason: 'timer ticks must never overlap an in-flight attempt',
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });
}
