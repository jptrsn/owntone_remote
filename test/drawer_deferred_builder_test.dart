import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/main.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/outputs/outputs_controller.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/queue/queue_controller.dart';
import 'package:owntone_remote/src/rating/rating_controller.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:owntone_remote/src/settings/theme_preference.dart';
import 'package:owntone_remote/src/ui/app_drawer.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';
import 'package:owntone_remote/src/ui/queue_screen.dart';
import 'package:owntone_remote/src/ui/settings_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// issue #64 — the drawer's deferred page builder must never read providers
/// through the *caller's* context.
///
/// RCA (host device pass, Pixel 6, 2026-11-23): `AppDrawer._open` handed
/// [showDrawerDestination] a closure that did `context.read<…>()` with the
/// AppDrawer element's own context. That closure is the pushed route's page
/// builder — it first runs *after* `popUntil(isFirst)` has popped the drawer's
/// own route, and re-runs on every later rebuild of that route's
/// `_ModalScopeState`. Once the popped subtree unmounted, the next rebuild
/// (theme toggle, ws event storm, hot reload) read through a `defunct` element,
/// and debug builds answered with the red screen
/// `Looking up a deactivated widget's ancestor is unsafe`.
///
/// The suite was green with the bug present AND absent, because no test tapped
/// Settings from a *pushed* screen and then rebuilt that route's content after
/// the pop settled. That is exactly the shape asserted below, so a reviewer
/// mutation-checks this file by restoring the lazy `context.read` inside the
/// closure in `AppDrawer._open` and confirming the first test goes red.
///
/// R-26's theme toggle is the rebuild trigger: `OwntoneRemoteApp` watches
/// [ThemePreference], so flipping it rebuilds MaterialApp → Navigator → Overlay
/// → every onstage `_ModalScopeState` → the pushed route's `buildContent` → the
/// deferred closure. It is a plain user gesture, no host tooling — the finding
/// that made this crash reachable without `flutter run` attached.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);
  const otherCfg = ServerConfig(host: '10.9.9.9', port: 3689);

  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late OutputsController outputs;
  late QueueController queue;
  late RatingController rating;
  late SettingsStore store;
  late ThemePreference theme;
  bool serverDown = false;

  Response<dynamic> handle(RequestOptions o) {
    if (serverDown) {
      throw networkError(
        o,
        socketFailure('Connection refused (ECONNREFUSED)', 111),
      );
    }
    switch (o.uri.path) {
      case '/api/config':
        return jsonResponse(o, {
          'websocket_port': 3688,
          'version': '29.3',
          'library_name': 'Test Music',
        });
      case '/api/player':
        return jsonResponse(o, {'state': 'pause', 'volume': 40});
      case '/api/queue':
        return jsonResponse(o, {
          'version': 1,
          'count': 1,
          'items': [
            {
              'id': 'q1',
              'item_id': 1,
              'title': 'Test Item',
              'artist': 'Artist 1',
              'album': 'Album 1',
              'lyrics': '',
              'art_url': '',
              'length_ms': 100000,
              'uri': 'library:track:1',
            },
          ],
        });
      case '/api/outputs':
        return jsonResponse(o, {
          'outputs': [
            {
              'id': 'a',
              'name': 'Alpha',
              'type': 'Chromecast',
              'selected': true,
              'has_password': false,
              'needs_auth_key': false,
              'volume': 50,
            },
          ],
        });
      case '/api/playlists':
      case '/api/library/playlists':
      case '/api/library/artists':
      case '/api/library/albums':
      case '/api/library/genres':
      case '/api/search':
        return jsonResponse(o, {
          'items': <Map<String, dynamic>>[],
          'total': 0,
          'offset': 0,
          'limit': 50,
        });
      default:
        return jsonResponse(o, <String, dynamic>{});
    }
  }

  /// Same harness as test/app_drawer_test.dart: real controllers over the
  /// scripted adapter + fake WS, real timers inside `tester.runAsync`.
  Future<void> wireUp() async {
    SharedPreferences.setMockInitialValues({});
    serverDown = false;
    adapter = ScriptedAdapter(responder: handle);
    channels = [];
    conn = ConnectionController(
      dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
      wsFactory: (uri, subscriptions, backoff) => WsClient(
        uri: uri,
        subscriptions: subscriptions,
        backoff: Backoff(
          initial: const Duration(milliseconds: 5),
          maximum: const Duration(milliseconds: 20),
        ),
        channelFactory: (u) {
          final c = FakeWsChannel();
          if (serverDown) c.handshakeFails = true;
          channels.add(c);
          return c;
        },
      ),
    );
    player = PlayerController(connection: conn);
    await player.init();
    outputs = OutputsController(connection: conn);
    await outputs.init();
    queue = QueueController(connection: conn);
    await queue.init();
    rating = RatingController(connection: conn, player: player);
    await rating.init();
    store = SettingsStore(await SharedPreferences.getInstance());
    theme = ThemePreference(store);
    await conn.connectTo(cfg);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  tearDown(() {
    player.dispose();
    outputs.dispose();
    rating.dispose();
    queue.dispose();
    conn.dispose();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The real [OwntoneRemoteApp] MaterialApp — required, because the rebuild
  /// trigger is MaterialApp itself watching [ThemePreference]. A bare
  /// MaterialApp would not re-skin on a theme change, so the cascade would
  /// never reach the pushed route's page builder and the crash test would pass
  /// vacuously.
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SettingsStore>.value(value: store),
          ChangeNotifierProvider<ThemePreference>.value(value: theme),
          ChangeNotifierProvider<ConnectionController>.value(value: conn),
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<OutputsController>.value(value: outputs),
          ChangeNotifierProvider<QueueController>.value(value: queue),
          ChangeNotifierProvider<RatingController>.value(value: rating),
        ],
        // NOT const: a canonical const instance would short-circuit
        // updateChild's == check and pin the subtree to this pump.
        child: OwntoneRemoteApp(home: const NowPlayingScreen()),
      ),
    );
    await settle(tester);
  }

  Future<void> openDrawer(WidgetTester tester, Type screen) async {
    await tester.tap(
      find
          .descendant(
            of: find.byType(screen),
            matching: find.byType(DrawerButton),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  Finder drawerTile(DrawerDestination dest) =>
      find.byKey(ValueKey('drawer-${dest.name}'));

  Finder themeSegment(String label) => find.descendant(
    of: find.byKey(const ValueKey('theme-mode-picker')),
    matching: find.text(label),
  );

  /// R-26 toggle as the post-settle rebuild trigger (the 2026-11-23 finding: a
  /// plain gesture, no `flutter run` needed).
  Future<void> toggleTheme(WidgetTester tester) async {
    await tester.ensureVisible(themeSegment('Dark'));
    await tester.pumpAndSettle();
    await tester.tap(themeSegment('Dark'));
    // pump, not pumpAndSettle: AnimatedTheme's 200 ms lerp is the multi-frame
    // rebuild cascade that re-runs the page builder.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  SettingsScreen settingsScreen(WidgetTester tester) =>
      tester.widget<SettingsScreen>(find.byType(SettingsScreen).last);

  group(
    '#64 drawer → Settings from a PUSHED screen (deferred page builder)',
    () {
      testWidgets('pushing Queue, then drawer → Settings, then rebuilding that '
          'route (R-26 theme toggle) does not touch a deactivated ancestor', (
        tester,
      ) async {
        await tester.runAsync(wireUp);
        await pumpApp(tester);

        // 1. Root drawer → Queue: the pushed screen whose drawer is the source.
        await openDrawer(tester, NowPlayingScreen);
        await tester.tap(drawerTile(DrawerDestination.queue));
        await tester.pumpAndSettle();
        expect(find.byType(QueueScreen), findsOneWidget);

        // 2. Queue's OWN drawer → Settings. This pops Queue's route — the route
        // owning the AppDrawer element whose context the closure used to
        // capture.
        await openDrawer(tester, QueueScreen);
        await tester.tap(drawerTile(DrawerDestination.settings));
        await tester.pumpAndSettle();
        expect(
          find.byType(SettingsScreen),
          findsOneWidget,
          reason:
              'the tap itself never showed the red screen — step 3 of the '
              'RCA mechanism is the later rebuild',
        );

        // 3. The discriminating step: rebuild the pushed route's content AFTER
        // the pop completed, i.e. with the popped subtree now defunct.
        await toggleTheme(tester);

        expect(
          tester.takeException(),
          isNull,
          reason:
              'issue #64: a provider lookup on the popped drawer element '
              'surfaces here as "Looking up a deactivated widget’s ancestor '
              'is unsafe"',
        );
        expect(
          find.byType(SettingsScreen),
          findsOneWidget,
          reason: 'the rebuild must not have lost the Settings route',
        );
        expect(
          Theme.of(tester.element(find.byType(SettingsScreen).last)).brightness,
          Brightness.dark,
          reason:
              'the R-26 toggle really reached the pushed route — without '
              'this the test could pass without rebuilding anything',
        );
      });

      testWidgets('SettingsScreen.initial is the ConnectionController.config '
          'value captured at TAP time, not a live provider read', (
        tester,
      ) async {
        await tester.runAsync(wireUp);
        await pumpApp(tester);

        await openDrawer(tester, NowPlayingScreen);
        await tester.tap(drawerTile(DrawerDestination.queue));
        await tester.pumpAndSettle();
        await openDrawer(tester, QueueScreen);
        expect(
          conn.config,
          cfg,
          reason: 'precondition: the controller holds the tap-time value',
        );

        await tester.tap(drawerTile(DrawerDestination.settings));
        await tester.pumpAndSettle();
        expect(
          settingsScreen(tester).initial,
          cfg,
          reason:
              'the eager tap-time read produced the value the deferred '
              'builder used',
        );

        // Move the provider AFTER the pop, then rebuild: a builder that still
        // read through the (now defunct) context would either throw here or
        // drift to the new value.
        await tester.runAsync(() async {
          await conn.connectTo(otherCfg);
          await Future<void>.delayed(const Duration(milliseconds: 60));
        });
        expect(conn.config, otherCfg, reason: 'the provider really moved on');
        await tester.pump();
        await toggleTheme(tester);
        expect(tester.takeException(), isNull);
        expect(
          settingsScreen(tester).initial,
          cfg,
          reason: 'the route keeps its tap-time snapshot',
        );
      });
    },
  );

  group('#64 Settings from the ROOT drawer — same hazard, one hop away', () {
    testWidgets('the post-settle theme toggle is clean here too, and is NOT a '
        'vacuous pass: with the lazy `context.read` restored this fails as '
        'well, because DrawerController unmounts the drawer once the close '
        'animation settles', (tester) async {
      await tester.runAsync(wireUp);
      await pumpApp(tester);

      await openDrawer(tester, NowPlayingScreen);
      await tester.tap(drawerTile(DrawerDestination.settings));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);

      await toggleTheme(tester);
      expect(tester.takeException(), isNull);
      expect(settingsScreen(tester).initial, cfg);
    });
  });

  group('#64 the R-21 navigation contract is unchanged', () {
    testWidgets('a drawer tap from the pushed Settings screen still collapses '
        'to [root, target] without stacking a duplicate', (tester) async {
      await tester.runAsync(wireUp);
      await pumpApp(tester);

      await openDrawer(tester, NowPlayingScreen);
      await tester.tap(drawerTile(DrawerDestination.queue));
      await tester.pumpAndSettle();
      await openDrawer(tester, QueueScreen);
      await tester.tap(drawerTile(DrawerDestination.settings));
      await tester.pumpAndSettle();

      await openDrawer(tester, SettingsScreen);
      await tester.tap(drawerTile(DrawerDestination.queue));
      await tester.pumpAndSettle();
      expect(
        find.byType(QueueScreen),
        findsOneWidget,
        reason: 'popUntil(isFirst) + one push: never a duplicate',
      );
      expect(
        find.byType(SettingsScreen),
        findsNothing,
        reason: 'the stack collapsed to the root before the push',
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byType(QueueScreen),
        findsNothing,
        reason: 'one back = back to the root',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
