import 'dart:ui' show Tristate;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:owntone_remote/src/ui/browse_rows.dart';
import 'package:owntone_remote/src/ui/browse_screens.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';
import 'package:owntone_remote/src/ui/outputs_screen.dart';
import 'package:owntone_remote/src/ui/queue_screen.dart';
import 'package:owntone_remote/src/ui/settings_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// R-21 (issue #44, `docs/REQUIREMENTS.md` "Drawer navigation", frozen
/// spec `.ai-dlc/night-2026-11-19/issues/44.md`): the navigation drawer —
/// hamburger on every main screen, the three sections + Connected To
/// header, `popUntil(isFirst)`-then-push landing (stack-depth regression),
/// `Semantics(selected:)` on the selected destination, back-closes-drawer-
/// first, and the offline inert-destinations contract.
const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

/// The `/api/config` display name the fixture serves (the drawer header's
/// identity line — R-21 `Connected To — server name`).
const _serverName = 'Test Music';

/// Counts live routes (R-21's stack-depth contract is asserted on this —
/// `popUntil(isFirst)` then push must leave exactly [root, target]).
class _DepthObserver extends NavigatorObserver {
  int depth = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    depth++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    depth--;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    depth--;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late OutputsController outputs;
  late QueueController queue;
  late RatingController rating;
  late SettingsStore store;
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
          'library_name': _serverName,
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

  /// Controllers + real-timer waiting inside `tester.runAsync` (the fake
  /// WS/backoff timers need the real zone — pattern from
  /// outputs_appbar_test / now_playing_screen_test).
  Future<void> wireUp({bool connect = true}) async {
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
          // A reconnect attempt made while the server is down must fail
          // its handshake too (now_playing_screen_test pattern) — a
          // silently-succeeding channel would flip the phase back to
          // connected and the offline assertions would race it.
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
    if (connect) {
      await conn.connectTo(_cfg);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

  Future<void> dropServer() async {
    serverDown = true;
    channels.last.serverClose();
    await Future<void>.delayed(const Duration(milliseconds: 150));
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

  late _DepthObserver observer;

  Future<void> pumpApp(WidgetTester tester, Widget home) async {
    // Realistic phone viewport (the other screen tests pin 360 logical px;
    // the binding default of 800x600 @3.0 dpr = 266 logical px is not a
    // supported surface and would fail the app bar fit contract).
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    observer = _DepthObserver();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<SettingsStore>.value(value: store),
          ChangeNotifierProvider<ThemePreference>.value(
            value: ThemePreference(store),
          ),
          ChangeNotifierProvider<ConnectionController>.value(value: conn),
          ChangeNotifierProvider<PlayerController>.value(value: player),
          ChangeNotifierProvider<OutputsController>.value(value: outputs),
          ChangeNotifierProvider<QueueController>.value(value: queue),
          ChangeNotifierProvider<RatingController>.value(value: rating),
        ],
        child: MaterialApp(home: home, navigatorObservers: [observer]),
      ),
    );
    await settle(tester);
  }

  /// Tap the screen's own hamburger (scoped to [of] so a behind-route
  /// button can never be hit).
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

