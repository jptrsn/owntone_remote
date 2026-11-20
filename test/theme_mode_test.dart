import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/main.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:owntone_remote/src/settings/theme_preference.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// R-26 (issue #43): theme preference. Oracle is `Theme.of(context)
/// .brightness` inside the real [OwntoneRemoteApp] MaterialApp wiring
/// (darkTheme derived from the same seed), driven only through persisted
/// prefs and `platformDispatcher` — no network, no server.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const probeKey = ValueKey('theme-probe');

  /// Pump the app shell with a trivial home — the theme contract does not
  /// depend on [RootScreen] (which would need every controller provider).
  Future<void> pumpThemeApp(WidgetTester tester) async {
    final store = await SettingsStore.create();
    // NOT const: a canonical const instance would short-circuit
    // updateChild's == check and pin the subtree to the first pump's
    // ThemePreference (stale scheme on re-pump).
    await tester.pumpWidget(
      ChangeNotifierProvider<ThemePreference>.value(
        value: ThemePreference(store),
        child: OwntoneRemoteApp(home: const SizedBox.shrink(key: probeKey)),
      ),
    );
    // pumpAndSettle, not pump: MaterialApp wraps the resolved theme in an
    // AnimatedTheme (200 ms) — a single pump leaves Theme.of mid-lerp.
    await tester.pumpAndSettle();
  }

  /// Drive a platform brightness flip live — TestPlatformDispatcher does
  /// not dispatch the change callback by itself.
  Future<void> setPlatformBrightness(
    WidgetTester tester,
    Brightness brightness,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    tester.binding.handlePlatformBrightnessChanged();
    await tester.pumpAndSettle();
  }

  Brightness probeBrightness(WidgetTester tester) =>
      Theme.of(tester.element(find.byKey(probeKey))).brightness;

  MaterialApp appOf(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp));

  group('ThemePreference (R-26 listenable mirror of the store)', () {
    test(
      'R-26 seeds from the store; corrupt value → System, no crash',
      () async {
        SharedPreferences.setMockInitialValues({'theme.mode': 'neon'});
        final pref = ThemePreference(await SettingsStore.create());
        expect(pref.mode, ThemeMode.system);
      },
    );

    test('R-26 setMode notifies listeners once and persists immediately '
        '(applies without restart; survives a "relaunch")', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await SettingsStore.create();
      final pref = ThemePreference(store);
      var notifications = 0;
      pref.addListener(() => notifications++);

      await pref.setMode(ThemeMode.dark);
      expect(pref.mode, ThemeMode.dark);
      expect(notifications, 1);
      // Fresh store over the same prefs = the kill/relaunch read.
      expect((await SettingsStore.create()).themeMode, ThemeMode.dark);

      await pref.setMode(ThemeMode.dark); // no-op → no rebuild storm
      expect(notifications, 1);
    });
  });

  group('OwntoneRemoteApp theme wiring (R-26)', () {
    testWidgets('R-26 stored Light renders light; stored Dark renders dark', (
      tester,
    ) async {
      // Platform stays light here, so "dark" can only come from the forced
      // darkTheme.
      SharedPreferences.setMockInitialValues({'theme.mode': 'dark'});
      await pumpThemeApp(tester);
      expect(probeBrightness(tester), Brightness.dark);

      SharedPreferences.setMockInitialValues({'theme.mode': 'light'});
      await pumpThemeApp(tester);
      expect(probeBrightness(tester), Brightness.light);
    });

    testWidgets('R-26 default is System — follows a platform brightness '
        'change live, while running (no restart)', (tester) async {
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      SharedPreferences.setMockInitialValues({}); // unset → System
      await pumpThemeApp(tester);
      expect(probeBrightness(tester), Brightness.light);

      await setPlatformBrightness(tester, Brightness.dark);
      expect(probeBrightness(tester), Brightness.dark);

      await setPlatformBrightness(tester, Brightness.light);
      expect(probeBrightness(tester), Brightness.light);
    });

    testWidgets('R-26 corrupt persisted value degrades to System — never a '
        'crash, never a forced scheme', (tester) async {
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      SharedPreferences.setMockInitialValues({'theme.mode': 'garbage!!'});
      await pumpThemeApp(tester); // no exception
      expect(probeBrightness(tester), Brightness.light);
      // It really is System (not forced light): the platform flip moves it.
      await setPlatformBrightness(tester, Brightness.dark);
      expect(probeBrightness(tester), Brightness.dark);
    });

    testWidgets('R-26 selection survives kill/relaunch — stored dark boots '
        'dark even on a light platform', (tester) async {
      SharedPreferences.setMockInitialValues({'theme.mode': 'dark'});
      await pumpThemeApp(tester); // a fresh boot over the persisted value
      expect(probeBrightness(tester), Brightness.dark);
      expect(appOf(tester).themeMode, ThemeMode.dark);
    });

    testWidgets('R-26 dark scheme derives from the existing seed — '
        'fromSeed(0xFF7C5CBF, dark), no bespoke palette', (tester) async {
      SharedPreferences.setMockInitialValues({'theme.mode': 'dark'});
      await pumpThemeApp(tester);
      const seed = Color(0xFF7C5CBF);
      final app = appOf(tester);
      expect(
        app.darkTheme?.colorScheme,
        ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        reason: 'dark scheme == fromSeed with the same seed (nothing bespoke)',
      );
      expect(
        app.theme?.colorScheme,
        ColorScheme.fromSeed(seedColor: seed),
        reason: 'light scheme unchanged, same seed',
      );
      expect(app.darkTheme?.brightness, Brightness.dark);
    });
  });
}
