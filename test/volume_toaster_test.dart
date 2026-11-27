import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/main.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/audio/mirror_handler.dart';
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
import 'package:owntone_remote/src/ui/volume_toaster.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// Issue #92 (ReTune capture-22 parity, `docs/retune-capture/22-volume-
/// toaster/notes.md`): the transient volume toaster on rocker-driven
/// server steps — on every screen EXCEPT the NowPlaying root route, whose
/// 0–100 slider stays the indicator. Tests derive from the issue's ACs and
/// cite R-06/D20 (rocker→server while foregrounded), R-14 (step magnitude)
/// and the capture-22 reference (center band, ~1–2.5 s auto-hide, no a11y
/// node). Harness: production `OwntoneRemoteApp` (so the layer comes from
/// main.dart's `MaterialApp.builder`), fakes for the wire
/// (`ScriptedAdapter` + `FakeWsChannel` — no network), the real
/// [MirrorAudioHandler.handleVolumeKey] as the rocker entry point, and the
/// real [AppDrawer] for navigation (app_drawer_test pattern).
const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

const _barKey = ValueKey('volume-toaster');
const _progressKey = ValueKey('volume-toaster-progress');
const _levelKey = ValueKey('volume-toaster-level');
const _miniPlayerKey = ValueKey('mini-player');
const _miniMetadataKey = ValueKey('mini-metadata');

/// Stateful fixture: GETs serve it, the volume PUTs mutate it (relative to
/// its own state, like the shared server — AC-1's assertions stay
/// relative too).
class Fixture {
  Fixture({this.volume = 75, this.queueItems = 1});

  int volume;
  int queueItems;

  /// Set before wiring to hold `GET /api/player` open — the
  /// connected-but-no-first-slice state (plan A-4). Release via
  /// [playerGate].
  bool blockPlayerGet = false;
  final Completer<void> playerGate = Completer<void>();

  Map<String, dynamic> playerJson() => {
    'state': 'pause',
    'repeat': 'off',
    'consume': false,
    'shuffle': false,
    'volume': volume,
    'item_id': 100,
    'item_length_ms': 100000,
    'item_progress_ms': 1000,
  };

  Map<String, dynamic> queueJson() => {
    'version': 1,
    'count': queueItems,
    'items': [
      for (var i = 0; i < queueItems; i++)
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
  };

  FutureOr<Response<dynamic>> handle(RequestOptions o) async {
    switch (o.uri.path) {
      case '/api/config':
        return jsonResponse(o, {
          'websocket_port': 3688,
          'version': '29.3',
          'library_name': 'Test Music',
        });
      case '/api/player':
        if (blockPlayerGet) await playerGate.future;
        return jsonResponse(o, playerJson());
      case '/api/queue':
        return jsonResponse(o, queueJson());
      case '/api/outputs':
        return jsonResponse(o, {
          'outputs': [
            {
              'id': 'a',
              'name': 'Alpha',
              'type': 'AirPlay',
              'selected': true,
              'has_password': false,
              'needs_auth_key': false,
              'volume': 50,
            },
          ],
        });
      case '/api/player/volume':
        if (o.method == 'PUT') {
          final q = o.queryParameters.map((k, v) => MapEntry(k, v.toString()));
          if (q['volume'] != null) {
            volume = int.parse(q['volume']!).clamp(0, 100);
          } else if (q['step'] != null) {
            volume = (volume + int.parse(q['step']!)).clamp(0, 100);
          }
          return Response(requestOptions: o, statusCode: 204);
        }
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
    }
    return jsonResponse(o, <String, dynamic>{});
  }
}

/// Captures queue row taps (the AC-5 pass-through proof — the row's action
/// must fire with the bar on top of it).
class _RecordingQueue extends QueueController {
  _RecordingQueue({required super.connection});

  int skipCalls = 0;