  group('R-21 hamburger + drawer contract', () {
    testWidgets('R-21 hamburger opens the drawer on every main screen '
        '(NP/Library/Queue/Outputs/Settings/Albums)', (tester) async {
      await tester.runAsync(wireUp);
      for (final screen in <Widget>[
        const NowPlayingScreen(),
        const LibraryHomeScreen(),
        const QueueScreen(),
        const OutputsScreen(),
        SettingsScreen(initial: _cfg),
        const AlbumsScreen(),
      ]) {
        await pumpApp(tester, screen);
        expect(
          find.byType(DrawerButton),
          findsWidgets,
          reason: '${screen.runtimeType} must carry a hamburger',
        );
        await openDrawer(tester, screen.runtimeType);
        expect(
          find.byType(Drawer),
          findsOneWidget,
          reason: 'the hamburger opens the drawer on ${screen.runtimeType}',
        );
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('R-21 drawer content: Connected To header (library_name from '
        '/api/config) + Playing/Library/Settings sections with their rows', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpApp(tester, const NowPlayingScreen());
      await openDrawer(tester, NowPlayingScreen);

      expect(
        conn.serverName,
        _serverName,
        reason: 'ConnectionController exposes /api/config library_name',
      );
      expect(find.text('Connected To — $_serverName'), findsOneWidget);
      // Scoped to the Drawer (the NP screen behind carries its own
      // Library/Queue entry buttons). 'Playing' is unique to its section
      // header; 'Library'/'Settings' each appear once as the section
      // label and once as their own destination row.
      Finder inDrawer(Finder f) =>
          find.descendant(of: find.byType(Drawer), matching: f);
      expect(inDrawer(find.text('Playing')), findsOneWidget);
      expect(inDrawer(find.text('Library')), findsNWidgets(2));
      expect(inDrawer(find.text('Settings')), findsNWidgets(2));
      for (final dest in DrawerDestination.values) {
        expect(
          drawerTile(dest),
          findsOneWidget,
          reason: 'the ${dest.name} destination row is present',
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('PR #56 review (LOW): idle phase — drawer header must not '
        'claim a connection ("Not connected", never "Connected To — …")', (
      tester,
    ) async {
      await tester.runAsync(() => wireUp(connect: false));
      expect(conn.phase, ConnectionPhase.idle);
      await pumpApp(tester, const LibraryHomeScreen());
      await openDrawer(tester, LibraryHomeScreen);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.textContaining('Connected To'), findsNothing);
    });

    testWidgets('PR #70 review (LOW): POST-disconnect idle keeps _config — '
        'the motivating reachable state (host non-null, phase idle) still '
        'renders "Not connected" (pre-gate code showed the stale host)', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      expect(
        conn.serverName,
        'Test Music',
        reason:
            'precondition: host is non-null (the pre-gate code '
            'rendered it in the idle header after disconnect)',
      );
      await pumpApp(tester, const LibraryHomeScreen());
      await tester.runAsync(() async => conn.disconnect());
      expect(conn.phase, ConnectionPhase.idle);
      await settle(tester);
      await openDrawer(tester, LibraryHomeScreen);
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.textContaining('Connected To'), findsNothing);
    });
  });

  group('R-21 popUntil-then-push (stack depth, no duplicates)', () {
    testWidgets('R-21 Queue from two-deep browse lands depth 2 (root + queue), '
        'pops the browse stack, no duplicates, back returns to root', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpApp(tester, const NowPlayingScreen());
      expect(observer.depth, 1, reason: 'root Now Playing');

      // Deep: NP → Library home (drawer) → Artists (row tap).
      await openDrawer(tester, NowPlayingScreen);
      await tester.tap(drawerTile(DrawerDestination.library));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryHomeScreen), findsOneWidget);
      await tester.tap(find.widgetWithText(BrowseRow, 'Artists'));
      await tester.pumpAndSettle();
      expect(find.byType(ArtistsScreen), findsOneWidget);
      expect(observer.depth, 3, reason: 'root + library + artists');

      // Drawer from the two-deep screen → Queue.
      await openDrawer(tester, ArtistsScreen);
      await tester.tap(drawerTile(DrawerDestination.queue));
      await tester.pumpAndSettle();

      // Frozen repro: stack of depth 2 (root NP + queue), NOT duplicates.
      expect(find.byType(QueueScreen), findsOneWidget);
      expect(
        find.byType(ArtistsScreen),
        findsNothing,
        reason: 'popUntil(isFirst) popped the browse stack',
      );
      expect(
        find.byType(LibraryHomeScreen),
        findsNothing,
        reason: 'popUntil(isFirst) popped the browse stack',
      );
      expect(observer.depth, 2, reason: '[root, queue] only');

      // Back from Queue lands on the root (not a duplicate / the old
      // two-deep screens).
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(QueueScreen), findsNothing);
      expect(observer.depth, 1, reason: 'one back = back to root');
      expect(
        find.text('Queue · 1'),
        findsOneWidget,
        reason: 'the root Now Playing entry row renders again',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'R-21 tapping the current destination from its own drawer does not '
      'stack a duplicate (Queue → Queue stays depth 2)',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpApp(tester, const NowPlayingScreen());
        await openDrawer(tester, NowPlayingScreen);
        await tester.tap(drawerTile(DrawerDestination.queue));
        await tester.pumpAndSettle();
        expect(observer.depth, 2);

        await openDrawer(tester, QueueScreen);
        await tester.tap(drawerTile(DrawerDestination.queue));
        await tester.pumpAndSettle();
        expect(
          find.byType(QueueScreen),
          findsOneWidget,
          reason: 'no duplicate Queue screen stacked',
        );
        expect(
          observer.depth,
          2,
          reason: 'popUntil + one push: the stack never grows',
        );
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('R-21 selected destination carries Semantics(selected:)', () {
    testWidgets(
      'R-21 on the Queue screen the Queue row is selected, Now Playing is '
      'not; on Now Playing the Now Playing row is selected',
      (tester) async {
        await tester.runAsync(wireUp);
        final semantics = tester.ensureSemantics();

        await pumpApp(tester, const QueueScreen());
        await openDrawer(tester, QueueScreen);
        expect(
          tester
              .getSemantics(drawerTile(DrawerDestination.queue))
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
          reason: 'R-21: the selected destination announces as selected',
        );
        expect(
          tester
              .getSemantics(drawerTile(DrawerDestination.nowPlaying))
              .flagsCollection
              .isSelected,
          Tristate.isFalse,
        );
        semantics.dispose();
      },
    );

    testWidgets(
      'R-21 Now Playing route: the Now Playing row carries the selected '
      'state and Queue does not',
      (tester) async {
        await tester.runAsync(wireUp);
        final semantics = tester.ensureSemantics();
        await pumpApp(tester, const NowPlayingScreen());
        await openDrawer(tester, NowPlayingScreen);
        expect(
          tester
              .getSemantics(drawerTile(DrawerDestination.nowPlaying))
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );
        expect(
          tester
              .getSemantics(drawerTile(DrawerDestination.queue))
              .flagsCollection
              .isSelected,
          Tristate.isFalse,
        );
        semantics.dispose();
      },
    );
  });

  group('R-21 back closes the drawer first', () {
    testWidgets(
      'R-21 back with the drawer open closes the drawer without leaving '
      'the screen; the next back pops it',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpApp(tester, const NowPlayingScreen());
        await openDrawer(tester, NowPlayingScreen);
        await tester.tap(drawerTile(DrawerDestination.queue));
        await tester.pumpAndSettle();
        expect(observer.depth, 2);

        await openDrawer(tester, QueueScreen);
        final scaffold = tester.state<ScaffoldState>(
          find
              .descendant(
                of: find.byType(QueueScreen),
                matching: find.byType(Scaffold),
              )
              .last,
        );
        expect(scaffold.isDrawerOpen, isTrue);

        // System back (popRoute → maybePop): the DrawerController's local-
        // history entry pops first — the screen itself must survive.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(scaffold.isDrawerOpen, isFalse, reason: 'drawer closed first');
        expect(
          find.byType(QueueScreen),
          findsOneWidget,
          reason: 'the screen was NOT popped by the drawer-closing back',
        );
        expect(observer.depth, 2);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(QueueScreen), findsNothing);
        expect(observer.depth, 1);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('R-21 offline contract', () {
    testWidgets('R-21 offline: drawer opens with the header; server-touching '
        'destinations (Queue, Library views, Outputs) are inert while Now '
        'Playing and Settings stay live', (tester) async {
      await tester.runAsync(wireUp);
      await pumpApp(tester, const NowPlayingScreen());
      await tester.runAsync(dropServer);
      await tester.pump();
      expect(conn.phase, ConnectionPhase.offline, reason: 'fixture offline');

      await openDrawer(tester, NowPlayingScreen);
      expect(
        find.text('Connected To — $_serverName'),
        findsOneWidget,
        reason: 'the header survives the drop (identity is not re-fetched)',
      );

      final semantics = tester.ensureSemantics();
      for (final inert in [
        DrawerDestination.queue,
        DrawerDestination.library,
        DrawerDestination.playlists,
        DrawerDestination.artists,
        DrawerDestination.albums,
        DrawerDestination.songs,
        DrawerDestination.genres,
        DrawerDestination.outputs,
      ]) {
        final node = tester.getSemantics(drawerTile(inert));
        expect(
          node.flagsCollection.isEnabled,
          Tristate.isFalse,
          reason: 'R-21: $inert is inert while offline',
        );
      }
      for (final live in [
        DrawerDestination.nowPlaying,
        DrawerDestination.settings,
      ]) {
        expect(
          tester.getSemantics(drawerTile(live)).flagsCollection.isEnabled,
          Tristate.isTrue,
          reason: '$live is not server-touching — stays live',
        );
      }
      semantics.dispose();

      // Behavioural half: tapping an inert tile navigates nowhere.
      final depthBefore = observer.depth;
      await tester.tap(
        drawerTile(DrawerDestination.queue),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(observer.depth, depthBefore, reason: 'inert tap did nothing');

      // And a live one does (contrast case for the inert assertion).
      await tester.tap(drawerTile(DrawerDestination.settings));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(observer.depth, depthBefore + 1);
      expect(tester.takeException(), isNull);
    });
  });
}
