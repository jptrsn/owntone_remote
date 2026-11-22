/// Widget tests for the R-20 scan side panel (issue #42) against a FAKE
/// [DiscoverySource] — no network, no mDNS sockets. The R-01 leg is driven
/// through the real [ConnectionController] with the repo's
/// [ScriptedAdapter] (websocket_port 0 → no WS, no wire), so "tap pre-fills
/// and connects through the existing flow" is asserted on the actual
/// connect path, not a stub.
///
/// R-20: scan lists hits (name + host + port); a tap pre-fills the config
/// fields and goes through the existing R-01 connect flow; scan failure /
/// timeout show the error state with manual entry still enabled.
library;

import 'dart:async';

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
  /// WsClient out of the picture (R-02 REST-only mode).
  ConnectionController scriptedConn() => ConnectionController(
    dioFactory: (options) => Dio(options)
      ..httpClientAdapter = ScriptedAdapter(
        responder: (o) async => o.uri.path == '/api/config'
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
  }) async {
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
          home: SettingsScreen(
            key: ValueKey(tag),
            initial: null,
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

  // ensureVisible ANIMATES the scroll — a single pump() leaves the widget
  // mid-flight and the tap hits the stale position (observed on the Connect
  // button under the scan panel). Settle first; these taps are only ever
  // issued while nothing spins.
  Future<void> tapScan(WidgetTester tester) async {
    await tester.ensureVisible(
      find.byKey(const ValueKey('server-scan-button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('server-scan-button')));
    await tester.pump();
  }

  Future<void> tapButton(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pump();
  }

  group('R-20 scan side panel', () {
    testWidgets('scan lists the fake hits with name + host:port', (
      tester,
    ) async {
      final discovery = FakeDiscovery(() async => const [hit1, hit2]);
      await pumpScreen(tester, discovery);

      await tapScan(tester);
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

      await tapScan(tester);
      await tester.pump();
      await tapButton(tester, find.byKey(const ValueKey('scan-hit-0')));
      // The hand-off is the existing _saveAndConnect: persist + connectTo
      // on the scripted controller — settle to let both land.
      await tester.pumpAndSettle();

      expect(fieldText(tester, 'Host'), '192.168.1.13');
      expect(fieldText(tester, 'JSON port'), '3689');
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
    });

    testWidgets('manual entry stays usable DURING a scan: fields editable '
        'while the panel is in its loading state', (tester) async {
      final gate = Completer<List<DiscoveredServer>>();
      final discovery = FakeDiscovery(() => gate.future);
      await pumpScreen(tester, discovery);

      await tapScan(tester);
      expect(find.text('Searching the local network…'), findsOneWidget);

      // enterText on a disabled field would throw — succeeding IS the
      // assertion that the scan does not block manual entry.
      await tester.enterText(editable('Host'), 'manual.example');
      await tester.enterText(editable('JSON port'), '3689');
      await tester.pump();
      expect(fieldText(tester, 'Host'), 'manual.example');

      gate.complete(const []);
      await tester.pump();
    });

    testWidgets('scan FAILURE (DiscoveryException) → error state with '
        'retry; manual entry still works end-to-end afterwards', (
      tester,
    ) async {
      final discovery = FakeDiscovery(
        () async =>
            throw const DiscoveryException('Could not start the network scan.'),
      );
      final (store, conn) = await pumpScreen(tester, discovery);

      await tapScan(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('scan-error')), findsOneWidget);
      expect(
        find.textContaining('Could not start the network scan.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('scan-retry')), findsOneWidget);

      // Manual entry fully usable after the failure (R-20: never blocked).
      await tester.enterText(editable('Host'), '192.168.5.9');
      await tester.enterText(editable('JSON port'), '3689');
      await tapButton(tester, find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
      expect(store.config, const ServerConfig(host: '192.168.5.9', port: 3689));
      expect(conn.phase, ConnectionPhase.connected);
    });

    testWidgets('scan TIMEOUT → timeout error state; manual entry still '
        'works (panel resolves within kScanTimeout even if the source '
        'hangs)', (tester) async {
      final discovery = FakeDiscovery(
        () => Completer<List<DiscoveredServer>>().future,
      );
      await pumpScreen(tester, discovery);

      await tapScan(tester);
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

      await tester.pump(kScanTimeout + const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('scan-error')), findsOneWidget);
      expect(find.textContaining('Scan timed out'), findsOneWidget);

      await tester.enterText(editable('Host'), '192.168.5.10');
      await tester.enterText(editable('JSON port'), '3689');
      await tapButton(tester, find.widgetWithText(FilledButton, 'Connect'));
      await tester.pumpAndSettle();
    });

    testWidgets('empty scan → not-found state; retry re-runs the source '
        'and then lists hits', (tester) async {
      late final FakeDiscovery discovery;
      discovery = FakeDiscovery(
        () async => discovery.calls == 1 ? const [] : const [hit1],
      );
      await pumpScreen(tester, discovery);

      await tapScan(tester);
      await tester.pump();
      expect(find.byKey(const ValueKey('scan-empty')), findsOneWidget);
      expect(find.textContaining('No OwnTone server found'), findsOneWidget);

      await tapButton(tester, find.byKey(const ValueKey('scan-retry')));
      await tester.pump();
      expect(discovery.calls, 2);
      expect(find.text('My Music on hp-server'), findsOneWidget);
    });

    testWidgets('scan panel renders at 360 logical px with no overflow '
        '(unit 004 viewport rule)', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final discovery = FakeDiscovery(() async => const [hit1, hit2]);
      await pumpScreen(tester, discovery);

      await tapScan(tester);
      await tester.pump();
      // RenderFlex overflow throws in the test binding — reaching here is
      // the assertion.
      expect(find.byKey(const ValueKey('scan-panel')), findsOneWidget);
    });
  });

  group('R-20 scan cancellation (PR #61 retroactive review major)', () {
    testWidgets('dispose DURING an in-flight scan cancels the source — a late '
        'completion cannot touch the unmounted state', (tester) async {
      final gate = Completer<List<DiscoveredServer>>();
      final discovery = FakeDiscovery(() => gate.future);
      await pumpScreen(tester, discovery);

      await tapScan(tester);
      expect(find.text('Searching the local network…'), findsOneWidget);

      // Pop-equivalent: tear the screen down while the scan is in flight.
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
        // late completion after .timeout() never even resumes _startScan
        // (the wrapper already completed), so mounted alone passes it.
        // The token is defence-in-depth for that wrapper, not a tested
        // race. It IS load-bearing against the per-instance cancel flag
        // (see MdnsOwnToneDiscovery._scanToken comment).
        final g1 = Completer<List<DiscoveredServer>>();
        final g2 = Completer<List<DiscoveredServer>>();
        var call = 0;
        final discovery = FakeDiscovery(() => (call++ == 0 ? g1 : g2).future);
        await pumpScreen(tester, discovery);

        await tapScan(tester);
        await tester.pump(const Duration(seconds: 13)); // kScanTimeout
        final retry = find.byKey(const ValueKey('scan-retry'));
        expect(retry, findsOneWidget, reason: 'timeout → error state');

        await tapButton(tester, retry);
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
        await tester.pumpAndSettle();
        await tapScan(tester);
        expect(find.text('My Music on hp-server'), findsOneWidget);

        await tapButton(tester, find.byKey(const ValueKey('scan-hit-0')));
        await tester.pumpAndSettle();

        expect(find.text('go'), findsOneWidget, reason: 'route popped');
        expect(find.byType(SettingsScreen), findsNothing);
        expect(conn.phase, ConnectionPhase.connected);
      },
    );
  });
}