  @override
  Future<bool> skipToQueueItem(QueueItem item) {
    skipCalls++;
    return Future.value(true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Fixture fx;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late OutputsController outputs;
  late _RecordingQueue queue;
  late RatingController rating;
  late SettingsStore store;
  late MirrorAudioHandler handler;
  late VolumeToasterRouteObserver toaster;

  /// Controllers + the fake wire, wired like production `main()`. Real
  /// zone (`tester.runAsync`) — the WS/backoff/dio plumbing needs real
  /// async; the layer's own hide timer lands in the fake zone where the
  /// pumps control it.
  Future<void> wireUp({
    int volume = 75,
    int queueItems = 1,
    bool blockPlayerGet = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    fx = Fixture(volume: volume, queueItems: queueItems);
    fx.blockPlayerGet = blockPlayerGet;
    adapter = ScriptedAdapter(responder: fx.handle);
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
          channels.add(c);
          return c;
        },
      ),
    );
    player = PlayerController(connection: conn);
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
    // The rocker entry point: foregrounded + registered (startVolumeKeys
    // without start() — the media session mirror is not under test here,
    // and handleVolumeKey works from exactly these two flags).
    handler = MirrorAudioHandler(player, settings: store);
    handler.setAppForeground(true);
    await handler.startVolumeKeys();
  }

  tearDown(() async {
    await handler.stopVolumeKeys();
    player.dispose();
    outputs.dispose();
    rating.dispose();
    queue.dispose();
    conn.dispose();
  });

