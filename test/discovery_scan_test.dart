/// Widget tests for the R-20 scan (issue #42) as the PRIMARY connection
/// flow (issue #62), against a FAKE [DiscoverySource] — no network, no mDNS
/// sockets. The R-01 leg is driven through the real [ConnectionController]
/// with the repo's [ScriptedAdapter] (websocket_port 0 → no WS, no wire), so
/// "tap pre-fills and connects through the existing flow" is asserted on the
/// actual connect path, not a stub.
///
/// R-20: the scan lists hits (name + host + port); a tap pre-fills the
/// config fields and goes through the existing R-01 connect flow; scan
/// failure / timeout show the error state with manual entry still available.
///
/// Issue #62 (prominence): the unconfigured screen scans by itself, so its
/// panel is the first thing presented; the manual host/port form is absent
/// until the **Advanced** tile is tapped, and that tile is reachable in every
/// scan state — including while a scan runs and after it times out or fails.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/discovery/discovered_server.dart';
import 'package:owntone_remote/src/discovery/discovery_source.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:owntone_remote/src/settings/theme_preference.dart';
import 'package:owntone_remote/src/ui/settings_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';

class FakeDiscovery implements DiscoverySource {
  FakeDiscovery(this.behaviour);

  final Future<List<DiscoveredServer>> Function() behaviour;
  int calls = 0;
  int cancels = 0;

  @override
  Future<List<DiscoveredServer>> discover() {
    calls++;
    return behaviour();
  }

  @override
  void cancel() => cancels++;
}

