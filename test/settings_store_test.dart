import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsStore (R-01: persisted across launches)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('empty store → null config', () async {
      final store = await SettingsStore.create();
      expect(store.config, isNull);
    });

    test('save → reload survives a "relaunch" (fresh instance)', () async {
      const cfg = ServerConfig(host: '192.168.1.13', port: 3689);
      await (await SettingsStore.create()).save(cfg);

      // A fresh instance reads the same backing store — the relaunch case.
      final reloaded = (await SettingsStore.create()).config;
      expect(reloaded, cfg);
    });

    test('only host saved → still null (incomplete config)', () async {
      SharedPreferences.setMockInitialValues({'server.host': 'h'});
      final store = await SettingsStore.create();
      expect(store.config, isNull);
    });
  });

  group('SettingsStore rocker step (R-14: persisted, 1–10, default 5)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('unset → default 5', () async {
      final store = await SettingsStore.create();
      expect(store.rockerStep, 5);
    });

    test('save → reload survives a "relaunch" (fresh instance)', () async {
      await (await SettingsStore.create()).saveRockerStep(1);
      expect((await SettingsStore.create()).rockerStep, 1);
    });

    test('save clamps out of range (0 → 1, 15 → 10)', () async {
      final store = await SettingsStore.create();
      await store.saveRockerStep(0);
      expect(store.rockerStep, 1);
      await store.saveRockerStep(15);
      expect(store.rockerStep, 10);
    });

    test('a hand-edited out-of-range stored value clamps on read', () async {
      SharedPreferences.setMockInitialValues({'rocker.step': 99});
      expect((await SettingsStore.create()).rockerStep, 10);
      SharedPreferences.setMockInitialValues({'rocker.step': 0});
      expect((await SettingsStore.create()).rockerStep, 1);
    });

    test('step and server config persist independently', () async {
      final store = await SettingsStore.create();
      await store.saveRockerStep(3);
      await store.save(const ServerConfig(host: 'h', port: 1));
      final reloaded = await SettingsStore.create();
      expect(reloaded.rockerStep, 3);
      expect(reloaded.config, const ServerConfig(host: 'h', port: 1));
    });
  });

  group('SettingsStore theme mode (R-26: default system, persisted, '
      'read-validate fallback)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('R-26 unset → default System', () async {
      final store = await SettingsStore.create();
      expect(store.themeMode, ThemeMode.system);
    });

    test('R-26 save → reload survives a "relaunch" (fresh instance)', () async {
      await (await SettingsStore.create()).saveThemeMode(ThemeMode.dark);
      expect((await SettingsStore.create()).themeMode, ThemeMode.dark);
      await (await SettingsStore.create()).saveThemeMode(ThemeMode.light);
      expect((await SettingsStore.create()).themeMode, ThemeMode.light);
    });

    test(
      'R-26 corrupt persisted value degrades to System, never a crash',
      () async {
        SharedPreferences.setMockInitialValues({'theme.mode': 'neon'});
        expect((await SettingsStore.create()).themeMode, ThemeMode.system);
        SharedPreferences.setMockInitialValues({'theme.mode': ''});
        expect((await SettingsStore.create()).themeMode, ThemeMode.system);
        // Wrong case / legacy spelling is unknown → fallback, not a crash.
        SharedPreferences.setMockInitialValues({'theme.mode': 'LIGHT'});
        expect((await SettingsStore.create()).themeMode, ThemeMode.system);
      },
    );

    test('R-26 wrongly-typed stored value degrades to System', () async {
      // getString on an int-backed key reads null → default.
      SharedPreferences.setMockInitialValues({'theme.mode': 7});
      expect((await SettingsStore.create()).themeMode, ThemeMode.system);
    });

    test('R-26 theme and server config persist independently', () async {
      final store = await SettingsStore.create();
      await store.saveThemeMode(ThemeMode.dark);
      await store.save(const ServerConfig(host: 'h', port: 1));
      final reloaded = await SettingsStore.create();
      expect(reloaded.themeMode, ThemeMode.dark);
      expect(reloaded.config, const ServerConfig(host: 'h', port: 1));
    });
  });
}
