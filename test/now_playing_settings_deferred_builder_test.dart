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
import 'package:owntone_remote/src/ui/now_playing_screen.dart';
import 'package:owntone_remote/src/ui/settings_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// issue #78 — NowPlaying's 'Server settings' button must resolve the
/// SettingsScreen pre-fill at PRESS time, not inside the pushed route's page
/// builder.
///
/// Same shape as issue #64 (fixed in PR #77 for the drawer): the
/// `MaterialPageRoute(builder: …)` closure handed to `Navigator.push` is not a
/// tap-time factory. It is the route's page builder — it first runs when the
/// new route builds and is re-run on **every** later rebuild of that route's
/// `_ModalScopeState` (R-26 theme change, websocket event storm, hot reload).
/// A `context.read` inside it is therefore a *deferred* provider lookup that
/// resolves against the NowPlaying element captured at press time; once that
/// element is `defunct`, the next re-run reads through a dead ancestor and
/// debug builds answer with the red screen
/// `Looking up a deactivated widget's ancestor is unsafe`.
///
/// It does not fire today purely by placement: NowPlaying is the app's root
/// route, so the push *covers* it rather than popping it and the element stays
/// mounted while the pushed screen is up. #64's harness already proved
/// 'covered, not popped' is not safety (DrawerController drops its drawer
/// subtree once the close animation settles), so the site is hardened to the
/// proven `settingsInitial` shape (app_drawer.dart, post-#77) rather than left
/// as a latent hazard.
///
/// The suite is mutation-sensitive in both directions (verify by hand, from a
/// `/tmp` copy — never `git checkout`, per AGENTS.md):
/// - restore the lazy `context.read` inside `builder:` in
///   `lib/src/ui/now_playing_screen.dart` and BOTH provider-leg tests go red:
///   the page builder is re-run *after* the hosting NowPlaying subtree has been
///   unmounted (its `home:` slot emptied), which is the harness-side stand-in
///   for the pop/unmount the root route would take in the #64 shape. The crash
///   tests therefore press while `conn.config` is null — the `??` fallback leg
///   is the only one that evaluates a provider read, and a test that presses
///   while connected would pass with the bug present (`??` short-circuits).
/// - replace the captured value with a live read in the builder (e.g.
///   `context.read<SettingsStore>().config` or `conn.config`) and the
///   tap-time-snapshot test goes red, because the route then drifts to the
///   post-press provider value.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);
  const otherCfg = ServerConfig(host: '10.9.9.9', port: 3689);
  const savedCfg = ServerConfig(host: '10.7.7.7', port: 3689);

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

  /// Same harness as test/drawer_deferred_builder_test.dart: real controllers
  /// over the scripted adapter + fake WS, real timers inside `tester.runAsync`.
  /// [saved] seeds the persisted `SettingsStore.config` (the fallback leg);
  /// [connect] = false leaves the controller at `idle` with a null config, so
  /// the button's `?? SettingsStore.config` fallback leg is the one in play.
  Future<void> wireUp({ServerConfig? saved, bool connect = true}) async {
    SharedPreferences.setMockInitialValues({
      if (saved != null) ...{
        'server.host': saved.host,
        'server.port': saved.port,
      },
    });
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
    if (connect) {
      await conn.connectTo(cfg);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
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

  /// `home:` is injectable so one test can unmount the NowPlaying element that
  /// the pressed button's context belongs to, while leaving the pushed route
  /// (and its page builder) onstage — the root-route stand-in for #64's pop.
  bool showRootPage = true;

  /// The real [OwntoneRemoteApp] MaterialApp — required, because the rebuild
  /// trigger is MaterialApp itself watching [ThemePreference]. A bare
  /// MaterialApp would not re-skin on a theme change, so the cascade would
  /// never reach the pushed route's page builder and the crash test would pass
  /// vacuously.
  Future<void> pumpAppTree(WidgetTester tester) async {
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
        child: OwntoneRemoteApp(
          home: showRootPage
              ? const NowPlayingScreen()
              : const SizedBox.shrink(),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    showRootPage = true;
    await pumpAppTree(tester);
  }

  /// Re-pump the app tree with `home:` emptied: the NowPlaying element (and the
  /// element the settings button's `onPressed` captured) is deactivated and
  /// unmounted, while the pushed SettingsScreen route stays onstage. Any
  /// provider lookup still living inside that route's page builder now runs
  /// through a defunct element.
  ///
  /// The assertion is what keeps this honest: if the root content somehow
  /// stayed mounted, every crash test below would pass vacuously.
  Future<void> unmountNowPlaying(WidgetTester tester) async {
    showRootPage = false;
    await pumpAppTree(tester);
    expect(
      find.descendant(
        of: find.byType(Navigator),
        matching: find.byType(NowPlayingScreen),
      ),
      findsNothing,
      reason:
          'the harness must really have unmounted the pressed button\'s '
          'host — otherwise the deferred-read tests prove nothing',
    );
    expect(
      find.byType(SettingsScreen),
      findsOneWidget,
      reason: 'the pushed route must survive the root swap',
    );
  }

  Finder settingsButton() => find.ancestor(
    of: find.byIcon(Icons.settings),
    matching: find.byType(IconButton),
  );

  Finder themeSegment(String label) => find.descendant(
    of: find.byKey(const ValueKey('theme-mode-picker')),
    matching: find.text(label),
  );

  /// R-26 toggle as the post-settle rebuild trigger (the #64 finding: a plain
  /// gesture, no `flutter run` needed). MaterialApp → Navigator → Overlay →
  /// every onstage `_ModalScopeState` → the pushed route's `buildContent` → the
  /// deferred closure.
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

  Future<void> openServerSettings(WidgetTester tester) async {
    expect(settingsButton(), findsOneWidget);
    await tester.tap(settingsButton());
    await tester.pumpAndSettle();
  }

  group(
    '#78 NowPlaying → Settings: the page builder must not read providers',
    () {
      testWidgets('pressing the button on the provider leg (conn.config null '
          '→ the `?? SettingsStore.config` read), then unmounting the route '
          'host and re-running the page builder (R-26 theme toggle), does not '
          'touch a deactivated ancestor', (tester) async {
        // Pressing with `conn.config == null` is what makes this test bite:
        // `conn.config ?? context.read<SettingsStore>().config` only evaluates
        // the provider read on the fallback leg, so pressing while connected
        // would leave the lazy mutation short-circuited and the test green.
        await tester.runAsync(() => wireUp(saved: savedCfg, connect: false));
        await pumpApp(tester);
        expect(conn.config, isNull, reason: 'provider leg is in play');

        // 1. Press on the root route. Today the host is only *covered*, so
        // even the lazy shape survives this step — the push itself is not what
        // red-screens.
        await openServerSettings(tester);
        expect(
          find.byType(SettingsScreen),
          findsOneWidget,
          reason:
              'the tap itself never showed the red screen — the failure is '
              'the later page-builder re-run',
        );
        expect(settingsScreen(tester).initial, savedCfg);

        // 2. The discriminating step: the NowPlaying element whose context the
        // builder used to capture is now defunct…
        await unmountNowPlaying(tester);
        // …and the pushed route's page builder is re-run over multiple frames.
        await toggleTheme(tester);

        expect(
          tester.takeException(),
          isNull,
          reason:
              'issue #78: a provider lookup on the deactivated NowPlaying '
              'element surfaces here as "Looking up a deactivated widget’s '
              'ancestor is unsafe" — restore the lazy context.read inside the '
              'builder in now_playing_screen.dart and this fails',
        );
        expect(
          find.byType(SettingsScreen),
          findsOneWidget,
          reason: 'the rebuild must not have lost the Settings route',
        );
        expect(
          settingsScreen(tester).initial,
          savedCfg,
          reason:
              'the re-run rebuilt the same screen from the press-time value',
        );
        expect(
          Theme.of(tester.element(find.byType(SettingsScreen).last)).brightness,
          Brightness.dark,
          reason:
              'the R-26 toggle really reached the pushed route — without '
              'this the test could pass without rebuilding anything',
        );
      });

      testWidgets('SettingsScreen.initial is the press-time snapshot: the '
          'pre-fill does not drift when the provider moves after the press', (
        tester,
      ) async {
        await tester.runAsync(wireUp);
        await pumpApp(tester);

        expect(
          conn.config,
          cfg,
          reason: 'precondition: the controller holds the press-time value',
        );
        await openServerSettings(tester);
        expect(
          settingsScreen(tester).initial,
          cfg,
          reason: 'the eager press-time read produced the captured value',
        );

        // Move the provider AFTER the push, then re-run the builder: a builder
        // that still resolved the pre-fill live would drift to the new value
        // (a `context.read` there would instead throw — see the test above).
        await tester.runAsync(() async {
          await conn.connectTo(otherCfg);
          await Future<void>.delayed(const Duration(milliseconds: 60));
        });
        expect(conn.config, otherCfg, reason: 'the provider really moved on');
        await unmountNowPlaying(tester);
        await toggleTheme(tester);

        expect(tester.takeException(), isNull);
        expect(
          settingsScreen(tester).initial,
          cfg,
          reason: 'the route keeps its press-time snapshot',
        );
      });
    },
  );

  group('#78 behaviour is unchanged for a real tap (AC 2)', () {
    testWidgets('connected server pre-fills host/port, and a theme toggle '
        'cascade on the pushed route stays clean', (tester) async {
      await tester.runAsync(wireUp);
      await pumpApp(tester);

      await openServerSettings(tester);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(settingsScreen(tester).initial, cfg);

      // The R-01 form is behind the Advanced tile (issue #62) — expand it and
      // read the fields the user actually sees.
      await tester.tap(find.byKey(const ValueKey('advanced-tile')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('manual-host')))
            .controller
            ?.text,
        cfg.host,
        reason: 'the host field is pre-filled from conn.config',
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('manual-port')))
            .controller
            ?.text,
        cfg.port.toString(),
      );

      await toggleTheme(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('with no live connection config the saved SettingsStore '
        'config is the fallback', (tester) async {
      await tester.runAsync(() => wireUp(saved: savedCfg, connect: false));
      await pumpApp(tester);

      expect(conn.config, isNull, reason: 'fallback leg is in play');
      await openServerSettings(tester);
      expect(settingsScreen(tester).initial, savedCfg);
      await toggleTheme(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(settingsScreen(tester).initial, savedCfg);
    });
  });
}
