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
}
