import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/outputs/outputs_controller.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/ui/outputs_screen.dart';
import 'package:provider/provider.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

/// Unit 004 fixture: a stateful outputs server + a minimal player, so the
/// screen's guard (player `play`) can be exercised.
class Fixture {
  Fixture();

  String state = 'pause';

  /// Wire-shaped store.
  final List<Map<String, dynamic>> store = [
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
      'has_password': true,
      'needs_auth_key': false,
      'volume': 60,
    },
    {
      'id': 'c',
      'name': 'Gamma',
      'type': 'Pulseaudio 12',
      'selected': false,
      'has_password': false,
      'needs_auth_key': false,
      'volume': 70,
    },
  ];

  final List<List<String>> setCalls = [];
  final List<Map<String, dynamic>> perOutputBodies = [];
  String? failPutPath;
  bool rejectNextPin = false;

  Map<String, dynamic> playerJson() => {
    'state': state,
    'repeat': 'off',
    'consume': false,
    'shuffle': false,
    'volume': 75,
    'item_id': 123,
    'item_length_ms': 100000,
    'item_progress_ms': 1000,
  };

  Map<String, dynamic> queueJson() => {
    'items': [
      {
        'id': 'q1',
        'track_id': 42,
        'title': 'Test Track',
        'artist': 'Test Artist',
        'album': 'Test Album',
        'length_ms': 100000,
        'uri': 'library:track:42',
      },
    ],
  };

  Response<dynamic> handle(RequestOptions o) {
    switch (o.path) {
      case '/api/config':
        return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
      case '/api/player':
        return jsonResponse(o, playerJson());
      case '/api/queue':
        return jsonResponse(o, queueJson());
      case '/api/outputs':
        return jsonResponse(o, {'outputs': store});
    }
    if (o.method != 'PUT') return Response(requestOptions: o, statusCode: 204);
    if (failPutPath == o.path) {
      throw DioException(
        requestOptions: o,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: o, statusCode: 500),
      );
    }
    switch (o.path) {
      case '/api/outputs/set':
        final ids = ((o.data as Map<String, dynamic>)['outputs'] as List)
            .cast<String>()
            .toList();
        setCalls.add(ids);
        for (final out in store) {
          out['selected'] = ids.contains(out['id']!);
        }
        return Response(requestOptions: o, statusCode: 204);
      default:
        if (o.path.startsWith('/api/outputs/')) {
          final body = (o.data as Map<String, dynamic>).cast<String, dynamic>();
          perOutputBodies.add(body);
          if (rejectNextPin &&
              body['selected'] == true &&
              body['pin'] != null) {
            rejectNextPin = false;
            throw DioException(
              requestOptions: o,
              type: DioExceptionType.badResponse,
              response: Response(requestOptions: o, statusCode: 400),
            );
          }
          final outId = o.path.substring('/api/outputs/'.length);
          final out = store.firstWhere((s) => s['id'] == outId);
          if (body['selected'] != null) out['selected'] = body['selected'];
          return Response(requestOptions: o, statusCode: 204);
        }
        return Response(requestOptions: o, statusCode: 204);
    }
  }
}

