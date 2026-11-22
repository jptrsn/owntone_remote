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
import 'package:owntone_remote/src/queue/queue_item.dart';
import 'package:owntone_remote/src/rating/rating_controller.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:owntone_remote/src/settings/theme_preference.dart';
import 'package:owntone_remote/src/ui/app_drawer.dart';
import 'package:owntone_remote/src/ui/browse_rows.dart';
import 'package:owntone_remote/src/ui/browse_screens.dart';
import 'package:owntone_remote/src/ui/connection_banner.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';
import 'package:owntone_remote/src/ui/outputs_screen.dart';
import 'package:owntone_remote/src/ui/queue_screen.dart';
import 'package:owntone_remote/src/ui/settings_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// R-22 (issue #45, N-01, frozen spec `.ai-dlc/night-2026-11-19/issues/45.md`):
/// the persistent bottom mini transport bar — presence on the pushed
/// screens, absence when stopped, transport presses routed to
/// PlayerController (NEVER `QueueController.playUris` — the issue-#21
/// `clear=true` lesson), metadata tap → `showNowPlaying`, row taps firing
/// with the bar shown, offline inertness, and the tooltips + semantics
/// labels ReTune lacks.
const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

const _miniPlayer = Key('mini-player');
const _miniMetadata = Key('mini-metadata');
const _miniMetadataSemantics = Key('mini-metadata-semantics');
const _miniPrevious = Key('mini-previous');
const _miniPlayPause = Key('mini-play-pause');
const _miniNext = Key('mini-next');

/// Captures every transport press (the frozen repro's "captured call"
/// requirement — prev/next/play/pause must land on PlayerController).
class _RecordingPlayer extends PlayerController {
  _RecordingPlayer({required super.connection});

  int playCalls = 0;
  int pauseCalls = 0;
  int nextCalls = 0;
  int previousCalls = 0;

  @override
  Future<void> play() {
    playCalls++;
    return super.play();
  }

  @override
  Future<void> pause() {
    pauseCalls++;
    return super.pause();
  }

  @override
  Future<void> next() {
    nextCalls++;
    return super.next();
  }

  @override
  Future<void> previous() {
    previousCalls++;
    return super.previous();
  }
}

/// Captures the two forbidden/decoy queue calls: `playUris` (must never be
/// reached from the bar — its add carries `clear=true`, issue #21) and
/// `skipToQueueItem` (row taps must still fire through the bar).
class _RecordingQueue extends QueueController {
  _RecordingQueue({required super.connection});

  int playUrisCalls = 0;
  int skipCalls = 0;

  @override
  Future<bool> playUris(List<String> uris) {
    playUrisCalls++;
    return Future.value(false);
  }