  /// The production `OwntoneRemoteApp` — MaterialApp builder + observers
  /// included (the wiring under test), with the toaster observer injected
  /// so the test can read its `depth`.
  ///
  /// [settle] false for the blocked-slice test: the NP root then renders
  /// an infinite `CircularProgressIndicator`, which never lets
  /// `pumpAndSettle` settle — the caller pumps a fixed number of frames
  /// instead.
  Future<void> pumpApp(
    WidgetTester tester,
    Widget home, {
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    toaster = VolumeToasterRouteObserver();
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
        child: OwntoneRemoteApp(home: home, toasterObserver: toaster),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
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

  Future<void> goto(
    WidgetTester tester,
    DrawerDestination dest, {
    required Type from,
  }) async {
    await openDrawer(tester, from);
    final tile = find.byKey(ValueKey('drawer-${dest.name}'));
    // Outputs/Settings sit below the DrawerHeader at the 800-px viewport —
    // without scrolling them into view the tap misses (warnIfMissed).
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  Finder bar() => find.byKey(_barKey);
  Finder barText(String level) =>
      find.descendant(of: bar(), matching: find.text(level));

  /// One rocker press through the production entry point, then let the
  /// optimistic frame + PUT + confirming refetch settle (fake-clock
  /// advance drives dio, per now_playing_screen_test's seek pattern).
  Future<void> press(WidgetTester tester, {bool raise = true}) async {
    unawaited(
      handler.handleVolumeKey(
        raise ? AndroidVolumeDirection.raise : AndroidVolumeDirection.lower,
      ),
    );
    await tester.pumpAndSettle();
  }

  List<String> volumePuts() =>
      adapter.requests.where((r) => r.contains('/api/player/volume')).toList();

  Slider volumeSlider(WidgetTester tester) => tester.widget<Slider>(
    find.byWidgetPredicate(
      (w) => w is Slider && w.min == 0 && w.max == 100,
      description: 'the 0-100 volume slider',
    ),
  );

  group('volume toaster (issue #92):', () {
    testWidgets('rocker step on Queue shows the level bar and PUTs ?step= '
        '(R-06/D20, #92 AC-1)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpApp(tester, const NowPlayingScreen());
      await goto(tester, DrawerDestination.queue, from: NowPlayingScreen);
      expect(toaster.depth, 2);

      await press(tester);
      expect(
        adapter.requests,
        contains('PUT /api/player/volume?step=5'),
        reason: 'R-06/D20 rocker step of the default R-14 magnitude 5',
      );
      expect(bar(), findsOneWidget);
      expect(barText('80'), findsOneWidget, reason: '75+5 optimistic level');
      expect(
        tester.widget<LinearProgressIndicator>(find.byKey(_progressKey)).value,
        0.8,
      );
      final center = tester.getCenter(bar());
      expect(
        center.dy,
        inInclusiveRange(300, 500),
        reason:
            'center band — capture-22 y≈900–1500 device px = 300–500 '
            'logical px on the 800-px viewport',
      );
      expect(center.dx, inInclusiveRange(140, 220));

      // R-14: the step magnitude follows the setting on the next press.
      await store.saveRockerStep(2);
      await press(tester);
      expect(adapter.requests, contains('PUT /api/player/volume?step=2'));
      expect(barText('82'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2)); // drain the timer
    });

    testWidgets(
      'bar auto-hides without interaction within the capture-22 window '
      '(#92 AC-3)',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpApp(tester, const NowPlayingScreen());
        await goto(tester, DrawerDestination.queue, from: NowPlayingScreen);

        handler.handleVolumeKey(AndroidVolumeDirection.raise);
        await tester.pump(); // the optimistic-notify frame (bar appears)
        expect(bar(), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        expect(bar(), findsOneWidget, reason: '1.0 s < the 1.5 s auto-hide');
        await tester.pump(const Duration(seconds: 1));
        expect(
          bar(),
          findsNothing,
          reason:
              '2.0 s > auto-hide, ≤3 s — inside the ~1–2.5 s capture-22 '
              'window, no tap involved',
        );
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'repeated press resets the timer and updates the level in place — '
      'one bar, newest level (#92 AC-3)',
      (tester) async {
        await tester.runAsync(() => wireUp(volume: 50));
        await pumpApp(tester, const NowPlayingScreen());
        await goto(tester, DrawerDestination.queue, from: NowPlayingScreen);

        handler.handleVolumeKey(AndroidVolumeDirection.raise);
        await tester.pump();
        expect(bar(), findsOneWidget);
        expect(barText('55'), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 400));
        handler.handleVolumeKey(AndroidVolumeDirection.raise);
        await tester.pump();
        expect(
          bar(),
          findsOneWidget,
          reason: 'still exactly ONE bar — never a stack',
        );
        expect(barText('60'), findsOneWidget, reason: 'updated in place');
        expect(barText('55'), findsNothing);

        await tester.pump(const Duration(milliseconds: 1000));
        expect(
          bar(),
          findsOneWidget,
          reason: '1.0 s after the LAST press — the timer was reset',
        );
        await tester.pump(const Duration(milliseconds: 1000));
        expect(bar(), findsNothing, reason: '2.0 s after the last press');
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'offline press issues nothing and shows no bar and schedules no '
      'timer (R-06, #92 AC-4)',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpApp(tester, const NowPlayingScreen());

        // Disconnect at the NP ROOT first: disconnecting while a route is
        // pushed crashes on a pre-existing framework assertion (banner
        // insertion under an offstage-covered route — reproduced with a
        // plain MaterialApp, unrelated to this layer; see session log).
        // The queue drawer tile is inert while disconnected (R-21), so the
        // depth-2 route is reached by the same Navigator.push the drawer
        // performs when enabled.
        await tester.runAsync(() async => conn.disconnect());
        await tester.pumpAndSettle();
        expect(conn.isConnected, isFalse);

        final context = tester.element(find.byType(NowPlayingScreen));
        Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const QueueScreen()));
        await tester.pumpAndSettle();
        expect(find.byType(QueueScreen), findsOneWidget);
        expect(toaster.depth, 2);

        final seqBefore = player.volumeStepSeq;
        unawaited(handler.handleVolumeKey(AndroidVolumeDirection.raise));
        await tester.pump();
        expect(player.volumeStepSeq, seqBefore, reason: 'no request issued');
        expect(
          volumePuts(),
          isEmpty,
          reason:
              'the mini bar rule: offline → '
              'presses stay visually inert',
        );
        expect(bar(), findsNothing);

        await tester.pump(const Duration(seconds: 3));
        expect(bar(), findsNothing);
        // The test completing at all is the flutter_test pending-timer
        // invariant proving no hide timer was ever scheduled.
      },
    );

    testWidgets(
      'connected but no first slice: the PUT issues, no bar and no seq '
      'bump (plan A-4, #92 AC-4)',
      (tester) async {
        await tester.runAsync(() => wireUp(blockPlayerGet: true));
        expect(conn.isConnected, isTrue);
        expect(player.player, isNull, reason: 'slice held open by the gate');

        // The gated player slice makes the NP root render an infinite
        // CircularProgressIndicator → pumpAndSettle can never settle;
        // every navigation here pumps a fixed frame budget instead.
        await pumpApp(tester, const NowPlayingScreen(), settle: false);

        await tester.tap(
          find
              .descendant(
                of: find.byType(NowPlayingScreen),
                matching: find.byType(DrawerButton),
              )
              .first,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.byKey(const ValueKey('drawer-queue')));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(QueueScreen), findsOneWidget);
        expect(toaster.depth, 2);

        unawaited(handler.handleVolumeKey(AndroidVolumeDirection.raise));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(player.volumeStepSeq, 0, reason: 'no slice → no level (A-4)');
        expect(player.volumeStepLevel, isNull);
        expect(bar(), findsNothing);
        expect(
          volumePuts(),
          contains('PUT /api/player/volume?step=5'),
          reason:
              'the request itself is still issued (A-4 minimal '
              'interpretation) — only the bar is withheld',
        );

        fx.playerGate.complete();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          player.player,
          isNotNull,
          reason: 'premise: the slice really did arrive late',
        );
        expect(
          bar(),
          findsNothing,
          reason: 'the late slice must not retro-show a stale bar',
        );
      },
    );

