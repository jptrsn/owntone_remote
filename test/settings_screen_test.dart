import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:owntone_remote/src/ui/about_screen.dart';
import 'package:owntone_remote/src/ui/settings_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings screen, R-14 rows (unit 008): the rocker-step control
/// (render / ±1 / clamping / immediate persistence) and the About entry.
/// An idle [ConnectionController] — the step row and About entry must not
/// depend on a live server, and no fake wire is needed (no network).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ConnectionController conn;

  setUp(() {
    conn = ConnectionController();
  });

  tearDown(() {
    conn.dispose();
  });

  /// Distinct [tag] per call: `pumpWidget` reuses the [SettingsScreen]
  /// State (initState would not re-read the store on a second pump in the
  /// same test).
  Future<SettingsStore> pumpScreen(
    WidgetTester tester, {
    Object tag = 1,
  }) async {
    final store = await SettingsStore.create();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SettingsStore>.value(value: store),
          ChangeNotifierProvider<ConnectionController>.value(value: conn),
        ],
        child: MaterialApp(
          home: SettingsScreen(
            key: ValueKey(tag),
            initial: const ServerConfig(host: '10.0.0.5', port: 3689),
          ),
        ),
      ),
    );
    await tester.pump();
    return store;
  }

  IconButton stepButton(WidgetTester tester, String key) =>
      tester.widget<IconButton>(find.byKey(ValueKey(key)));

  group('R-14 rocker-step control', () {
    testWidgets('renders the persisted step (default 5 when unset)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpScreen(tester);
      expect(find.text('5'), findsOneWidget);

      SharedPreferences.setMockInitialValues({'rocker.step': 2});
      await pumpScreen(tester, tag: 'two');
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('± taps move the value and persist immediately — the next '
        'keypress reads the store (applies without restart)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = await pumpScreen(tester);

      await tester.tap(find.byKey(const ValueKey('rocker-step-increase')));
      await tester.pump();
      expect(find.text('6'), findsOneWidget);
      expect(store.rockerStep, 6, reason: 'store already at 6 (keypress read)');
      // Survives a "relaunch" (fresh store over the same prefs).
      expect((await SettingsStore.create()).rockerStep, 6);

      await tester.tap(find.byKey(const ValueKey('rocker-step-decrease')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('rocker-step-decrease')));
      await tester.pump();
      expect(find.text('4'), findsOneWidget);
      expect(store.rockerStep, 4);
    });

    testWidgets('clamped at the bounds: disabled at 1 / 10, never beyond', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({'rocker.step': 1});
      await pumpScreen(tester, tag: 'one');
      expect(
        stepButton(tester, 'rocker-step-decrease').onPressed,
        isNull,
        reason: 'cannot go below 1',
      );
      await tester.tap(find.byKey(const ValueKey('rocker-step-decrease')));
      await tester.pump();
      expect(find.text('1'), findsOneWidget, reason: 'tap on disabled = no-op');

      SharedPreferences.setMockInitialValues({'rocker.step': 10});
      await pumpScreen(tester, tag: 'ten');
      expect(
        stepButton(tester, 'rocker-step-increase').onPressed,
        isNull,
        reason: 'cannot go above 10',
      );
    });
  });

  group('R-14 About entry', () {
    testWidgets('About row pushes the read-only About screen', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpScreen(tester);
      // The row sits below the 640-px fold in this test viewport — a raw
      // tap on an unfound-by-hit-test widget is a silent miss.
      await tester.ensureVisible(find.byKey(const ValueKey('about-entry')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('about-entry')));
      await tester.pumpAndSettle();
      expect(find.byType(AboutScreen), findsOneWidget);
      expect(find.text('About'), findsWidgets);
    });
  });

  group('unit 004 viewport rule', () {
    testWidgets('Settings renders at 360 logical px with no overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      await pumpScreen(tester);
      expect(find.text('Volume rocker step'), findsOneWidget);
      // RenderFlex overflow throws in the test binding — reaching here is
      // the assertion.
    });
  });
}
