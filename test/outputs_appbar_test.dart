import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/outputs/outputs_controller.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/ui/browse_screens.dart';
import 'package:owntone_remote/src/ui/outputs_screen.dart';
import 'package:provider/provider.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

/// R-18 (D-09) fixture: one paged list (albums, for the paged browse
/// screen) + two server outputs, so the tap-through can prove the pushed
/// OutputsScreen renders the fake provider's output *names* (not just
/// that a route opened).
class _Fixture {
  String state = 'pause';

  final List<Map<String, dynamic>> albums = [
    {
      'id': 'al1',
      'name': 'Album 1',
      'artist': 'Artist 1',
      'artist_id': 'a1',
      'track_count': 2,
      'length_ms': 100000,
      'year': 2020,
    },
  ];

  final List<Map<String, dynamic>> outputs = [
    {
      'id': 'a',
      'name': 'Alpha',
      'type': 'Chromecast',
      'selected': true,
      'has_password': false,
      'needs_auth_key': false,
      'volume': 50,
    },
    {
      'id': 'b',
      'name': 'Beta',
      'type': 'AirPlay 1',
      'selected': false,
      'has_password': false,
      'needs_auth_key': false,
      'volume': 60,
    },
  ];

  Response<dynamic> handle(RequestOptions o) {
    switch (o.uri.path) {
      case '/api/config':
        return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
      case '/api/player':
        return jsonResponse(o, {'state': state, 'volume': 40});
      case '/api/library/albums':
        return jsonResponse(o, {
          'items': albums,
          'total': albums.length,
          'offset': 0,
          'limit': 50,
        });
      case '/api/outputs':
        return jsonResponse(o, {'outputs': outputs});
      case '/api/queue':
        // PlayerController refreshes the queue alongside the player.
        return jsonResponse(o, {
          'version': 1,
          'count': 0,
          'items': <Map<String, dynamic>>[],
        });
      default:
        return Response(requestOptions: o, statusCode: 404);
    }
  }
}

void main() {
  late _Fixture fx;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late OutputsController outputs;

  Future<void> wireUp() async {
    fx = _Fixture();
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
    await conn.connectTo(_cfg);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  /// R-18 viewport constraint (unit 004 finding): the app bar must fit at
  /// 360 logical px — the width where a second app-bar action already
  /// overflowed in dv unit 004.
  void use360x800Viewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpScreen(WidgetTester tester, Widget screen) =>
      tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ConnectionController>.value(value: conn),
            ChangeNotifierProvider<PlayerController>.value(value: player),
            ChangeNotifierProvider<OutputsController>.value(value: outputs),
          ],
          child: MaterialApp(home: screen),
        ),
      );

  /// Lets the (fake) network futures land, then renders frames (same
  /// pattern as browse_screens_test).
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  tearDown(() {
    player.dispose();
    outputs.dispose();
    conn.dispose();
  });

  group('R-18 outputs action on every browse screen (D-09)', () {
    testWidgets(
      'library home at 360x800: outputs icon present (semantics label), '
      'no RenderFlex overflow',
      (tester) async {
        use360x800Viewport(tester);
        await tester.runAsync(wireUp);
        final semantics = tester.ensureSemantics();
        await pumpScreen(tester, const LibraryHomeScreen());
        await settle(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: 'app bar + one action must not overflow at 360 dp',
        );
        expect(find.byTooltip('Outputs'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Outputs'),
          findsOneWidget,
          reason:
              'PR #52 review: uniqueness of the semantics node must regress if duplicated (tooltip check alone does not pin it)',
        );
        semantics.dispose();
      },
    );

    testWidgets(
      'paged list (Albums) at 360x800: outputs icon present, no overflow, '
      'rows still render',
      (tester) async {
        use360x800Viewport(tester);
        await tester.runAsync(wireUp);
        final semantics = tester.ensureSemantics();
        await pumpScreen(tester, const AlbumsScreen());
        await settle(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: 'title + back + one action must fit at 360 dp',
        );
        expect(find.byTooltip('Outputs'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Outputs'),
          findsOneWidget,
          reason:
              'PR #52 review: uniqueness of the semantics node must regress if duplicated (tooltip check alone does not pin it)',
        );
        expect(
          find.text('Album 1'),
          findsOneWidget,
          reason: 'the action did not displace the list',
        );
        semantics.dispose();
      },
    );

    testWidgets(
      'library home: tapping the outputs action pushes OutputsScreen',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpScreen(tester, const LibraryHomeScreen());
        await settle(tester);

        await tester.tap(find.byTooltip('Outputs'));
        await tester.pumpAndSettle();
        expect(find.byType(OutputsScreen), findsOneWidget);
        expect(find.text('Outputs'), findsOneWidget, reason: 'app bar title');
        // The server's outputs render from the fake provider — the
        // destination is the real OutputsScreen, not a stub route.
        expect(find.text('Alpha'), findsOneWidget);
        expect(find.text('Beta'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'paged list (Albums): tap → OutputsScreen with the outputs list, '
      'back returns to the browse list',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpScreen(tester, const AlbumsScreen());
        await settle(tester);
        expect(find.text('Album 1'), findsOneWidget);

        await tester.tap(find.byTooltip('Outputs'));
        await tester.pumpAndSettle();
        expect(find.byType(OutputsScreen), findsOneWidget);
        expect(find.text('Alpha'), findsOneWidget);
        expect(find.text('Beta'), findsOneWidget);

        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(OutputsScreen), findsNothing);
        expect(
          find.text('Album 1'),
          findsOneWidget,
          reason: 'back navigation returns to the paged browse list',
        );
        expect(
          find.byTooltip('Outputs'),
          findsOneWidget,
          reason: 'the action is still there on return',
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