    testWidgets(
      'NowPlaying root: no toaster, the 0-100 slider follows each step '
      '(R-06/D20, #92 AC-2)',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpApp(tester, const NowPlayingScreen());
        expect(toaster.depth, 1);
        expect(volumeSlider(tester).value, 75.0);

        await press(tester);
        expect(
          player.volumeStepSeq,
          1,
          reason:
              'the signal fires — only '
              'the route gate suppresses the overlay',
        );
        expect(
          bar(),
          findsNothing,
          reason:
              'the 0-100 slider IS the indicator on the NP root (#92 '
              'AC-2) — pinned per the issue',
        );
        expect(volumeSlider(tester).value, 80.0);
        expect(find.text('80'), findsWidgets, reason: 'the slider label');

        await press(tester);
        expect(bar(), findsNothing);
        expect(volumeSlider(tester).value, 85.0);
      },
    );

    testWidgets('the bar contributes no semantics node (#92 AC-6, capture-22 '
        'pure-Toast parity)', (tester) async {
      await tester.runAsync(wireUp);
      final handle = tester.ensureSemantics();
      await pumpApp(tester, const NowPlayingScreen());
      await goto(tester, DrawerDestination.queue, from: NowPlayingScreen);
      await press(tester);
      expect(bar(), findsOneWidget, reason: 'premise: the bar is on screen');
      expect(
        find.byKey(_levelKey),
        findsOneWidget,
        reason:
            'premise: the level Text is really painted (so its absence '
            'from the semantics tree below is meaningful, not vacuous)',
      );

      // The bar's own RenderObjects carry no semantics node (cheap first
      // line of defence — WEAK on its own: round-1 review measured these
      // still reading null while a real leak was present, which is why
      // the walk below is the contract).
      expect(
        tester.element(find.byKey(_levelKey)).renderObject!.debugSemantics,
        isNull,
        reason: 'the level label contributes no a11y node (AC-6)',
      );
      expect(
        tester.element(bar()).renderObject!.debugSemantics,
        isNull,
        reason: 'the bar container contributes no a11y node (AC-6)',
      );
      // The decisive check is the WHOLE TREE a screen reader walks, on the
      // same oracle as device row D-3 ("62 vs 62 nodes, zero delta"):
      // walk the tree with the bar visible, walk again after the
      // auto-hide, and assert the two walks are IDENTICAL — the visible
      // bar's contribution to the tree a screen reader reaches is exactly
      // the empty set. (Round-1 review found the previous exact-entry and
      // 'volume' probes vacuous: a leaked level node reads '80 80' via
      // '${label} ${value}', never '80', and nothing in the bar emits the
      // word 'volume' — removing ExcludeSemantics kept that version
      // green. The delta walk catches the leak by construction; the
      // blob-level negatives below are defence-in-depth. Round 1
      // mutation-verified: ExcludeSemantics removed ⇒ THIS test reddens.)
      // Anchored on the queue row's node (public tester.getSemantics —
      // the mini_player_test pattern) and climbed to the root each walk,
      // re-anchored so the second walk reads the post-hide tree freshly.
      List<String> walkTree() {
        final row = tester.getSemantics(find.text('Test Item').first);
        final top = row.owner?.rootSemanticsNode;
        expect(top, isNotNull, reason: 'semantics tree is attached');
        final entries = <String>[];
        var nodeCount = 0;
        bool walk(SemanticsNode node) {
          nodeCount++;
          final data = node.getSemanticsData();
          entries.add('${data.label} ${data.value}');
          node.visitChildren(walk);
          return true; // keep descending
        }

        walk(top!);
        entries.add('##nodeCount $nodeCount');
        return entries;
      }

      final withBar = walkTree();
      expect(
        withBar.length,
        greaterThanOrEqualTo(10),
        reason: 'non-vacuity: the tree is really populated',
      );
      expect(
        withBar.join('\n').toLowerCase(),
        contains('test item'),
        reason:
            'positive control + AC-5 side: queue row semantics below the '
            'layer are unaffected',
      );

      await tester.pump(const Duration(seconds: 2)); // the auto-hide fires
      expect(bar(), findsNothing, reason: 'premise: the bar is gone');
      final noBar = walkTree();
      expect(
        noBar,
        equals(withBar),
        reason:
            'AC-6 (capture-22 pure-Toast parity): the visible bar adds '
            'ZERO semantics nodes — the walk with the bar must be '
            'identical to the walk without it, entries and nodeCount '
            '(device D-3 oracle)',
      );
      // Blob-level (substring, not exact-entry) negatives: the level is
      // 80 and the Queue route carries no other '80' anywhere (the NP
      // slider that reads 80 sits OFFSTAGE under the pushed route), so a
      // leaked level node — which measured as a '80 80' entry — cannot
      // produce a false positive and cannot hide in merged text.
      final blob = noBar.join('\n').toLowerCase();
      expect(
        blob,
        isNot(contains('80')),
        reason: 'the level label contributes nothing anywhere in the tree',
      );
      expect(
        blob,
        isNot(contains('volume')),
        reason:
            'no volume text leaks either — defence-in-depth if a '
            'semanticLabel is ever added to the bar (today nothing in it '
            'emits the word, so this alone could never catch a leak)',
      );
      handle.dispose();
    });

