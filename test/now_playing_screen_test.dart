import 'dart:io';
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
import 'package:owntone_remote/src/player/player_state.dart';
import 'package:owntone_remote/src/queue/queue_controller.dart';
import 'package:owntone_remote/src/rating/rating_controller.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:owntone_remote/src/ui/browse_screens.dart';
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

  /// Queue-item metadata (issue #26's playhead-row test pushes a long title).
  String title = 'Test Track';

  /// Browse ids on the queue item (R-17, issue #39). Default null so the
  /// pre-existing tests keep their exact queue payload — the R-17 tests
  /// opt in (the server always sends both for file tracks; null is the
  /// defensive branch that hides the entry). Non-null also flips the
  /// artwork fallback (`./artwork/album/<id>`), which is why the opt-in
  /// tests install the 404 HttpOverrides.
  String? albumId;
  String? albumArtistId;

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
          'title': title,
          'artist': 'Test Artist',
          'album': 'Test Album',
          if (albumId != null) 'album_id': albumId,
          if (albumArtistId != null) 'album_artist_id': albumArtistId,
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
      // R-17 (issue #39): the Go to Artist / Go to Album targets' browse
      // endpoints (the "real" albums/tracks the pushed route must render).
      case '/api/library/artists/aT/albums':
        return jsonResponse(o, {
          'items': [
            {
              'id': 'alT',
              'name': 'Test Album',
              'artist': 'Test Artist',
              'artist_id': 'aT',
              'track_count': 1,
              'length_ms': length,
              'uri': 'library:album:alT',
            },
            {
              'id': 'alT2',
              'name': 'Test Album Two',
              'artist': 'Test Artist',
              'artist_id': 'aT',
              'track_count': 1,
              'length_ms': length,
              'uri': 'library:album:alT2',
            },
          ],
          'total': 2,
          'offset': 0,
          'limit': 50,
        });
      case '/api/library/albums/alT/tracks':
        return jsonResponse(o, {
          'items': [
            {
              'id': 42,
              'title': title,
              'artist': 'Test Artist',
              'album': 'Test Album',
              'album_id': 'alT',
              'track_number': 1,
              'length_ms': length,
              'uri': 'library:track:42',
            },
          ],
          'total': 1,
          'offset': 0,
          'limit': 50,
        });
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

  group('playhead row — times share the slider row (issue #26, R-03)', () {
    // Repro per the issue: long title + 10:00+ (5-char) durations. The old
    // layout stacked Text/Slider/Text (full-width slider, times pushed off
    // the row). The contract (SCREENS.md item 7): ONE row
    // `[elapsed] —flex slider— [total]`, the slider the only flex child so
    // it can never squeeze the labels.
    testWidgets(
      'long title + 10:00+ durations: elapsed, Expanded slider and total in '
      'one Row; labels keep their width at a narrow viewport',
      (tester) async {
        // 360×640 — the narrowest surface the app supports (unit 004: the
        // entry row + app bar are sized for a 360-logical-px viewport; below
        // that they overflow for reasons unrelated to this row).
        tester.view.physicalSize = const Size(1080, 1920);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        await tester.runAsync(wireUp);
        fx.title =
            'A Really Unreasonably Long Track Title That Cannot Fit One Line';
        fx.length = ((45 * 60) + 12) * 1000; // '45:12' (minutes ≥ 10)
        fx.progress = ((10 * 60) + 30) * 1000; // '10:30'
        channels.last.serverSend('{"notify":["player"]}');
        await pumpScreen(tester);
        await tester.runAsync(realPump);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'no overflow');

        const elapsed = '10:30';
        const total = '45:12';
        final elapsedFinder = find.text(elapsed);
        final totalFinder = find.text(total);
        expect(elapsedFinder, findsOneWidget);
        expect(totalFinder, findsOneWidget);

        // All three live in the SAME Row (the defect put them in three
        // stacked Column children).
        final rowFinder = find
            .ancestor(of: elapsedFinder, matching: find.byType(Row))
            .first;
        final sliderFinder = find.descendant(
          of: rowFinder,
          matching: find.byType(Slider),
        );
        expect(sliderFinder, findsOneWidget);
        expect(
          find.descendant(of: rowFinder, matching: totalFinder),
          findsOneWidget,
        );

        // The slider is the row's only flex child, and the flex is Expanded
        // (it takes the leftover space between the labels, nothing more).
        final row = tester.widget<Row>(rowFinder);
        final flexed = row.children.whereType<Expanded>().toList();
        expect(flexed, hasLength(1), reason: 'slider takes only the flex');
        expect(flexed.single.child, isA<Slider>());
        expect(
          row.children
              .where((c) => c is! Expanded)
              .map((c) => (c as Text).data),
          [elapsed, total],
          reason: 'the two non-flex children are the time labels',
        );

        // Geometry: the slider sits strictly between the labels, and the
        // labels are single-line at their own width (a squeezed label would
        // wrap → double height, or ellipsize).
        final eRect = tester.getRect(elapsedFinder);
        final tRect = tester.getRect(totalFinder);
        final sRect = tester.getRect(sliderFinder);
        expect(sRect.left, greaterThanOrEqualTo(eRect.right));
        expect(sRect.right, lessThanOrEqualTo(tRect.left));
        expect(
          (eRect.center.dy - sRect.center.dy).abs(),
          lessThan(1.0),
          reason: 'times are ON the playhead row, not near it',
        );
        expect((tRect.center.dy - sRect.center.dy).abs(), lessThan(1.0));
        // Single line: ~1 line of the label text style, not 2+.
        expect(eRect.height, lessThan(24));
        expect(tRect.height, lessThan(24));
        // Never ellipsized: the label's laid-out width matches the text's
        // own intrinsic width (a squeezed label renders narrower).
        for (final (finder, text) in [
          (elapsedFinder, elapsed),
          (totalFinder, total),
        ]) {
          final painter = TextPainter(
            text: TextSpan(
              text: text,
              style: DefaultTextStyle.of(tester.element(finder)).style,
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          expect(
            tester.getSize(finder).width,
            closeTo(painter.width, 0.5),
            reason: '$text keeps its intrinsic width',
          );
        }
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
    testWidgets(
      'server-side repeat → tinted repeat button (parent-tint pattern)',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpScreen(tester);
        await tester.runAsync(realPump);
        await tester.pump();

        fx.repeat = 'all';
        channels.last.serverSend('{"notify":["options"]}');
        await tester.runAsync(realPump);
        await tester.pump();

        expect(player.player!.repeat, Repeat.all);
        final button = tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.repeat),
            matching: find.byType(IconButton),
          ),
        );
        expect(
          button.color,
          isNotNull,
          reason: 'active state tints via the button',
        );
        expect(find.byIcon(Icons.repeat_one), findsNothing);
        // Inactive side of _ModeToggle: isSelected: false must reach
        // semantics too (green-under-mutation check for that line).
        final semantics = tester.ensureSemantics();
        final inactive = tester.getSemantics(
          find
              .ancestor(
                of: find.byIcon(Icons.shuffle),
                matching: find.byType(IconButton),
              )
              .first,
        );
        expect(inactive.flagsCollection.isSelected, Tristate.isFalse);
        semantics.dispose();
      },
    );

    testWidgets('server-side repeat single → repeat_one glyph + fill', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();

      fx.repeat = 'single';
      channels.last.serverSend('{"notify":["options"]}');
      await tester.runAsync(realPump);
      await tester.pump();

      expect(player.player!.repeat, Repeat.single);
      // The activeIcon branch (R-05): single loops the current track —
      // repeat_one glyph AND the active filledTonal fill.
      expect(find.byIcon(Icons.repeat_one), findsOneWidget);
      final buttonMaterial = tester.widget<Material>(
        find
            .ancestor(
              of: find.byIcon(Icons.repeat_one),
              matching: find.byType(Material),
            )
            .first,
      );
      final expectedFill = Theme.of(
        tester.element(find.byIcon(Icons.repeat_one)),
      ).colorScheme.secondaryContainer;
      expect(buttonMaterial.color, expectedFill);
    });

    testWidgets('server-side shuffle → active affordance on the button', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();

      fx.shuffle = true;
      channels.last.serverSend('{"notify":["options"]}');
      await tester.runAsync(realPump);
      await tester.pump();

      expect(player.player!.shuffle, isTrue);
      // No shuffle_on glyph (solid-box upstream bug) — the shuffle glyph is
      // constant and the ACTIVE state rides on the button instead.
      expect(find.byIcon(Icons.shuffle), findsOneWidget);
      final buttonFinder = find.ancestor(
        of: find.byIcon(Icons.shuffle),
        matching: find.byType(IconButton),
      );
      final button = tester.widget<IconButton>(buttonFinder);
      expect(button.color, isNotNull);
      // filledTonal paints its container through the button's own Material
      // (nearest ancestor of the icon). Assert the actual fill — every M3
      // variant renders a Material with a non-null color (outlined's is
      // Colors.transparent), so isNotNull would be tautological.
      final buttonMaterial = tester.widget<Material>(
        find
            .ancestor(
              of: find.byIcon(Icons.shuffle),
              matching: find.byType(Material),
            )
            .first,
      );
      final expectedFill = Theme.of(
        tester.element(find.byIcon(Icons.shuffle)),
      ).colorScheme.secondaryContainer;
      expect(
        buttonMaterial.color,
        expectedFill,
        reason: 'active toggle renders filledTonal (secondaryContainer)',
      );
      // The glyph no longer changes with shuffle — the state must still
      // reach accessibility: isSelected → Semantics(selected:).
      final semantics = tester.ensureSemantics();
      final data = tester.getSemantics(
        find
            .ancestor(
              of: find.byIcon(Icons.shuffle),
              matching: find.byType(IconButton),
            )
            .first,
      );
      expect(data.flagsCollection.isSelected, Tristate.isTrue);
      semantics.dispose();
    });

    testWidgets('server-side consume → tinted hourglass button', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();

      fx.consume = true;
      channels.last.serverSend('{"notify":["options"]}');
      await tester.runAsync(realPump);
      await tester.pump();

      expect(player.player!.consume, isTrue);
      final button = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.hourglass_bottom),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.color, isNotNull);
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

  // R-17 (issue #39, diff-list D-04): the now-playing overflow carries
  // Go to Artist / Go to Album, pushing the browse screens for the
  // current track. The frozen spec's "absent/disabled" resolves to
  // ABSENT when no track (or no browse id) is loaded, and INERT menu
  // rows while offline (matching the entry row's disabled pattern).
  group('now-playing context navigation (R-17, issue #39)', () {
    /// Menu-open pumps (outputs_appbar_test's proven pattern: route
    /// animations need `pumpAndSettle`, not fixed pumps, in the fake-async
    /// zone — fixed-count pumps leave menu/route transitions stuck mid-
    /// flight and the popped route mounted).
    Future<void> openOverflow(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
    }

    /// Lets a pushed browse route's list fetch land (dio completes through
    /// the fake clock; the real-time beat gives the adapter's future its
    /// event-loop turns, cf. browse_screens_test's settle).
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'loaded track: overflow shows both entries; Go to Artist pushes '
      'ArtistAlbumsScreen with the artist albums; back; Go to Album pushes '
      'AlbumTracksScreen with the album tracks',
      (tester) async {
        // The queue item carries album_id (fixture default), so the
        // now-playing artwork falls back to `./artwork/album/<id>` —
        // 404-override it like the artwork test does (deterministic
        // placeholder, no real socket).
        HttpOverrides.global = _FailOverrides();
        addTearDown(() => HttpOverrides.global = null);
        await tester.runAsync(wireUp);
        fx.albumId = 'alT';
        fx.albumArtistId = 'aT';
        channels.last.serverSend('{"notify":["player"]}');
        await pumpScreen(tester);
        await tester.runAsync(realPump);
        await tester.pump();
        expect(tester.takeException(), isNull);

        await openOverflow(tester);
        expect(find.text('Go to Artist'), findsOneWidget);
        expect(find.text('Go to Album'), findsOneWidget);

        await tester.tap(find.text('Go to Artist'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        final artistRoute = find.byType(ArtistAlbumsScreen);
        expect(artistRoute, findsOneWidget, reason: 'route by widget type');
        expect(
          find.descendant(
            of: artistRoute,
            matching: find.text('Test Album Two'),
          ),
          findsOneWidget,
          reason: "the artist's real albums render",
        );

        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(ArtistAlbumsScreen), findsNothing);

        await openOverflow(tester);
        await tester.tap(find.text('Go to Album'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        final albumRoute = find.byType(AlbumTracksScreen);
        expect(albumRoute, findsOneWidget, reason: 'route by widget type');
        expect(
          find.descendant(of: albumRoute, matching: find.text('Test Track')),
          findsOneWidget,
          reason: "the album's real track renders",
        );
      },
    );

    testWidgets('stopped (no track): the overflow entries are absent', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      fx.state = 'stop';
      fx.progress = 0;
      fx.length = 0;
      fx.itemId = null;
      channels.last.serverSend('{"notify":["player"]}');
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();
      expect(find.text('Stopped'), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      expect(find.text('Go to Artist'), findsNothing);
      expect(find.text('Go to Album'), findsNothing);
    });

    testWidgets('track without browse ids (defensive branch): entries absent', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      fx.albumId = null;
      fx.albumArtistId = null;
      channels.last.serverSend('{"notify":["player"]}');
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();
      expect(find.text('Test Track'), findsOneWidget, reason: 'track loaded');
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    testWidgets('offline with a cached track: entries present but inert', (
      tester,
    ) async {
      HttpOverrides.global = _FailOverrides();
      addTearDown(() => HttpOverrides.global = null);
      await tester.runAsync(wireUp);
      fx.albumId = 'alT';
      fx.albumArtistId = 'aT';
      channels.last.serverSend('{"notify":["player"]}');
      await pumpScreen(tester);
      await tester.runAsync(realPump);
      await tester.pump();

      await tester.runAsync(dropServer);
      await tester.pump();
      expect(conn.phase, ConnectionPhase.offline);

      await openOverflow(tester);
      expect(find.text('Go to Artist'), findsOneWidget);
      expect(find.text('Go to Album'), findsOneWidget);
      final items = tester.widgetList<PopupMenuItem<String>>(
        find.byType(PopupMenuItem<String>),
      );
      expect(items, hasLength(2));
      expect(
        items.every((i) => !i.enabled),
        isTrue,
        reason: 'offline rows are inert (no dead navigation)',
      );
    });
  });
}
