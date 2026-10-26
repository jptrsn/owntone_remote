import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/outputs/outputs_controller.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/player/player_state.dart';
import 'package:owntone_remote/src/queue/queue_controller.dart';
import 'package:owntone_remote/src/rating/rating_controller.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

const _configJson = {'websocket_port': 3688, 'version': '29.3'};
const _outputsJson = {
  'outputs': [
    {
      'id': '1',
      'name': 'Office-Airsync',
      'type': 'AirPlay 1',
      'selected': true,
      'has_password': false,
      'needs_auth_key': false,
      'volume': 100,
    },
  ],
};

/// Stateful player fixture: GETs reflect it, PUTs mutate it (unit 002
/// tests: optimistic updates, drag-state sliders, WS option events).
class Fixture {
  Fixture();

  String state = 'pause';
  String repeat = 'off';
  bool consume = false;
  bool shuffle = false;
  int volume = 75;
  int progress = 1000;
  int length = 100000;
  int? itemId = 123;

  /// Artwork URL for the queue item (null = none → placeholder).
  String? itemArtwork;

  /// When non-null, PUTs to this path answer 500 (rollback/snackbar tests).
  String? failPutPath;

  Map<String, dynamic> playerJson() => {
    'state': state,
    'repeat': repeat,
    'consume': consume,
    'shuffle': shuffle,
    'volume': volume,
    if (itemId != null) 'item_id': itemId,
    if (length > 0) 'item_length_ms': length,
    'item_progress_ms': progress,
  };

  Map<String, dynamic> queueJson() => {
    'items': [
      if (itemId != null)
        {
          'id': 'q1',
          'track_id': 42,
          'title': 'Test Track',
          'artist': 'Test Artist',
          'album': 'Test Album',
          'length_ms': length,
          'uri': 'library:track:42',
          if (itemArtwork != null) 'artwork_url': itemArtwork,
        },
    ],
  };

  Response<dynamic> handle(RequestOptions o) {
    switch (o.path) {
      case '/api/config':
        return jsonResponse(o, _configJson);
      case '/api/player':
        return jsonResponse(o, playerJson());
      case '/api/queue':
        return jsonResponse(o, queueJson());
      case '/api/outputs':
        return jsonResponse(o, _outputsJson);
    }
    if (o.method != 'PUT') {
      return jsonResponse(o, <String, dynamic>{});
    }
    if (failPutPath == o.path) {
      throw DioException(
        requestOptions: o,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: o, statusCode: 500),
      );
    }
    // dio passes query values through untyped — an `int` stays an `int`.
    final q = o.queryParameters.map((k, v) => MapEntry(k, v.toString()));
    switch (o.path) {
      case '/api/player/play':
        state = 'play';
      case '/api/player/pause':
        state = 'pause';
      case '/api/player/stop':
        state = 'stop';
        progress = 0;
      case '/api/player/shuffle':
        shuffle = q['state'] == 'true';
      case '/api/player/repeat':
        repeat = q['state'] ?? repeat;
      case '/api/player/consume':
        consume = q['state'] == 'true';
      case '/api/player/volume':
        if (q['volume'] != null) {
          volume = int.parse(q['volume']!).clamp(0, 100);
        }
      case '/api/player/seek':
        progress = int.parse(q['position_ms']!).clamp(0, length);
    }
    return Response(requestOptions: o, statusCode: 204);
  }
}

const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

/// 'mm:ss' for a millisecond value (the screen's format).
String _fmt(int ms) =>
    '${(ms ~/ 60000).toString().padLeft(2, '0')}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}';

/// HttpClient stand-in that 404s every request — forces Image.network's
/// errorBuilder (R-03 artwork placeholder on 404) deterministically.
/// Implements only the members NetworkImage's load path touches.
class _FailOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FailClient();
}

class _FailClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FailRequest();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