    testWidgets(
      'bar covers Queue, Outputs, Settings and About and coexists with '
      'the mini player (#92 AC-5)',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpApp(tester, const NowPlayingScreen());

        var from = NowPlayingScreen;
        for (final (dest, screenType) in <(DrawerDestination, Type)>[
          (DrawerDestination.queue, QueueScreen),
          (DrawerDestination.outputs, OutputsScreen),
          (DrawerDestination.settings, SettingsScreen),
        ]) {
          await goto(tester, dest, from: from);
          expect(find.byType(screenType), findsOneWidget);
          expect(
            toaster.depth,
            2,
            reason:
                '$dest is a pushed route on top of the NP root '
                '(drawer destinations collapse to [root, target])',
          );
          await press(tester);
          expect(
            bar(),
            findsOneWidget,
            reason: 'the bar shows on $dest (AC-5 coverage)',
          );
          expect(
            find.byKey(_miniPlayerKey),
            findsOneWidget,
            reason: 'coexists with the mini player ($dest hosts it)',
          );
          await tester.pump(const Duration(seconds: 2)); // drain the timer
          from = screenType;
        }

        // About — pushed from Settings (depth 3).
        await tester.ensureVisible(find.byKey(const ValueKey('about-entry')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('about-entry')));
        await tester.pumpAndSettle();
        expect(toaster.depth, 3);
        await press(tester);
        expect(bar(), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
      },
    );

    testWidgets(
      'the layer never consumes taps meant for rows behind it (#92 AC-5)',
      (tester) async {
        await tester.runAsync(() => wireUp(queueItems: 12));
        await pumpApp(tester, const NowPlayingScreen());
        await goto(tester, DrawerDestination.queue, from: NowPlayingScreen);
        await press(tester);
        expect(bar(), findsOneWidget);

        final barRect = tester.getRect(bar());
        // Queue rows are Semantics→Material→InkWell rows (no ListTile —
        // those live in the popup menu); key each row off its title text.
        final titles = find.descendant(
          of: find.byType(ReorderableListView),
          matching: find.text('Test Item'),
        );
        Finder rowOf(int i) =>
            find.ancestor(of: titles.at(i), matching: find.byType(InkWell));

        final count = titles.evaluate().length;
        expect(count, greaterThanOrEqualTo(8));
        var best = 0;
        var bestD = double.infinity;
        for (var i = 0; i < count; i++) {
          final d = (tester.getCenter(rowOf(i)).dy - barRect.center.dy).abs();
          if (d < bestD) {
            bestD = d;
            best = i;
          }
        }
        final rowRect = tester.getRect(rowOf(best));
        expect(
          rowRect.contains(barRect.center),
          isTrue,
          reason:
              'premise: the bar sits ON this row — the tap below must '
              'pass through the IgnorePointer layer',
        );

        final skipBefore = queue.skipCalls;
        await tester.tap(rowOf(best));
        await tester.pumpAndSettle();
        expect(
          queue.skipCalls,
          skipBefore + 1,
          reason: 'the row received the tap with the bar over it (AC-5)',
        );
        expect(
          bar(),
          findsOneWidget,
          reason: 'bar still up — the tap passed through, not onto it',
        );
        await tester.pump(const Duration(seconds: 2));
      },
    );

