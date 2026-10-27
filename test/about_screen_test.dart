import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/app_info.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/ui/about_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fakes/fake_owntone_server.dart';

const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

/// R-14 (unit 008) fixture: scriptable `/api/config` (`websocket_port: 0`
/// → REST-only, no WS channel needed); `failConfig` simulates the server
/// going away for the offline/error state.
class AboutFixture {
  String version = '29.3';
  List<String> buildoptions = const ['ffmpeg', 'AirPlay 1', 'ALSA'];
  bool failConfig = false;

  Response<dynamic> handle(RequestOptions o) {
    switch (o.path) {
      case '/api/config':
        if (failConfig) {
          throw networkError(o, const SocketException('down'));
        }
        return jsonResponse(o, {
          'websocket_port': 0,
          'version': version,
          'buildoptions': buildoptions,
        });
      default:
        return jsonResponse(o, <String, dynamic>{});
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AboutFixture fx;
  late ScriptedAdapter adapter;
  ConnectionController? conn;

  Future<void> connect() async {
    fx = AboutFixture();
    adapter = ScriptedAdapter(responder: fx.handle);
    conn = ConnectionController(
      dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
    );
    await conn!.connectTo(_cfg);
  }

  Future<void> pumpAbout(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<ConnectionController>.value(value: conn!),
        ],
        child: const MaterialApp(home: AboutScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() {
    // Nullable: tests that never connect (pubspec drift guard, never-
    // connected error state) must not dispose a *previous* test's
    // controller — ChangeNotifier asserts on double-dispose.
    conn?.dispose();
    conn = null;
  });

  group('R-14 app identity (compile-time const — no package_info_plus)', () {
    testWidgets('name + version render from the constants', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(connect);
      await pumpAbout(tester);
      expect(find.text(kAppName), findsOneWidget);
      expect(find.text(kAppVersion), findsOneWidget);
    });

    test('kAppVersion mirrors pubspec.yaml (release-process drift guard)', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('version: $kAppVersion'));
    });
  });

  group('R-14 server info (GET /api/config)', () {
    testWidgets('version + buildoptions render from the fake config', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(connect);
      await pumpAbout(tester);
      expect(find.text('Server version'), findsOneWidget);
      expect(find.text('OwnTone 29.3'), findsOneWidget);
      expect(find.text('Build options'), findsOneWidget);
      expect(find.text('ffmpeg, AirPlay 1, ALSA'), findsOneWidget);
      expect(
        adapter.requests.where((r) => r.startsWith('GET /api/config')),
        hasLength(2),
        reason: 'one connect probe + one About fetch',
      );
    });

    testWidgets('tapping the server version re-fetches and shows fresh data', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(connect);
      await pumpAbout(tester);

      fx.version = '30.0';
      fx.buildoptions = const ['ffmpeg', 'ALSA'];
      await tester.tap(find.byKey(const ValueKey('about-server-version')));
      await tester.pumpAndSettle();

      expect(
        adapter.requests.where((r) => r.startsWith('GET /api/config')),
        hasLength(3),
        reason: 'connect probe + initial About fetch + tap re-fetch',
      );
      expect(find.text('OwnTone 30.0'), findsOneWidget);
      expect(find.text('ffmpeg, ALSA'), findsOneWidget);
      expect(find.text('OwnTone 29.3'), findsNothing, reason: 'not stale');
    });

    testWidgets('offline (never connected) → error state with Retry', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      conn = ConnectionController(); // idle — api is null
      await pumpAbout(tester);
      expect(find.byKey(const ValueKey('about-error')), findsOneWidget);
      expect(find.text('Could not reach the server.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Server version'), findsNothing);
    });

    testWidgets('server dies after connect → re-fetch shows the error '
        'state, never stale values', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(connect);
      await pumpAbout(tester);
      expect(find.text('OwnTone 29.3'), findsOneWidget);

      fx.failConfig = true;
      await tester.tap(find.byKey(const ValueKey('about-server-version')));
      await tester.pumpAndSettle();
      expect(find.text('Could not reach the server.'), findsOneWidget);
      expect(find.text('OwnTone 29.3'), findsNothing);

      // Retry recovers when the server answers again.
      fx.failConfig = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('OwnTone 29.3'), findsOneWidget);
    });
  });

  group('unit 004 viewport rule', () {
    testWidgets('About renders at 360 logical px with no overflow', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      await tester.runAsync(connect);
      await pumpAbout(tester);
      expect(find.text('OwnTone 29.3'), findsOneWidget);
      // Long buildoptions list too (the widest content on the screen).
      fx.buildoptions = List.generate(20, (i) => 'Option$i');
      await tester.tap(find.byKey(const ValueKey('about-server-version')));
      await tester.pumpAndSettle();
      // RenderFlex overflow throws in the test binding — reaching here is
      // the assertion.
    });
  });
}
