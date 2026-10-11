import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/outputs/outputs_controller.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

const _configJson = {'websocket_port': 3688, 'version': '29.3'};
const _queueJson = {
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

Map<String, dynamic> playerJson() => {
  'state': 'pause',
  'repeat': 'off',
  'consume': false,
  'shuffle': false,
  'volume': 75,
  'item_id': 123,
  'item_length_ms': 100000,
  'item_progress_ms': 1000,
};

const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

Future<void> realPump([int ms = 50]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late OutputsController outputs;
  late SettingsStore store;
  bool serverDown = false;

  /// All controller wiring + real-timer waiting happens inside
  /// `tester.runAsync` (widget tests run in a FakeAsync zone; the fake
  /// backoff timers and dio calls need real async).
  Future<void> wireUp() async {
    SharedPreferences.setMockInitialValues({});
    serverDown = false;
    adapter = ScriptedAdapter(
      responder: (o) {
        if (serverDown) {
          throw networkError(
            o,
            socketFailure('Connection refused (ECONNREFUSED)', 111),
          );
        }
        switch (o.path) {
          case '/api/config':
            return jsonResponse(o, _configJson);
          case '/api/player':
            return jsonResponse(o, playerJson());
          case '/api/queue':
            return jsonResponse(o, _queueJson);
          case '/api/outputs':
            return jsonResponse(o, _outputsJson);
          default:
            return jsonResponse(o, <String, dynamic>{});
        }
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
    conn.dispose();
  });

  Future<void> pumpScreen(WidgetTester tester) => tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<SettingsStore>.value(value: store),
        ChangeNotifierProvider<ConnectionController>.value(value: conn),
        ChangeNotifierProvider<PlayerController>.value(value: player),
        ChangeNotifierProvider<OutputsController>.value(value: outputs),
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
}