const hit1 = DiscoveredServer(
  name: 'My Music on hp-server',
  host: '192.168.1.13',
  port: 3689,
);
const hit2 = DiscoveredServer(
  name: 'spare-room',
  host: '192.168.1.90',
  port: 3689,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Controller whose only "server" is the scripted `/api/config` — the
  /// R-01 path runs for real without a wire. `websocket_port: 0` keeps the
  /// WsClient out of the picture (R-02 REST-only mode). [responder] replaces
  /// the script (issue #62 AC5: a wrong host must surface the TYPED
  /// ConnectionController error through the same path).
  ConnectionController scriptedConn({
    FutureOr<Response<dynamic>> Function(RequestOptions options)? responder,
  }) => ConnectionController(
    dioFactory: (options) => Dio(options)
      ..httpClientAdapter = ScriptedAdapter(
        responder:
            responder ??
            (o) async => o.uri.path == '/api/config'
                ? Response(
                    requestOptions: o,
                    data: const {
                      'version': '29.3',
                      'websocket_port': 0,
                      'library_name': 'My Music on hp-server',
                    },
                  )
                : Response(requestOptions: o, data: null, statusCode: 404),
      ),
  );

  late List<ConnectionController> opened;
  setUp(() => opened = []);
  tearDown(() {
    for (final c in opened) {
      c.dispose();
    }
  });

  Future<(SettingsStore, ConnectionController)> pumpScreen(
    WidgetTester tester,
    DiscoverySource discovery, {
    Object tag = 1,
    ServerConfig? initial,
    FutureOr<Response<dynamic>> Function(RequestOptions options)? responder,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.create();
    final conn = scriptedConn(responder: responder);
    opened.add(conn);
    // Tall viewport: the scan panel and an EXPANDED Advanced tile have to be
    // on screen together (several tests edit the manual fields while a scan
    // is in flight), and scrolling is animated while a spinner is running —
    // so taps here are un-scrolled and never settle. The 360-px viewport
    // rule has its own test at the end of the R-20 group.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SettingsStore>.value(value: store),
          ChangeNotifierProvider<ThemePreference>.value(
            value: ThemePreference(store),
          ),
          ChangeNotifierProvider<ConnectionController>.value(value: conn),
        ],
        child: MaterialApp(
          home: SettingsScreen(
            key: ValueKey(tag),
            initial: initial,
            discovery: discovery,
          ),
        ),
      ),
    );
    await tester.pump();
    return (store, conn);
  }

  // The label text is unique per field; the EditableText under it is the
  // editable surface (TextFormField exposes no decoration getter in 3.47).
  Finder editable(String label) => find.descendant(
    of: find.ancestor(
      of: find.text(label),
      matching: find.byType(TextFormField),
    ),
    matching: find.byType(EditableText),
  );

  String fieldText(WidgetTester tester, String label) =>
      tester.widget<EditableText>(editable(label)).controller.text;

  /// Tap by key without settling: `pumpAndSettle` hangs while the scan
  /// spinner animates, and the tall viewport in [pumpScreen] removes the
  /// need to scroll. [advance] moves an expansion animation on.
  Future<void> tapKey(
    WidgetTester tester,
    String key, {
    Duration advance = Duration.zero,
  }) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
    if (advance > Duration.zero) await tester.pump(advance);
  }

  /// Reveal the manual host/port form by tapping the Advanced tile, then run
  /// the expansion animation (300 ms) so the fields are laid out.
  Future<void> openAdvanced(WidgetTester tester) => tapKey(
    tester,
    'advanced-tile',
    advance: const Duration(milliseconds: 400),
  );

  /// Enter an address and connect through the Advanced form (issue #62: the
  /// only manual path, still the exact R-01 `_saveAndConnect`).
  Future<void> connectManually(
    WidgetTester tester,
    String host,
    String port,
  ) async {
    await openAdvanced(tester);
    await tester.enterText(editable('Host'), host);
    await tester.enterText(editable('JSON port'), port);
    await tester.pump();
    await tapKey(tester, 'manual-connect');
  }

  group('Issue #62 — auto-discovery is the primary flow', () {
    testWidgets('first display presents the scan, not the manual form: no '
        'tap needed, the loading panel on the very first frame, and the '
        'host/port fields absent', (tester) async {
      final gate = Completer<List<DiscoveredServer>>();
      final discovery = FakeDiscovery(() => gate.future);
      await pumpScreen(tester, discovery);

      expect(
        discovery.calls,
        1,
        reason: 'the screen started the scan by itself (primary flow)',
      );
      expect(
        find.text('Searching the local network…'),
        findsOneWidget,
        reason: 'the scan panel is the first thing presented',
      );
      // Manual entry is hidden behind the explicit affordance…
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('Host'), findsNothing);
      expect(find.text('JSON port'), findsNothing);
      expect(find.byKey(const ValueKey('manual-connect')), findsNothing);
      // …which is itself present even while the scan runs…
      expect(find.byKey(const ValueKey('advanced-tile')), findsOneWidget);
      // …and BELOW the scan panel: the scan leads the screen.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('scan-panel'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('advanced-tile'))).dy,
        ),
      );

      gate.complete(const []);
      await tester.pump();
    });

    testWidgets('tapping Advanced reveals the host/port fields and Connect', (
      tester,
    ) async {
      final discovery = FakeDiscovery(() async => const [hit1]);
      await pumpScreen(tester, discovery);
      await tester.pump();

      await openAdvanced(tester);
      expect(find.text('Host'), findsOneWidget);
      expect(find.text('JSON port'), findsOneWidget);
      expect(find.byKey(const ValueKey('manual-connect')), findsOneWidget);
    });

    testWidgets('a scan FAILURE still exposes the Advanced affordance — and '
        'the revealed form connects end-to-end (never stranded)', (
      tester,
    ) async {
      final (store, conn) = await pumpScreen(
        tester,
        FakeDiscovery(
          () async => throw const DiscoveryException(
            'Could not start the network scan.',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('scan-error')), findsOneWidget);
      expect(
        find.textContaining('Could not start the network scan.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('advanced-tile')),
        findsOneWidget,
        reason: 'a failed scan must never strand the user',
      );
      expect(find.byType(TextFormField), findsNothing);

      await connectManually(tester, '192.168.5.9', '3689');
      await tester.pumpAndSettle();
      expect(store.config, const ServerConfig(host: '192.168.5.9', port: 3689));
      expect(conn.phase, ConnectionPhase.connected);
    });

    testWidgets('a configured Settings visit does not scan by itself — no '
        'multicast traffic for a rocker-step/theme visit', (tester) async {
      final discovery = FakeDiscovery(() async => const [hit1]);
      await pumpScreen(
        tester,
        discovery,
        initial: const ServerConfig(host: 'h', port: 3689),
      );

      expect(discovery.calls, 0);
      expect(find.byKey(const ValueKey('scan-panel')), findsNothing);
      // The affordance is still there for the user to take.
      expect(find.byKey(const ValueKey('server-scan-button')), findsOneWidget);
      expect(find.text('Scan for servers'), findsOneWidget);
    });
  });

  // Issue #62 AC5: R-01 preserved behind Advanced, now pinned by widget
  // tests (on develop these legs were only ever checked by hand, and the
  // round-1/2 reviews measured them with throwaway probes — this group
  // makes them permanent).
  group('R-01 behind Advanced (issue #62 AC5)', () {
    testWidgets('validators fire from inside Advanced and nothing persists '
        'or connects: empty host → Required, non-numeric port → Enter a '
        'number, out-of-range → 1–65535', (tester) async {
      final (store, conn) = await pumpScreen(
        tester,
        FakeDiscovery(() async => const []),
      );
      await tester.pumpAndSettle();

      await connectManually(tester, '', '3689');
      await tester.pump();
      expect(find.text('Required'), findsOneWidget);
      expect(find.text('Enter a number'), findsNothing);
      expect(store.config, isNull);
      expect(conn.phase, ConnectionPhase.idle);

      await tester.enterText(editable('Host'), 'h');
      await tester.enterText(editable('JSON port'), 'x');
      await tester.pump();
      await tapKey(tester, 'manual-connect');
      await tester.pump();
      expect(find.text('Required'), findsNothing);
      expect(find.text('Enter a number'), findsOneWidget);
      expect(store.config, isNull);
      expect(conn.phase, ConnectionPhase.idle);

      // The out-of-range leg surfaces the `1–65535` validator through the
      // Form.validate() path (empty host → _parsed() null → every field
      // validates) — byte-identical R-01 behaviour on develop, which the
      // round-1/2 reviews measured the same way. Pre-existing quirk, out of
      // this issue's scope (non-goals: no _saveAndConnect change):
      // _parsed() does not range-check, so a *complete* form with an
      // out-of-range port would still connect — same on develop, not
      // weakened here.
      await tester.enterText(editable('Host'), '');
      await tester.enterText(editable('JSON port'), '70000');
      await tester.pump();
      await tapKey(tester, 'manual-connect');
      await tester.pump();
      expect(find.text('Required'), findsOneWidget);
      expect(find.text('1–65535'), findsOneWidget);
      expect(store.config, isNull);
      expect(conn.phase, ConnectionPhase.idle);
    });

    testWidgets('a wrong host surfaces the specific DNS error through the '
        'existing ConnectionController error surface (not a generic one)', (
      tester,
    ) async {
      final (_, conn) = await pumpScreen(
        tester,
        FakeDiscovery(() async => const []),
        responder: (o) => throw networkError(
          o,
          // The shape the VM produces for a failed host lookup (see
          // connection_error.dart and connection_controller_test.dart).
          const SocketException('Failed host lookup: ghost'),
        ),
      );
      await tester.pumpAndSettle();

      await connectManually(tester, 'ghost', '3689');
      await tester.pumpAndSettle();

      expect(conn.phase, ConnectionPhase.error);
      expect(
        conn.errorMessage,
        contains('could not be resolved (DNS)'),
        reason: 'the typed DNS error, not a generic connection failure',
      );
    });
  });

  group('R-20 scan (issue #42 behaviour, preserved)', () {
    testWidgets('the auto-started scan lists the fake hits with name + '
        'host:port', (tester) async {
      final discovery = FakeDiscovery(() async => const [hit1, hit2]);
      await pumpScreen(tester, discovery);
      await tester.pump();

      expect(find.text('My Music on hp-server'), findsOneWidget);
      expect(find.text('192.168.1.13:3689'), findsOneWidget);
      expect(find.text('spare-room'), findsOneWidget);
      expect(find.text('192.168.1.90:3689'), findsOneWidget);
      expect(discovery.calls, 1);
    });

    testWidgets('tap on a hit pre-fills host/port and goes through the '
        'R-01 connect flow (persist + connectTo — no bypass)', (tester) async {
      final discovery = FakeDiscovery(() async => const [hit1, hit2]);
      final (store, conn) = await pumpScreen(tester, discovery);
      await tester.pump();

      await tapKey(tester, 'scan-hit-0');
      // The hand-off is the existing _saveAndConnect: persist + connectTo
      // on the scripted controller — settle to let both land.
      await tester.pumpAndSettle();

      expect(
        store.config,
        const ServerConfig(host: '192.168.1.13', port: 3689),
        reason: 'R-01 save() ran for the hit config',
      );
      expect(
        conn.phase,
        ConnectionPhase.connected,
        reason: 'R-01 connectTo ran (and passed) on the hit config',
      );
      // The pre-fill landed in the manual fields (R-20: a hit rides on the
      // manual form), which the Advanced tile reveals.
      await openAdvanced(tester);
      expect(fieldText(tester, 'Host'), '192.168.1.13');
      expect(fieldText(tester, 'JSON port'), '3689');
    });

    testWidgets('manual entry stays usable DURING a scan: the Advanced form '
        'opens and is editable while the panel is in its loading state', (
      tester,
    ) async {
      final gate = Completer<List<DiscoveredServer>>();
      final discovery = FakeDiscovery(() => gate.future);
      await pumpScreen(tester, discovery);

      expect(find.text('Searching the local network…'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const ValueKey('server-scan-button')),
            )
            .onPressed,
        isNull,
        reason: 'no double-scan while one is in flight',
      );

      await openAdvanced(tester);
      // enterText on a disabled field would throw — succeeding IS the
      // assertion that the scan does not block manual entry.
      await tester.enterText(editable('Host'), 'manual.example');
      await tester.enterText(editable('JSON port'), '3689');
      await tester.pump();
      expect(fieldText(tester, 'Host'), 'manual.example');

      gate.complete(const []);
      await tester.pump();
    });

    testWidgets('scan TIMEOUT → timeout error state; manual entry still '
        'works (panel resolves within kScanTimeout even if the source '
        'hangs)', (tester) async {
      final (store, conn) = await pumpScreen(
        tester,
        FakeDiscovery(() => Completer<List<DiscoveredServer>>().future),
      );
      expect(find.text('Searching the local network…'), findsOneWidget);

      await tester.pump(kScanTimeout + const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('scan-error')), findsOneWidget);
      expect(find.textContaining('Scan timed out'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('advanced-tile')),
        findsOneWidget,
        reason: 'a hung scan must never strand the user',
      );

      await connectManually(tester, '192.168.5.10', '3689');
      await tester.pumpAndSettle();
      expect(
        store.config,
        const ServerConfig(host: '192.168.5.10', port: 3689),
      );
      expect(conn.phase, ConnectionPhase.connected);
    });

    testWidgets('empty scan → not-found state; retry re-runs the source '
        'and then lists hits', (tester) async {
      late final FakeDiscovery discovery;
      discovery = FakeDiscovery(
        () async => discovery.calls == 1 ? const [] : const [hit1],
      );
      await pumpScreen(tester, discovery);
      await tester.pump();

      expect(find.byKey(const ValueKey('scan-empty')), findsOneWidget);
      expect(find.textContaining('No OwnTone server found'), findsOneWidget);

      await tapKey(tester, 'scan-retry');
      await tester.pump();
      expect(discovery.calls, 2);
      expect(find.text('My Music on hp-server'), findsOneWidget);
    });

    testWidgets('the leading Scan button re-runs a completed scan', (
      tester,
    ) async {
      late final FakeDiscovery discovery;
      discovery = FakeDiscovery(
        () async => discovery.calls == 1 ? const [] : const [hit1, hit2],
      );
      await pumpScreen(tester, discovery);
      await tester.pump();
      expect(find.byKey(const ValueKey('scan-empty')), findsOneWidget);
      expect(find.text('Scan for servers'), findsOneWidget);

      await tapKey(tester, 'server-scan-button');
      await tester.pump();
      expect(discovery.calls, 2);
      expect(find.text('My Music on hp-server'), findsOneWidget);
      expect(find.text('spare-room'), findsOneWidget);
    });

    testWidgets('scan panel + expanded Advanced tile render at 360 logical '
        'px with no overflow (unit 004 viewport rule)', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final discovery = FakeDiscovery(() async => const [hit1, hit2]);
      await pumpScreen(tester, discovery);
      await tester.pump();
      await openAdvanced(tester);
      // RenderFlex overflow throws in the test binding — reaching here is
      // the assertion.
      expect(find.byKey(const ValueKey('scan-panel')), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
    });
  });

  group('R-20 scan cancellation (PR #61 retroactive review major)', () {
    testWidgets('dispose DURING an in-flight scan cancels the source — a late '
        'completion cannot touch the unmounted state', (tester) async {
      final gate = Completer<List<DiscoveredServer>>();
      final discovery = FakeDiscovery(() => gate.future);
      await pumpScreen(tester, discovery);
      expect(find.text('Searching the local network…'), findsOneWidget);

      // Pop-equivalent: tear the screen down while the auto-started scan is
      // still in flight.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(discovery.cancels, 1, reason: 'dispose() abandoned the scan');

      // The orphaned completion lands after unmount (this is the path
      // the generation token + cancel() together defuse): it must not
      // throw and must not schedule frames.
      gate.complete(const [hit1]);
      await tester.pump(const Duration(seconds: 13)); // drain 12 s timeout
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'retry after timeout: scan 1 (timed out) completing late cannot '
      'clobber scan 2 — panel keeps Searching, no stale hits land',
      (tester) async {
        // NOTE (round-2 review): this pins the USER-VISIBLE retry contract
        // end-to-end; it is not a discriminating test for _scanGen — a
        // late completion after .timeout() never even resumes _runScan
        // (the wrapper already completed), so mounted alone passes it.
        // The token is defence-in-depth for that wrapper, not a tested
        // race. It IS load-bearing against the per-instance cancel flag
        // (see MdnsOwnToneDiscovery._scanToken comment).
        final g1 = Completer<List<DiscoveredServer>>();
        final g2 = Completer<List<DiscoveredServer>>();
        var call = 0;
        final discovery = FakeDiscovery(() => (call++ == 0 ? g1 : g2).future);
        await pumpScreen(tester, discovery);

        await tester.pump(const Duration(seconds: 13)); // kScanTimeout
        expect(
          find.byKey(const ValueKey('scan-retry')),
          findsOneWidget,
          reason: 'timeout → error state',
        );

        await tapKey(tester, 'scan-retry');
        expect(find.text('Searching the local network…'), findsOneWidget);

        g1.complete(const [hit1]); // orphaned scan 1 lands late
        await tester.pump();
        expect(
          find.text('My Music on hp-server'),
          findsNothing,
          reason: 'stale hits must not appear mid-scan-2',
        );
        expect(find.text('Searching the local network…'), findsOneWidget);

        g2.complete(const []);
        await tester.pump();
        expect(find.text('Searching the local network…'), findsNothing);
      },
    );

    testWidgets(
      'PUSHED SettingsScreen: tapping a hit pops the route and connects '
      '(pins the Navigator.of(context).pop() branch, unreachable while the '
      'screen is pumped as home — the issue #64 crash neighbourhood)',
      (tester) async {
        final discovery = FakeDiscovery(() async => const [hit1]);
        SharedPreferences.setMockInitialValues({});
        final store = await SettingsStore.create();
        final conn = scriptedConn();
        opened.add(conn);
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              Provider<SettingsStore>.value(value: store),
              ChangeNotifierProvider<ThemePreference>.value(
                value: ThemePreference(store),
              ),
              ChangeNotifierProvider<ConnectionController>.value(value: conn),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    key: const ValueKey('push'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            SettingsScreen(initial: null, discovery: discovery),
                      ),
                    ),
                    child: const Text('go'),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const ValueKey('push')));
        await tester.pumpAndSettle(); // route animation + auto-started scan
        expect(find.text('My Music on hp-server'), findsOneWidget);

        await tapKey(tester, 'scan-hit-0');
        await tester.pumpAndSettle();

        expect(find.text('go'), findsOneWidget, reason: 'route popped');
        expect(find.byType(SettingsScreen), findsNothing);
        expect(conn.phase, ConnectionPhase.connected);
      },
    );
  });
}