    testWidgets(
      'the bar coexists with the offline banner — disconnect inside the '
      'auto-hide window keeps both on tree (#92 AC-5)',
      (tester) async {
        // semanticsEnabled: false — this test asserts the WIDGET tree,
        // and the default (true) makes every frame run flushSemantics,
        // where the PRE-EXISTING framework assertion object.dart:6723
        // (semantics child-geometry) throws on ConnectionBanner insertion
        // under a pushed route. Measured this round with the default:
        // same crash as T4's restructure (this file) — and it reproduces
        // with the bar never scheduled at all (bar unmounted, same
        // failure), i.e. the toaster layer is NOT implicated, matching
        // the build report's 'reproduced with a plain MaterialApp'
        // ASSUMPTION. Semantics for the toaster itself are pinned by the
        // AC-6 test above, which opts in explicitly.
        await tester.runAsync(wireUp);
        await pumpApp(tester, const NowPlayingScreen());
        await goto(tester, DrawerDestination.queue, from: NowPlayingScreen);

        // Schedule the bar on the optimistic-notify frame (T3's pattern —
        // NOT press()/pumpAndSettle: every settle spends fake-clock and
        // the disconnect+asserts must land inside the 1500 ms auto-hide
        // window).
        handler.handleVolumeKey(AndroidVolumeDirection.raise);
        await tester.pump();
        expect(bar(), findsOneWidget, reason: 'premise: the bar is up');

        // AC-5's 'must coexist with … the offline banner' half (the
        // mini-player half is the test above; the schedule-nothing-when-
        // offline half is the offline T4): disconnect INSIDE the 1.5 s
        // window — the Queue scaffold gains its ConnectionBanner at the
        // body top (browse_screen_scaffold.dart) while the already-
        // scheduled bar is still counting down.
        await tester.runAsync(() async => conn.disconnect());
        await tester.pump();
        expect(conn.isConnected, isFalse);
        // Scoped to the Queue route: the offstage NP root builds its own
        // ConnectionBanner (now_playing_screen.dart), so a global banner
        // finder answers 2 — the AC-5 claim is about THIS route.
        expect(
          find.descendant(
            of: find.byType(QueueScreen),
            matching: find.byType(ConnectionBanner),
          ),
          findsOneWidget,
          reason: 'the offline banner is rendered on the Queue route',
        );
        expect(
          find.descendant(
            of: find.byType(QueueScreen),
            matching: find.text(
              'Server unreachable — retrying. Queue disabled.',
            ),
          ),
          findsOneWidget,
          reason: 'premise: the banner is really the Queue route\'s',
        );
        expect(
          bar(),
          findsOneWidget,
          reason:
              'the pre-disconnect bar is still on tree WITH the banner — '
              'the layer is the MaterialApp.builder overlay above the '
              'Navigator, so scaffold-body banner insertion neither '
              'displaces nor swallows it (AC-5 coexistence)',
        );
        expect(
          find.byKey(_miniPlayerKey),
          findsOneWidget,
          reason: 'and the mini player is still there too (inert offline)',
        );

        await tester.pump(const Duration(seconds: 2)); // drain the timer
        expect(bar(), findsNothing, reason: 'the pre-disconnect bar hid');
        expect(
          find.descendant(
            of: find.byType(QueueScreen),
            matching: find.byType(ConnectionBanner),
          ),
          findsOneWidget,
          reason: 'the banner outlives the bar — they are independent',
        );
      },
      semanticsEnabled: false,
    );

