import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// Test-adversary suite for unit 009 criterion 2 (degraded-sync contract) —
/// the interleavings around the REST probe that decides `offline` while the
/// WS is down (connection_controller.dart:237-251).
///
/// Contract sources:
///  * unit spec L28-35: "WS death while REST is still reachable =
///    WsPhase.reconnecting with ConnectionPhase.connected … the offline
///    banner stays exactly as unit 001 defined it: driven by the REST probe
///    while the WS is down … This unit changes only *how fast* WS-down is
///    discovered, not who decides offline";
///  * connection_controller.dart state machine (L69-76) — `connected → idle`
///    only via explicit disconnect; `idle` is exited only by `connectTo`;
///  * connection_controller.dart L238: probe "runs once per reconnect
///    attempt"; L238-239: "A failed probe only downgrades a connected state
///    — and never after the WS reopened";
///  * docs/ARCHITECTURE.md § "Error / offline policy (v1)";
///  * docs/API.md § Websocket (subscribe payload).

const _config = ServerConfig(host: 'example.test', port: 3689);

class _Harness {
  _Harness({
    required List<FakeWsChannel?> channels,
    Duration backoffInitial = const Duration(milliseconds: 50),
  }) {
    adapter = ScriptedAdapter();
    script = _Script(channels);
    controller = ConnectionController(
      dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
      wsFactory: (uri, subscriptions, b) => WsClient(
        uri: uri,
        subscriptions: subscriptions,
        backoff: b,
        channelFactory: script.create,
      ),
      backoff: Backoff(initial: backoffInitial),
    );
    controller.addListener(() {
      final p = controller.phase.name;
      if (p != lastPhase) {
        lastPhase = p;
        phases.add(p);
      }
      pairs.add('$p/${controller.wsPhase.name}');
    });
    controller.refetchAll.listen((_) => refetches++);
    controller.events.listen(events.add);
    adapter.responder = _respond;
  }

  late final ScriptedAdapter adapter;
  late final _Script script;
  late final ConnectionController controller;
  final List<String> phases = [];
  final List<String> pairs = [];
  String lastPhase = 'idle';
  final List<List<String>> events = [];
  int refetches = 0;

  /// When non-null, every *probe* `GET /api/config` (all but the first)
  /// waits on it.
  Completer<void>? probeGate;
  bool probeFails = false;

  /// 1-based `GET /api/config` counter; when it equals this value the
  /// responder throws a network error (simulates the server dying between
  /// two connect attempts).
  int failAtConfig = 0;
  int _configSeen = 0;

  FutureOr<Response<dynamic>> _respond(RequestOptions options) async {
    if (options.uri.path == '/api/config') {
      _configSeen++;
      if (_configSeen == failAtConfig) {
        throw networkError(options, const SocketException('server gone'));
      }
      if (_configSeen == 1) {
        return jsonResponse(options, _serverConfigJson());
      }
      final gate = probeGate;
      if (gate != null) await gate.future;
      if (probeFails) {
        throw networkError(options, const SocketException('unreachable'));
      }
      return jsonResponse(options, _serverConfigJson());
    }
    return Response<dynamic>(
      requestOptions: options,
      statusCode: 404,
      data: '<html>not found</html>',
    );
  }

  static Map<String, dynamic> _serverConfigJson() => {
    'version': '29.3',
    'websocket_port': 3688,
  };

  int get configRequests =>
      adapter.requests.where((r) => r == 'GET /api/config').length;

  Future<void> connect() => controller.connectTo(_config);

  Future<bool> waitUntil(bool Function() cond, Duration max) async {
    final deadline = DateTime.now().add(max);
    while (!cond()) {
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return true;
  }

  Future<void> settle([Duration d = const Duration(milliseconds: 80)]) async {
    await Future<void>.delayed(d);
    await pumpEventQueue();
  }

  Future<void> dispose() async => controller.dispose();
}

class _Script {
  _Script(this.planned);
  final List<FakeWsChannel?> planned;
  final List<FakeWsChannel> created = [];