  @override
  Future<bool> skipToQueueItem(QueueItem item) {
    skipCalls++;
    return Future.value(true);
  }
}

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
  late _RecordingPlayer player;
  late _RecordingQueue queue;
  late OutputsController outputs;
  late RatingController rating;
  late SettingsStore store;
  bool serverDown = false;

  /// `'pause'` / `'play'` / `'stop'` for the `/api/player` fixture.
  String playerState = 'pause';

  /// Rows served by `/api/queue` (also feeds `id=now_playing` → items.first).
  int queueItemCount = 1;

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
        return jsonResponse(o, {'state': playerState, 'volume': 60});
      case '/api/queue':
        return jsonResponse(o, {
          'version': 1,
          'count': queueItemCount,
          'items': [
            for (var i = 0; i < queueItemCount; i++)
              {
                'id': 'q$i',
                'item_id': 100 + i,
                'title': 'Test Item',
                'artist': 'Artist 1',
                'album': 'Album 1',
                'lyrics': '',
                'art_url': '',
                'length_ms': 100000,
                'uri': 'library:track:${100 + i}',
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
    player = _RecordingPlayer(connection: conn);
    await player.init();
    outputs = OutputsController(connection: conn);
    await outputs.init();
    queue = _RecordingQueue(connection: conn);
    await queue.init();
    rating = RatingController(connection: conn, player: player);
    await rating.init();
    store = SettingsStore(await SharedPreferences.getInstance());
    await conn.connectTo(_cfg);
    await Future<void>.delayed(const Duration(milliseconds: 60));
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

  Future<void> pumpApp(
    WidgetTester tester,
    Widget home, {
    FakeViewPadding bottomInset = FakeViewPadding.zero,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    tester.view.padding = bottomInset;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
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

  group('R-22 presence / visibility', () {
    testWidgets('R-22 bar content clears a non-zero bottom window inset '
        '(PR #57 review major: Scaffold gives bottomNavigationBar children '
        'no SafeArea — buttons sat under the system nav strip; device dump '
        'showed bar bottom at the 2400-px screen edge)', (tester) async {
      await tester.runAsync(wireUp);
      // dpr 3.0 => 144 physical px = 48 logical px of system nav.
      await pumpApp(
        tester,
        const LibraryHomeScreen(),
        bottomInset: const FakeViewPadding(bottom: 144),
      );
      expect(find.byKey(const ValueKey('mini-player')), findsOneWidget);
      expect(
        tester.getBottomLeft(find.byKey(const ValueKey('mini-play-pause'))).dy,
        lessThanOrEqualTo(800 - 48 + 1),
      );
    });

    testWidgets(
      'R-22 bar is present on Library/Queue/Outputs/Settings with a fake '
      'current item (paused) — two-line metadata + the three transport '
      'buttons',
      (tester) async {
        await tester.runAsync(wireUp);
        for (final screen in <Widget>[
          const LibraryHomeScreen(),
          const QueueScreen(),
          const OutputsScreen(),
          SettingsScreen(initial: _cfg),
        ]) {
          await pumpApp(tester, screen);
          expect(
            find.byKey(_miniPlayer),
            findsOneWidget,
            reason: '${screen.runtimeType} must pin the mini transport bar',
          );
          // Scaffold lays out bottomNavigationBar with LOOSE constraints —
          // a Column in the bar must not default to MainAxisSize.max (that
          // mutation makes the bar 800 px tall and the body zero-height).
          final barSize = tester.getSize(find.byKey(_miniPlayer));
          expect(
            barSize.height,
            lessThan(120),
            reason:
                '${screen.runtimeType}: the bar is a compact strip, '
                'not a full-screen layer',
          );
          expect(
            find.descendant(
              of: find.byKey(_miniPlayer),
              matching: find.text('Test Item'),
            ),
            findsOneWidget,
            reason: 'line 1 = title',
          );
          expect(
            find.descendant(
              of: find.byKey(_miniPlayer),
              matching: find.text('Artist 1 - Album 1'),
            ),
            findsOneWidget,
            reason: 'line 2 = "artist - album"',
          );
          expect(find.byKey(_miniPrevious), findsOneWidget);
          expect(find.byKey(_miniPlayPause), findsOneWidget);
          expect(find.byKey(_miniNext), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        // PR #57 review (minor): the spec's OTHER half — "every main
        // screen EXCEPT Now Playing" — was device-row-only until now.
        await pumpApp(tester, const NowPlayingScreen());
        expect(
          find.byKey(_miniPlayer),
          findsNothing,
          reason: 'Now Playing must never host the mini bar (R-22)',
        );
      },
    );

    testWidgets(
      'R-22 bar is ABSENT when nowPlaying == null (stopped) — the dead-'
      'transport simplification (ReTune keeps dead buttons; we do not)',
      (tester) async {
        playerState = 'stop';
        await tester.runAsync(wireUp);
        await pumpApp(tester, const LibraryHomeScreen());
        expect(conn.phase, ConnectionPhase.connected);
        expect(player.player?.isStopped, isTrue);
        expect(player.nowPlaying, isNull, reason: 'fixture is stopped');
        expect(
          find.byKey(_miniPlayer),
          findsNothing,
          reason: 'R-22: hidden when stopped / no current item',
        );
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('R-22 transport routing (captured calls)', () {
    testWidgets(
      'R-22 while PLAYING the play/pause button shows the pause control and '
      'presses call PlayerController.pause — and NEVER '
      'QueueController.playUris (issue-#21 clear=true lesson)',
      (tester) async {
        playerState = 'play';
        await tester.runAsync(wireUp);
        await pumpApp(tester, const LibraryHomeScreen());
        expect(
          find.descendant(
            of: find.byKey(_miniPlayPause),
            matching: find.byIcon(Icons.pause),
          ),
          findsOneWidget,
          reason: 'isPlaying → pause control (same mapping as controlsFor)',
        );
        await tester.tap(find.byKey(_miniPlayPause));
        await tester.pumpAndSettle();
        expect(
          player.pauseCalls,
          1,
          reason: 'pause routed to PlayerController',
        );
        expect(player.playCalls, 0);
        expect(
          queue.playUrisCalls,
          0,
          reason:
              'the bar must NEVER call playUris (clear=true replaces '
              'the queue — the issue-#21 defect)',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R-22 while PAUSED the play/pause button shows the play control and '
      'presses call PlayerController.play (never pause, never playUris)',
      (tester) async {
        playerState = 'pause';
        await tester.runAsync(wireUp);
        await pumpApp(tester, const LibraryHomeScreen());
        expect(
          find.descendant(
            of: find.byKey(_miniPlayPause),
            matching: find.byIcon(Icons.play_arrow),
          ),
          findsOneWidget,
          reason: 'not playing → play control (same mapping as controlsFor)',
        );
        await tester.tap(find.byKey(_miniPlayPause));
        await tester.pumpAndSettle();
        expect(player.playCalls, 1);
        expect(player.pauseCalls, 0);
        expect(queue.playUrisCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R-22 prev/next presses route to PlayerController.previous/next '
      '(captured) — never playUris (device-withheld proof)',
      (tester) async {
        playerState = 'pause';
        await tester.runAsync(wireUp);
        await pumpApp(tester, const LibraryHomeScreen());
        await tester.tap(find.byKey(_miniPrevious));
        await tester.tap(find.byKey(_miniNext));
        await tester.pumpAndSettle();
        expect(player.previousCalls, 1, reason: 'previous → PlayerController');
        expect(player.nextCalls, 1, reason: 'next → PlayerController');
        expect(player.playCalls, 0);
        expect(player.pauseCalls, 0);
        expect(queue.playUrisCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('R-22 metadata zone + layers', () {
    testWidgets(
      'R-22 metadata-zone tap pops to the Now Playing root (exactly one NP '
      'route — showNowPlaying, not a push)',
      (tester) async {
        playerState = 'pause';
        await tester.runAsync(wireUp);
        await pumpApp(tester, const NowPlayingScreen());
        expect(observer.depth, 1, reason: 'root Now Playing');
        await openDrawer(tester, NowPlayingScreen);
        await tester.tap(drawerTile(DrawerDestination.library));
        await tester.pumpAndSettle();
        expect(find.byType(LibraryHomeScreen), findsOneWidget);
        expect(observer.depth, 2);
        expect(find.byKey(_miniPlayer), findsOneWidget);

        await tester.tap(find.byKey(_miniMetadata));
        await tester.pumpAndSettle();
        expect(find.byType(LibraryHomeScreen), findsNothing);
        expect(
          observer.depth,
          1,
          reason:
              'popUntil(isFirst): back to the single NP root, no '
              'duplicate route stacked',
        );
        expect(find.byType(NowPlayingScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R-22 list row taps still fire with the bar shown — Library row '
      'pushes its screen (bar is its own layer, no tap stealing)',
      (tester) async {
        playerState = 'pause';
        await tester.runAsync(wireUp);
        await pumpApp(tester, const LibraryHomeScreen());
        expect(find.byKey(_miniPlayer), findsOneWidget);
        await tester.tap(find.widgetWithText(BrowseRow, 'Artists'));
        await tester.pumpAndSettle();
        expect(
          find.byType(ArtistsScreen),
          findsOneWidget,
          reason: 'row tap navigated with the bar visible',
        );
        expect(find.byKey(_miniPlayer), findsOneWidget);
        expect(player.playCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R-22 list row taps still fire with the bar shown — Queue row tap '
      'reaches skipToQueueItem (issue #21 in-place skip), never playUris',
      (tester) async {
        playerState = 'pause';
        await tester.runAsync(wireUp);
        await pumpApp(tester, const QueueScreen());
        expect(find.byKey(_miniPlayer), findsOneWidget);
        await tester.tap(
          // R-23 (issue #46) made the queue list a ReorderableListView —
          // the R-22 finding (rows must still receive taps with the bar
          // shown) follows the list widget, not its class name.
          find.descendant(
            of: find.byType(ReorderableListView),
            matching: find.text('Test Item'),
          ),
        );
        await tester.pump();
        expect(
          queue.skipCalls,
          1,
          reason:
              'queue row tap still reaches skipToQueueItem '
              '(issue #21 in-place skip) with the bar shown',
        );
        expect(queue.playUrisCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R-22 the bar is pinned while the list scrolls (own layer, not a '
      'list footer)',
      (tester) async {
        queueItemCount = 12;
        playerState = 'pause';
        await tester.runAsync(wireUp);
        await pumpApp(tester, const QueueScreen());
        expect(find.byKey(_miniPlayer), findsOneWidget);
        final before = tester.getTopLeft(find.byKey(_miniPlayer));
        // (R-23 swapped QueueScreen's ListView for a ReorderableListView;
        // a quick pan on a row body scrolls it — drag needs a hold.)
        await tester.drag(
          find.byType(ReorderableListView),
          const Offset(0, -400),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(_miniPlayer),
          findsOneWidget,
          reason: 'R-22: the bar must not scroll away',
        );
        expect(
          tester.getTopLeft(find.byKey(_miniPlayer)),
          before,
          reason: 'the bar stays pinned at the bottom as the list scrolls',
        );
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('R-22 offline contract + a11y', () {
    testWidgets(
      'R-22 offline → transport inert: all three buttons disabled, taps do '
      'nothing, the ConnectionBanner coexists above the bar',
      (tester) async {
        playerState = 'pause';
        await tester.runAsync(wireUp);
        await pumpApp(tester, const LibraryHomeScreen());
        expect(find.byKey(_miniPlayer), findsOneWidget);
        await tester.runAsync(dropServer);
        await tester.pump();
        expect(conn.phase, ConnectionPhase.offline, reason: 'fixture offline');

        expect(
          find.byType(ConnectionBanner),
          findsOneWidget,
          reason:
              'the offline banner shows while the bar stays (banner '
              'above the bar — different Scaffold layers)',
        );
        expect(
          find.byKey(_miniPlayer),
          findsOneWidget,
          reason: 'last-known item keeps the bar; it goes inert, not away',
        );
        for (final key in [_miniPrevious, _miniPlayPause, _miniNext]) {
          expect(
            tester.widget<IconButton>(find.byKey(key)).onPressed,
            isNull,
            reason: 'R-22: $key is inert while offline',
          );
        }
        await tester.tap(find.byKey(_miniPlayPause), warnIfMissed: false);
        await tester.pump();
        expect(player.pauseCalls, 0, reason: 'offline tap fired nothing');
        expect(player.playCalls, 0);
        expect(queue.playUrisCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('R-22 all three buttons carry tooltips AND semantics labels '
        '(ReTune unlabeled ImageButtons — the a11y gap is not copied)', (
      tester,
    ) async {
      // Playing: the button offers the pause control (the mapping tests
      // pin both directions; here all three labels land at once).
      playerState = 'play';
      await tester.runAsync(wireUp);
      await pumpApp(tester, const LibraryHomeScreen());
      final semantics = tester.ensureSemantics();

      // Tooltips.
      expect(find.byTooltip('Previous'), findsOneWidget);
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Next'), findsOneWidget);

      // Semantics labels (the Icon-level label each button exposes).
      for (final (key, icon, label) in <(Key, IconData, String)>[
        (_miniPrevious, Icons.skip_previous, 'Previous'),
        (_miniPlayPause, Icons.pause, 'Pause'),
        (_miniNext, Icons.skip_next, 'Next'),
      ]) {
        expect(
          tester
              .getSemantics(
                find.descendant(
                  of: find.byKey(key),
                  matching: find.byIcon(icon),
                ),
              )
              .label,
          contains(label),
          reason: 'R-22: the $label button announces itself',
        );
      }

      // The metadata zone is a labelled button too.
      final node = tester.getSemantics(find.byKey(_miniMetadataSemantics));
      expect(node.label, contains('Open now playing'));
      expect(node.flagsCollection.isButton, isTrue);

      semantics.dispose();
      expect(tester.takeException(), isNull);
    });
  });
}