    testWidgets(
      'backgrounded declined key starts no timer and builds no overlay '
      '(D20/#84, #92 AC-7)',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpApp(tester, const NowPlayingScreen());
        await goto(tester, DrawerDestination.queue, from: NowPlayingScreen);
        final seqBefore = player.volumeStepSeq;

        handler.setAppForeground(false);
        await tester.pump();
        expect(
          await handler.handleVolumeKey(AndroidVolumeDirection.raise),
          isFalse,
          reason: 'the D20 foreground guard declines (unchanged from #84)',
        );
        expect(player.volumeStepSeq, seqBefore);
        expect(volumePuts(), isEmpty);
        expect(bar(), findsNothing);

        await tester.pump(const Duration(seconds: 3));
        expect(bar(), findsNothing);
        // Completing without the pending-timer error == no timer scheduled.
      },
    );

    testWidgets('route gating: pushed route on top shows, root (NowPlaying / '
        'popUntil) suppresses (#92 AC-2/AC-5)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpApp(tester, const NowPlayingScreen());
      expect(toaster.depth, 1);

      // Deep stack: NP → Library (drawer) → Artists (row tap).
      await goto(tester, DrawerDestination.library, from: NowPlayingScreen);
      await tester.tap(find.widgetWithText(BrowseRow, 'Artists'));
      await tester.pumpAndSettle();
      expect(find.byType(ArtistsScreen), findsOneWidget);
      expect(toaster.depth, 3, reason: 'root + library + artists');

      // Drawer from two-deep → Queue (popUntil + one push, plan A-2).
      await goto(tester, DrawerDestination.queue, from: ArtistsScreen);
      expect(find.byType(QueueScreen), findsOneWidget);
      expect(
        find.byType(ArtistsScreen),
        findsNothing,
        reason: 'popUntil popped the browse stack',
      );
      expect(
        toaster.depth,
        2,
        reason: '[root, queue] — didPop fired for every popUntil pop',
      );
      await press(tester);
      expect(bar(), findsOneWidget, reason: 'pushed route on top → shows');
      await tester.pump(const Duration(seconds: 2));

      // showNowPlaying (mini-metadata popUntil) → root on top.
      await tester.tap(find.byKey(_miniMetadataKey));
      await tester.pumpAndSettle();
      expect(toaster.depth, 1);
      expect(find.byType(NowPlayingScreen), findsOneWidget);

      await press(tester);
      expect(bar(), findsNothing, reason: 'root on top → suppressed');
      expect(
        volumeSlider(tester).value,
        85.0,
        reason:
            'the slider moved instead (75→80→85) — the NP indicator '
            'stays alive (AC-2)',
      );
    });

    testWidgets(
      'bar level equals the optimistic post-step slice value — agrees '
      'with the NP slider (#92 AC-4)',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpApp(tester, const NowPlayingScreen());
        await goto(tester, DrawerDestination.queue, from: NowPlayingScreen);

        Future<void> stepTo({required bool raise}) async {
          await press(tester, raise: raise);
          expect(bar(), findsOneWidget);
          expect(
            barText(player.player!.volume.toString()),
            findsOneWidget,
            reason:
                'bar label == the optimistic slice value the NP slider '
                'renders — agreement by construction',
          );
        }

        // Plain step from 75 (optimistic clamped value).
        await stepTo(raise: true);
        expect(player.player!.volume, 80);
        await tester.pump(const Duration(seconds: 2));

        // Clamp rows: 98+5→100, 2−5→0 (re-base the slice via a WS volume
        // event, like the shared server would). WS frame delivery runs in
        // the REAL zone — needs a real-clock drain, then the fake clock
        // drives the refetch's dio call (now_playing_screen_test pattern).
        Future<void> rebase(int to) async {
          fx.volume = to;
          channels.last.serverSend('{"notify":["volume"]}');
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 80)),
          );
          await tester.pumpAndSettle();
          expect(player.player!.volume, to, reason: 'premise: rebased');
        }

        await rebase(98);
        await stepTo(raise: true);
        expect(player.player!.volume, 100);
        expect(barText('100'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));

        await rebase(2);
        await stepTo(raise: false);
        expect(player.player!.volume, 0);
        expect(barText('0'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
      },
    );
  });
}