void main() {
  late Fixture fx;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late OutputsController outputs;

  Future<void> wireUp() async {
    fx = Fixture();
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

  Future<void> pumpScreen(WidgetTester tester) => tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<ConnectionController>.value(value: conn),
        ChangeNotifierProvider<PlayerController>.value(value: player),
        ChangeNotifierProvider<OutputsController>.value(value: outputs),
      ],
      child: const MaterialApp(home: OutputsScreen()),
    ),
  );

  /// Checkbox i in list order (rows render in server order).
  Future<void> tapCheckbox(WidgetTester tester, int i) async {
    await tester.tap(find.byType(Checkbox).at(i));
    await tester.pumpAndSettle();
  }

  tearDown(() {
    player.dispose();
    outputs.dispose();
    conn.dispose();
  });

  group('R-09 rendering (C1 shape, type display)', () {
    testWidgets('all outputs render: name, type as-is, selected, volume', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.pump();
      expect(tester.takeException(), isNull);

      for (final name in ['Alpha', 'Beta', 'Gamma']) {
        expect(find.text(name), findsOneWidget);
      }
      // Type strings verbatim — incl. an unknown type (display-only,
      // no icon, no parsing).
      expect(find.text('Chromecast'), findsOneWidget);
      expect(find.text('AirPlay 1'), findsOneWidget);
      expect(find.text('Pulseaudio 12'), findsOneWidget);
      expect(find.text('50'), findsOneWidget);
      expect(find.text('60'), findsOneWidget);
      expect(find.text('70'), findsOneWidget);

      final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(boxes, hasLength(3));
      expect(boxes[0].value, isTrue, reason: 'Alpha selected');
      expect(boxes[1].value, isFalse);
      expect(boxes[2].value, isFalse);
      // The protected output carries the lock marker.
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('empty server → empty state, not a blank list', (tester) async {
      await tester.runAsync(() async {
        await wireUp();
        fx.store.clear();
        channels.single.serverSend('{"notify":["outputs"]}');
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await pumpScreen(tester);
      await tester.pump();
      expect(find.text('No outputs on this server.'), findsOneWidget);
    });
  });

  group('R-09 selection (one PUT /outputs/set per toggle)', () {
    testWidgets(
      'unprotected toggle: one /outputs/set with the full list, no dialog',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpScreen(tester);
        await tester.pump();

        await tapCheckbox(tester, 2); // Gamma on

        expect(find.text('PIN for Gamma'), findsNothing);
        expect(fx.setCalls, hasLength(1));
        expect(fx.setCalls.single, ['a', 'c'], reason: 'full id list');
        expect(fx.perOutputBodies, isEmpty, reason: 'no per-output PUT');
        // Checkbox now reflects the server-confirmed state.
        expect(
          tester.widgetList<Checkbox>(find.byType(Checkbox)).toList()[2].value,
          isTrue,
        );
      },
    );

    testWidgets('disabled while offline: checkboxes inert', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.pump();

      conn.disconnect();
      await tester.pump();
      for (final box
          in tester.widgetList<Checkbox>(find.byType(Checkbox)).toList()) {
        expect(box.onChanged, isNull);
      }
      await tapCheckbox(tester, 2);
      expect(fx.setCalls, isEmpty);
    });
  });

  group('R-09 PIN flow (C5)', () {
    testWidgets(
      'protected enable opens the PIN dialog; unlock sends selected+pin',
      (tester) async {
        await tester.runAsync(wireUp);
        await pumpScreen(tester);
        await tester.pump();

        await tester.tap(find.byType(Checkbox).at(1)); // Beta on (protected)
        await tester.pumpAndSettle();
        expect(find.text('PIN for Beta'), findsOneWidget);
        expect(find.text('Unlock'), findsOneWidget);

        await tester.enterText(find.byType(TextField), '1234');
        // One frame so the onChanged-driven rebuild (Unlock enables)
        // lands before the tap.
        await tester.pump();
        await tester.tap(find.text('Unlock'));
        await tester.pumpAndSettle();

        expect(fx.setCalls, isEmpty, reason: 'PIN path never uses /set');
        expect(fx.perOutputBodies.single, {'selected': true, 'pin': '1234'});
        expect(
          tester.widgetList<Checkbox>(find.byType(Checkbox)).toList()[1].value,
          isTrue,
        );
      },
    );

    testWidgets('cancel leaves the output disabled, no request', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester);
      await tester.pump();

      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(find.text('PIN for Beta'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(fx.perOutputBodies, isEmpty);
      expect(
        tester.widgetList<Checkbox>(find.byType(Checkbox)).toList()[1].value,
        isFalse,
      );
    });
  });

  group('playing guard (unit 004, user decision 2026-10-22)', () {
    testWidgets(
      'playing: guard dialog before the change; cancel → server untouched',
      (tester) async {
        await tester.runAsync(() async {
          await wireUp();
          fx.state = 'play';
          channels.single.serverSend('{"notify":["player"]}');
          await Future<void>.delayed(const Duration(milliseconds: 60));
        });
        await pumpScreen(tester);
        await tester.pump();

        await tester.tap(find.byType(Checkbox).at(0)); // Alpha off
        await tester.pumpAndSettle();
        expect(find.text('Server is playing'), findsOneWidget);
        expect(
          find.text(
            'Moving outputs redirects live audio to the selected outputs. '
            'Continue?',
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(fx.setCalls, isEmpty, reason: 'cancel = no request');
      },
    );

    testWidgets('playing: continue proceeds to the single /outputs/set', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await wireUp();
        fx.state = 'play';
        channels.single.serverSend('{"notify":["player"]}');
        await Future<void>.delayed(const Duration(milliseconds: 60));
      });
      await pumpScreen(tester);
      await tester.pump();

      await tester.tap(find.byType(Checkbox).at(2)); // Gamma on
      await tester.pumpAndSettle();
      expect(find.text('Server is playing'), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(fx.setCalls, hasLength(1));
      expect(fx.setCalls.single, ['a', 'c']);
    });

    testWidgets('paused: no guard dialog, direct toggle', (tester) async {
      await tester.runAsync(wireUp); // fixture default: pause
      await pumpScreen(tester);
      await tester.pump();

      await tester.tap(find.byType(Checkbox).at(2));
      await tester.pumpAndSettle();
      expect(find.text('Server is playing'), findsNothing);
      expect(fx.setCalls, hasLength(1));
    });

    testWidgets(
      'stale cache (server plays, app never told): refetch forces the dialog '
      '(2026-10-23 C3 regression)',
      (tester) async {
        await tester.runAsync(wireUp); // cache: pause
        // The server started playing without the app learning of it (no WS
        // event, no app action) — exactly the stale state observed on the
        // long-lived C3 instance. The guard must refetch, not trust the
        // cached 'pause'.
        await tester.runAsync(() async {
          fx.state = 'play';
        });
        await pumpScreen(tester);
        await tester.pump();

        await tester.tap(find.byType(Checkbox).at(0));
        await tester.pumpAndSettle();
        expect(find.text('Server is playing'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(fx.setCalls, isEmpty, reason: 'cancel = no request');
      },
    );
  });
}