  WebSocketChannel create(Uri _) {
    if (planned.isEmpty) throw StateError('channel script exhausted');
    final channel = planned.removeAt(0)!;
    created.add(channel);
    return channel;
  }
}

FakeWsChannel _failingChannel() => FakeWsChannel()..handshakeFails = true;

void main() {
  group('unit 009 adversary — REST probe vs client lifecycle', () {
    test('a REST probe still in flight when disconnect() runs must not flip '
        'idle back to connected (connection_controller.dart state machine '
        'L69-76: `connected → idle (explicit disconnect)`; idle is exited '
        'only by connectTo — no idle→connected edge exists; unit spec '
        'L32-35: the probe decides offline *while the WS is down* for a live '
        'connection, it is not a phase authority after teardown)', () async {
      final h = _Harness(channels: [FakeWsChannel()]);
      await h.connect();
      await h.settle();
      expect(h.controller.phase, ConnectionPhase.connected);
      expect(h.script.created.single.clientSent, isNotEmpty);

      h.probeGate = Completer<void>();
      h.script.created.single.serverClose();
      expect(
        await h.waitUntil(
          () => h.configRequests == 2,
          const Duration(seconds: 3),
        ),
        isTrue,
        reason:
            'the reconnecting transition must have started the REST '
            'probe (L238)',
      );

      h.controller.disconnect();
      expect(h.controller.phase, ConnectionPhase.idle);

      h.probeGate!.complete(); // probe (REST alive) resolves post-teardown
      await h.settle(const Duration(milliseconds: 300));
      expect(
        h.controller.phase,
        ConnectionPhase.idle,
        reason:
            'the stale probe resolved successfully and the '
            '_wsPhase != open guard passed (wsPhase is "none", not '
            '"open") — so the torn-down client\'s probe resurrected the '
            'phase idle → connected with no connectTo(), a transition the '
            'state machine does not contain',
      );
      await h.dispose();
    });

    test('the same stale-probe race must not resurrect the error phase: a '
        'retry/connectTo whose REST attempt fails stays in error even when an '
        'older WS probe from the previous connection resolves successfully '
        'afterwards (state machine L69-76: `connecting → error` is terminal '
        'until a new connectTo; ARCHITECTURE.md § Error/offline policy: '
        '"REST failure → typed error surfaced" — phase connected with '
        'errorMessage set means the banner disappears and controls enable '
        'against an unreachable server)', () async {
      final h = _Harness(channels: [FakeWsChannel()]);
      await h.connect();
      await h.settle();
      h.probeGate = Completer<void>();
      final staleGate = h.probeGate!;
      h.script.created.single.serverClose();
      await h.waitUntil(
        () => h.configRequests == 2,
        const Duration(seconds: 3),
      );

      h.probeGate = null; // (the stale probe captured its gate already)
      h.failAtConfig = 3; // the retry's own /api/config now fails
      await h.controller.connectTo(_config);
      expect(h.controller.phase, ConnectionPhase.error);

      staleGate.complete(); // stale probe (old REST was alive) resolves
      await h.settle(const Duration(milliseconds: 300));
      expect(
        h.controller.phase,
        ConnectionPhase.error,
        reason:
            'the successful stale probe flipped error → connected via '
            'the unguarded _setPhase(connected) success branch in '
            '_probeServer (connection_controller.dart:244-247)',
      );
      await h.dispose();
    });

    test('a probe that succeeds only AFTER the WS reopened must not change '
        'anything (guard L245: "never after the WS reopened") — phase stays '
        'connected with no duplicate transition', () async {
      final h = _Harness(channels: [FakeWsChannel(), FakeWsChannel()]);
      await h.connect();
      h.probeGate = Completer<void>();
      h.script.created.single.serverClose();
      await h.waitUntil(
        () => h.configRequests == 2,
        const Duration(seconds: 3),
      );
      // Reconnect (backoff 50 ms) → second channel opens.
      expect(
        await h.waitUntil(
          () => h.controller.wsPhase == WsPhase.open,
          const Duration(seconds: 3),
        ),
        isTrue,
        reason: 'the WS must have reopened before releasing the probe',
      );
      h.probeGate!.complete();
      await h.settle(const Duration(milliseconds: 300));
      expect(h.controller.phase, ConnectionPhase.connected);
      expect(
        h.phases,
        ['connecting', 'connected'],
        reason:
            'the late probe success must be a no-op, not a re-emitted '
            'connected transition',
      );
      expect(
        h.pairs,
        [
          'connecting/none',
          'connected/none',
          'connected/open',
          'connected/reconnecting',
          'connected/open',
        ],
        reason:
            'exact notification ledger — the late probe adds no '
            'duplicate (connected/open) emission (guard L245)',
      );
      await h.dispose();
    });

    test(
      'a probe that FAILS only AFTER the WS reopened must not go offline '
      '(guard L249: downgrade requires `_wsPhase != WsPhase.open`) — '
      'flapping network must not show the banner over a healthy WS',
      () async {
        final h = _Harness(channels: [FakeWsChannel(), FakeWsChannel()]);
        await h.connect();
        h.probeGate = Completer<void>();
        h.probeFails = true;
        h.script.created.single.serverClose();
        await h.waitUntil(
          () => h.configRequests == 2,
          const Duration(seconds: 3),
        );
        expect(
          await h.waitUntil(
            () => h.controller.wsPhase == WsPhase.open,
            const Duration(seconds: 3),
          ),
          isTrue,
        );
        h.probeGate!.complete();
        await h.settle(const Duration(milliseconds: 300));
        expect(h.controller.phase, ConnectionPhase.connected);
        expect(h.phases, [
          'connecting',
          'connected',
        ], reason: 'no offline downgrade may land after the WS reopened');
        expect(
          h.pairs,
          [
            'connecting/none',
            'connected/none',
            'connected/open',
            'connected/reconnecting',
            'connected/open',
          ],
          reason:
              'exact notification ledger — the failed probe adds no '
              'offline emission over a healthy WS (guard L249)',
        );
        await h.dispose();
      },
    );
  });

  group('unit 009 adversary — reconnect storm vs status emissions (c2)', () {
    test('storm: WS closes then two failed reconnect attempts before success — '
        'phase never leaves connected (no banner, controls live), one REST '
        'probe per reconnecting emission (L238 "runs once per reconnect '
        'attempt"), refetchAll fires exactly once (the post-reconnect open, '
        'spec L43-44 / ARCHITECTURE.md "on reconnect completes → emits a '
        'RefetchAll event"), events flow again after re-subscribe, and the '
        'subscribe payload matches docs/API.md § Websocket verbatim', () async {
      final h = _Harness(
        channels: [
          FakeWsChannel(),
          _failingChannel(),
          _failingChannel(),
          FakeWsChannel(),
        ],
      );
      await h.connect();
      await h.settle();
      expect(h.controller.phase, ConnectionPhase.connected);
      expect(h.refetches, 0, reason: 'first open must not refetch (L79-80)');
      expect(
        h.script.created.first.clientSent,
        [
          '{"notify":["player","volume","outputs","queue","options",'
              '"database","update"]}',
        ],
        reason: 'docs/API.md L144-147 prescribes exactly this subscribe',
      );

      h.script.created.first.serverClose();
      expect(
        await h.waitUntil(
          () => h.script.created.length == 4,
          const Duration(seconds: 4),
        ),
        isTrue,
        reason: 'the storm must run to the fourth scripted channel',
      );
      expect(
        await h.waitUntil(
          () => h.controller.wsPhase == WsPhase.open,
          const Duration(seconds: 3),
        ),
        isTrue,
      );
      await h.settle(const Duration(milliseconds: 300));

      expect(
        h.phases,
        ['connecting', 'connected'],
        reason:
            'WS failure never blocks REST control (R-02) — no '
            'offline transition with the REST probe alive',
      );
      expect(
        h.pairs,
        [
          'connecting/none',
          'connected/none',
          'connected/open',
          'connected/reconnecting',
          'connected/open',
        ],
        reason:
            'the UI-facing notification ledger stays quiet during the '
            'storm: two failed attempts must not re-emit the same '
            'connected/reconnecting state (dedup guard L278)',
      );
      expect(
        h.configRequests,
        4,
        reason:
            '1 connect + 1 probe per reconnecting emission (close + '
            '2 failed attempts); a doubled schedule would probe 6 times',
      );
      expect(
        h.refetches,
        1,
        reason: 'refetchAll exactly once — on the first *re*open',
      );
      expect(
        h.script.created[3].clientSent,
        isNotEmpty,
        reason: 're-subscribed',
      );

      h.script.created[3].serverSend('{"notify":["queue"]}');
      await h.settle();
      expect(h.events, [
        ['queue'],
      ], reason: 'event forwarding works on the re-subscribed connection');
      await h.dispose();
    });

    test(
      'refetchAll fires exactly once per re-open, never on the first open, '
      'and stop/disconnect during the backoff window suppresses the next '
      'open (and its refetch) entirely (spec L43-44; controller L79-80)',
      () async {
        final h = _Harness(
          channels: [
            FakeWsChannel(),
            FakeWsChannel(),
            FakeWsChannel(),
            FakeWsChannel(),
          ],
          backoffInitial: const Duration(milliseconds: 60),
        );
        await h.connect();
        expect(h.refetches, 0);

        h.script.created[0].serverClose();
        expect(
          await h.waitUntil(
            () => h.script.created.length == 2,
            const Duration(seconds: 3),
          ),
          isTrue,
        );
        await h.settle();
        expect(h.refetches, 1, reason: 'second open → one refetch');

        h.script.created[1].serverClose();
        expect(
          await h.waitUntil(
            () => h.script.created.length == 3,
            const Duration(seconds: 3),
          ),
          isTrue,
        );
        await h.settle();
        expect(h.refetches, 2, reason: 'third open → one more refetch');

        h.script.created[2].serverClose();
        // Disconnect in the same turn — the about-to-arm reconnect timer /
        // stop() guard must keep the client from ever opening a 4th time.
        h.controller.disconnect();
        await h.settle(const Duration(milliseconds: 200));
        expect(
          h.script.created.length,
          3,
          reason: 'no fourth attempt may be created after disconnect',
        );
        expect(h.refetches, 2, reason: 'no phantom refetch after disconnect');
        expect(h.controller.phase, ConnectionPhase.idle);
        await h.dispose();
      },
    );
  });
}