/// Minimal [HttpHeaders] (the real class is unconstructable): records
/// `add`, rejects the rest. NetworkImage's load path only calls `add`.
class _FailHeaders implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _FailRequest implements HttpClientRequest {
  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  final HttpHeaders _headers = _FailHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async => _FailResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _FailResponse implements HttpClientResponse {
  @override
  int statusCode = 404;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

Future<void> realPump([int ms = 50]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late Fixture fx;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late OutputsController outputs;
  late QueueController queue;
  late RatingController rating;
  late SettingsStore store;
  bool serverDown = false;

  /// All controller wiring + real-timer waiting happens inside
  /// `tester.runAsync` (widget tests run in a FakeAsync zone; the fake
  /// backoff timers and dio calls need real async).
  Future<void> wireUp() async {
    SharedPreferences.setMockInitialValues({});
    serverDown = false;
    fx = Fixture();
    adapter = ScriptedAdapter(
      responder: (o) {
        if (serverDown) {
          throw networkError(
            o,
            socketFailure('Connection refused (ECONNREFUSED)', 111),
          );
        }
        return fx.handle(o);
      },
    );
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
          if (serverDown) c.handshakeFails = true;
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
    await conn.connectTo(_cfg);
    await realPump();
  }

  Future<void> dropServer() async {
    serverDown = true;
    channels.last.serverClose();
    await realPump(150);
  }

  Future<void> restoreServer() async {
    serverDown = false;
    await realPump(250);
  }

  tearDown(() {
    player.dispose();
    outputs.dispose();
    rating.dispose();
    queue.dispose();
    conn.dispose();
  });

  Future<void> pumpScreen(WidgetTester tester) => tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<SettingsStore>.value(value: store),
        ChangeNotifierProvider<ConnectionController>.value(value: conn),
        ChangeNotifierProvider<PlayerController>.value(value: player),
        ChangeNotifierProvider<OutputsController>.value(value: outputs),
        ChangeNotifierProvider<QueueController>.value(value: queue),
        ChangeNotifierProvider<RatingController>.value(value: rating),
      ],
      child: const MaterialApp(home: NowPlayingScreen()),
    ),
  );

  List<IconButton> transportButtons(WidgetTester tester) {
    final icons = {
      Icons.play_arrow,
      Icons.pause,
      Icons.skip_next,
      Icons.skip_previous,
      Icons.shuffle,
      Icons.shuffle_on,
      Icons.repeat,
      Icons.repeat_one,
      Icons.hourglass_bottom,
      Icons.hourglass_empty,
      Icons.stop,
    };
    return tester
        .widgetList<IconButton>(find.byType(IconButton))
        .where((b) => b.icon is Icon && icons.contains((b.icon as Icon).icon))
        .toList();
  }

  group('offline banner + disabled controls (unit 001 criterion 6)', () {
    testWidgets('banner shows offline, controls disable; both reverse', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.text('Server unreachable — retrying. Controls disabled.'),
        findsNothing,
      );
      expect(
        transportButtons(tester).every((b) => b.onPressed != null),
        isTrue,
      );

      // Server goes away: WS drops, probes fail → offline.
      await tester.runAsync(dropServer);
      await tester.pump();
      expect(conn.phase, ConnectionPhase.offline);

      expect(
        find.text('Server unreachable — retrying. Controls disabled.'),
        findsOneWidget,
      );
      expect(
        transportButtons(tester).every((b) => b.onPressed == null),
        isTrue,
      );
      final slider = tester.widget<Slider>(find.byType(Slider).last);
      expect(slider.onChanged, isNull, reason: 'volume slider disabled');

      // Server is back: reconnect, banner hidden, controls re-enabled.
      await tester.runAsync(restoreServer);
      await tester.pump();
      expect(conn.phase, ConnectionPhase.connected);
      expect(
        find.text('Server unreachable — retrying. Controls disabled.'),
        findsNothing,
      );
      expect(
        transportButtons(tester).every((b) => b.onPressed != null),
        isTrue,
      );
    });
  });

  group('viewport fit — no scroll, artwork 1:1 (unit 001 criterion 8)', () {
    testWidgets('tall surface: artwork is a full-width square, fits', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2880);
      tester.view.devicePixelRatio = 3.0;
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'no overflow');

      final art = tester.getSize(find.byType(ArtworkBox));
      expect(art.width, art.height, reason: 'aspect ratio preserved');
      expect(
        art.width,
        360 - 48,
        reason: 'width-constrained when the height allows it',
      );

      final volBottom = tester.getRect(find.text('75')).bottom;
      expect(volBottom, lessThanOrEqualTo(960));
      expect(
        tester.getRect(find.byIcon(Icons.skip_next)).bottom,
        lessThanOrEqualTo(960),
      );
    });

    testWidgets('normal phone: artwork shrinks, all controls still visible', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'no overflow');

      final art = tester.getSize(find.byType(ArtworkBox));
      expect(art.width, art.height, reason: 'aspect ratio preserved');
      expect(
        art.width,
        lessThan(360 - 48),
        reason:
            'artwork shrinks below full width when the fixed controls '
            'leave little room',
      );

      // The bottom-most control (volume label) is inside the viewport.
      final volBottom = tester.getRect(find.text('75')).bottom;
      expect(volBottom, lessThanOrEqualTo(640));
    });

    testWidgets('short surface: artwork shrinks further, controls visible', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 1680);
      tester.view.devicePixelRatio = 3.0;
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'no overflow');

      final art = tester.getSize(find.byType(ArtworkBox));
      expect(art.width, art.height, reason: 'aspect ratio preserved');
      expect(art.width, greaterThan(0.0));

      final volBottom = tester.getRect(find.text('75')).bottom;
      expect(volBottom, lessThanOrEqualTo(560));
    });
  });

  group('three states render correctly (R-03)', () {
    testWidgets('playing: pause icon, seek enabled, progress label', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      fx.state = 'play';
      channels.last.serverSend('{"notify":["player"]}');
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();
      expect(tester.takeException(), isNull);

      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
      expect(find.text('Test Track'), findsOneWidget);
      expect(find.text('Test Artist · Test Album'), findsOneWidget);
      expect(find.text('00:01'), findsOneWidget, reason: 'elapsed');
      expect(find.text('01:40'), findsOneWidget, reason: 'total');
      final seek = tester.widget<Slider>(find.byType(Slider).first);
      expect(seek.onChanged, isNotNull, reason: 'seek enabled');
    });

    testWidgets('paused: play icon, progress frozen', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing);
      // Paused: no local ticker → the label stays on the server value.
      expect(find.text('00:01'), findsOneWidget);
      final seek = tester.widget<Slider>(find.byType(Slider).first);
      expect(seek.onChanged, isNotNull);
    });

    testWidgets(
      'stopped: title "Stopped", prev/next/stop disabled, play enabled, '
      'seek disabled',
      (tester) async {
        await tester.runAsync(wireUp);
        fx.state = 'stop';
        fx.progress = 0;
        fx.length = 0;
        fx.itemId = null;
        channels.last.serverSend('{"notify":["player"]}');
        await pumpScreen(tester);
        await tester.runAsync(realPump);
        await tester.pump();
        expect(tester.takeException(), isNull);

        expect(find.text('Stopped'), findsOneWidget);
        expect(find.text('00:00'), findsNWidgets(2), reason: 'elapsed+total');

        final prev = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.skip_previous),
            matching: find.byType(IconButton),
          ),
        );
        final next = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.skip_next),
            matching: find.byType(IconButton),
          ),
        );
        final stop = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.stop),
            matching: find.byType(IconButton),
          ),
        );
        final play = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.play_arrow),
            matching: find.byType(IconButton),
          ),
        );
        expect(prev.onPressed, isNull);
        expect(next.onPressed, isNull);
        expect(stop.onPressed, isNull);
        expect(play.onPressed, isNotNull, reason: 'play restarts from stop');

        // No item → no seekable length → seek disabled, placeholder artwork.
        final seek = tester.widget<Slider>(find.byType(Slider).first);
        expect(seek.onChanged, isNull);
        expect(find.byIcon(Icons.music_note), findsOneWidget);
      },
    );
  });

  group('seek drag-state (R-03, spike Finding 14)', () {
    testWidgets(
      'one seek on release; none while dragging; label follows the finger',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpScreen(tester);
        await tester.runAsync(realPump);
        await tester.pump();

        final seekCenter = tester.getCenter(find.byType(Slider).first);
        final gesture = await tester.startGesture(seekCenter);
        await tester.pump();
        await gesture.moveBy(const Offset(60, 0));
        await tester.pump();

        // Mid-drag: the label moved off the server value, but NO seek was
        // sent yet.
        expect(find.text('00:01'), findsNothing);
        expect(
          adapter.requests,
          isNot(contains(contains('seek'))),
          reason: 'no REST call before release',
        );

        await gesture.up();
        // `pumpAndSettle`, not a bare `pump()`: the release commits
        // seekMs → dio, and dio's request flow is scheduled through
        // `Future(callback)` → `Timer.run` (0 s) since Dart 3.11. In the
        // fake-async test zone that timer only fires when the fake clock
        // actually advances; a bare `pump()` advances no time, so the
        // request would never reach the adapter.
        await tester.pumpAndSettle();

        final seekRequests = adapter.requests
            .where((r) => r.contains('seek'))
            .toList();
        expect(seekRequests, hasLength(1));
        final ms = int.parse(
          RegExp(
            r'position_ms=(\d+)',
          ).firstMatch(seekRequests.single)!.group(1)!,
        );
        expect(ms, greaterThan(1000), reason: 'dragged right of the start');
        // The refetch re-based the label on the server-confirmed position.
        expect(find.text(_fmt(ms)), findsOneWidget);
      },
    );

    testWidgets('a server update mid-drag does not move the slider', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();
      expect(find.text('00:01'), findsOneWidget);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Slider).first),
      );
      await tester.pump();
      expect(find.text('00:01'), findsNothing, reason: 'drag value shown');

      // The server moves on (WS player event → refetch): the dragged
      // position must win while the finger is down.
      fx.progress = 80000;
      channels.last.serverSend('{"notify":["player"]}');
      await tester.runAsync(realPump);
      await tester.pump();
      expect(find.text('01:20'), findsNothing, reason: 'server value hidden');
      expect(find.text('00:01'), findsNothing);

      await gesture.up();
      // Advances the fake clock so the release commit (dio via
      // Timer.run) and its confirming refetch complete (see the seek test).
      await tester.pumpAndSettle();
    });
  });

  group('volume drag-state (R-06, spike Finding 14)', () {
    testWidgets('one volume PUT on release; label follows the finger', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();
      expect(find.text('75'), findsOneWidget);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Slider).last),
      );
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      expect(find.text('75'), findsNothing, reason: 'drag value shown');
      expect(
        adapter.requests,
        isNot(contains(contains('/api/player/volume'))),
        reason: 'no REST call before release',
      );

      await gesture.up();
      // Fake-clock advance for the dio commit + refetch (see seek test).
      await tester.pumpAndSettle();

      final volumeRequests = adapter.requests
          .where((r) => r.contains('/api/player/volume'))
          .toList();
      expect(volumeRequests, hasLength(1));
      final vol = int.parse(
        RegExp(r'volume=(\d+)').firstMatch(volumeRequests.single)!.group(1)!,
      );
      expect(vol, lessThan(75), reason: 'dragged left');
      expect(find.text('$vol'), findsOneWidget, reason: 'confirmed value');
    });

    testWidgets('a remote volume update does not yank a dragged slider', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Slider).last),
      );
      await tester.pump();

      // Rocker / web UI changed the server volume mid-drag.
      fx.volume = 20;
      channels.last.serverSend('{"notify":["volume"]}');
      await tester.runAsync(realPump);
      await tester.pump();
      expect(find.text('20'), findsNothing, reason: 'drag value wins');

      await gesture.up();
      // Fake-clock advance for the dio commit + refetch (see seek test).
      await tester.pumpAndSettle();
      // The committed (release) value wins over the stale server value.
      final vol = player.player!.volume;
      expect(find.text('$vol'), findsOneWidget);
    });

    testWidgets('failed volume send rolls back and shows a snackbar', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();
      expect(find.text('75'), findsOneWidget);

      fx.failPutPath = '/api/player/volume';
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Slider).last),
      );
      await gesture.moveBy(const Offset(30, 0));
      await gesture.up();
      await tester.runAsync(realPump);
      await tester.pumpAndSettle();

      expect(player.player!.volume, 75, reason: 'rolled back');
      expect(find.text('75'), findsOneWidget);
      expect(
        find.text('Volume failed — server answered HTTP 500.'),
        findsOneWidget,
        reason: 'snackbar with the typed error',
      );
    });
  });

  group('WS options events update the UI without a manual refresh (R-05)', () {
    testWidgets('server-side repeat → tinted repeat icon', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();

      fx.repeat = 'all';
      channels.last.serverSend('{"notify":["options"]}');
      await tester.runAsync(realPump);
      await tester.pump();

      expect(player.player!.repeat, Repeat.all);
      final icon = tester.widget<Icon>(find.byIcon(Icons.repeat));
      expect(icon.color, isNotNull, reason: 'active state is tinted');
    });

    testWidgets('server-side shuffle → shuffle_on icon', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();

      fx.shuffle = true;
      channels.last.serverSend('{"notify":["options"]}');
      await tester.runAsync(realPump);
      await tester.pump();

      expect(player.player!.shuffle, isTrue);
      expect(find.byIcon(Icons.shuffle_on), findsOneWidget);
    });

    testWidgets('server-side consume → tinted hourglass', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();

      fx.consume = true;
      channels.last.serverSend('{"notify":["options"]}');
      await tester.runAsync(realPump);
      await tester.pump();

      expect(player.player!.consume, isTrue);
      final icon = tester.widget<Icon>(find.byIcon(Icons.hourglass_bottom));
      expect(icon.color, isNotNull);
    });
  });

  group('artwork placeholder (R-03)', () {
    testWidgets('a 404 artwork renders the placeholder icon', (tester) async {
      HttpOverrides.global = _FailOverrides();
      addTearDown(() => HttpOverrides.global = null);
      await tester.runAsync(wireUp);
      fx.itemArtwork = './artwork/item/42';
      // Invalidate so the now-playing item (with its artwork URL) is
      // refetched and the image load actually starts.
      channels.last.serverSend('{"notify":["player"]}');
      await pumpScreen(tester);
      // The WS refetch is a real-zone dio call (the WS listener subscribed
      // in runAsync); real time lets it deliver the item with artwork.
      await tester.runAsync(() => realPump(300));
      await tester.pump();
      // Only now does the first frame mount Image.network; the (failing)
      // HTTP round-trip over the fake client needs its own real-time
      // window before the errorBuilder frame renders.
      await tester.runAsync(() => realPump(300));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        find.byIcon(Icons.music_note),
        findsOneWidget,
        reason: '404 artwork → placeholder',
      );
    });

    testWidgets('an absent artwork URL renders the placeholder directly', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      // Fixture default: no artwork_url on the queue item.
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();
      expect(find.byIcon(Icons.music_note), findsOneWidget);
    });
  });
}
