import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/audio/mirror_handler.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// A minimal stateful OwnTone (same shape as the StatefulServer in
/// player_controller_call_test.dart): PUTs mutate it, GETs reflect it.
class ClickServer {
  ClickServer();

  String state = 'pause';
  int itemId = 100;

  /// When non-null, PUTs to this path fail with a connection error — the
  /// shape of the phone having left the home Wi-Fi (issue #82: the key must
  /// still be observable when its server call dies).
  String? failPutPath;

  Response<dynamic> handle(RequestOptions o) {
    if (o.method == 'GET') {
      switch (o.path) {
        case '/api/config':
          return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
        case '/api/player':
          return jsonResponse(o, {
            'state': state,
            'repeat': 'off',
            'consume': false,
            'shuffle': false,
            'volume': 75,
            'item_id': itemId,
            'item_length_ms': 100000,
            'item_progress_ms': 1000,
          });
        case '/api/queue':
          return jsonResponse(o, {
            'items': [
              {
                'id': 'q1',
                'track_id': itemId,
                'title': 'Click Track',
                'artist': 'Click Artist',
                'album': 'Click Album',
                'length_ms': 100000,
                'uri': 'library:track:$itemId',
              },
            ],
          });
        default:
          return jsonResponse(o, <String, dynamic>{});
      }
    }
    if (o.path == failPutPath) {
      throw networkError(o, 'connection refused');
    }
    switch (o.path) {
      case '/api/player/play':
        state = 'play';
      case '/api/player/pause':
        state = 'pause';
      case '/api/player/stop':
        state = 'stop';
      case '/api/player/next':
        itemId++;
      case '/api/player/previous':
        itemId--;
    }
    return Response(requestOptions: o, statusCode: 204);
  }
}

/// Captures every line a [Logger] emits, without touching stdout.
class RecordingOutput extends LogOutput {
  final List<String> lines = [];

  @override
  void output(OutputEvent event) => lines.add('${event.origin.message}');

  List<String> matching(String needle) =>
      lines.where((l) => l.contains(needle)).toList();
}

/// Issue #82 (R-04 / R-07): the media-session command funnel is observable.
///
/// audio_service routes every media button — notification/lockscreen button,
/// genuine head-unit/headset key, `cmd media_session dispatch` — through
/// `onMediaButtonEvent → onClick → click` (AudioService.java:944-986,
/// audio_service.dart:3089), and the mirror forwards all of it to
/// [PlayerController]'s HTTP calls. Before #82 the handler overrode no
/// `click()` and logged nothing, so a key that died against an unreachable
/// server left no trace anywhere (owntone-sync#11 needed exactly this
/// witness). These tests lock: exactly one arrival line per click (naming
/// the button, the foreground state and the mirrored playing state), and the
/// UNCHANGED `BaseAudioHandler.click` delegation — media → play/pause by
/// `playbackState.playing`, next → skipToNext, previous → skipToPrevious —
/// each still reaching its server call. If the delegation is ever swallowed
/// by the logging override, the server-call assertions here go red.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);

  Future<void> pump([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  late ClickServer server;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late RecordingOutput output;
  late MirrorAudioHandler handler;

  List<String> playerPuts() =>
      adapter.requests.where((r) => r.startsWith('PUT /api/player/')).toList();

  setUp(() async {
    server = ClickServer();
    adapter = ScriptedAdapter(responder: server.handle);
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
    await conn.connectTo(cfg);
    await pump();
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.create();
    output = RecordingOutput();
    handler = MirrorAudioHandler(
      player,
      settings: store,
      logger: Logger(
        printer: SimplePrinter(colors: false),
        output: output,
        filter: ProductionFilter(),
      ),
    );
    await handler.start();
    await pump();
  });

  tearDown(() {
    player.dispose();
    conn.dispose();
  });

  group('clickLogMessage (pure, R-04/R-07):', () {
    test('names the button, the foreground state and the mirrored playing '
        'state (#82)', () {
      expect(
        clickLogMessage(
          MediaButton.media,
          appForeground: false,
          serverPlaying: false,
        ),
        'click(media) appForeground=false serverPlaying=false',
      );
      expect(
        clickLogMessage(
          MediaButton.next,
          appForeground: true,
          serverPlaying: true,
        ),
        'click(next) appForeground=true serverPlaying=true',
      );
      expect(
        clickLogMessage(
          MediaButton.previous,
          appForeground: false,
          serverPlaying: null,
        ),
        'click(previous) appForeground=false serverPlaying=null',
      );
    });
  });

  group('click() logging (R-04/R-07, #82):', () {
    test('exactly one arrival line per key, emitted before the server call '
        'and naming button + foreground + mirrored playing state', () async {
      // Server is paused in setUp → the mirrored session reports playing:false.
      await handler.click(MediaButton.media);
      expect(output.matching('click(media)'), hasLength(1));
      expect(
        output.matching('click(media)').single,
        'click(media) appForeground=false serverPlaying=false',
      );
    });

    test('the line reflects the foreground state D20 already tracks', () async {
      handler.setAppForeground(true);
      await pump();
      await handler.click(MediaButton.next);
      expect(
        output.matching('click(next)').single,
        'click(next) appForeground=true serverPlaying=false',
      );
    });

    test('no-argument click() logs the media button (the audio_service '
        'default, audio_service.dart:3089)', () async {
      await handler.click();
      expect(
        output.matching('click(').single,
        'click(media) appForeground=false serverPlaying=false',
      );
    });
  });

  group('click() delegation is BaseAudioHandler.click, unchanged '
      '(R-04/R-07):', () {
    test('media while paused → play() reaches PUT /api/player/play', () async {
      expect(server.state, 'pause');
      await handler.click(MediaButton.media);
      expect(playerPuts(), contains('PUT /api/player/play'));
      expect(server.state, 'play');
      expect(output.matching('click(media)'), hasLength(1));
    });

    test('media while playing → pause() reaches PUT /api/player/pause '
        '(routed by playbackState.playing, not by a guess)', () async {
      await handler.play();
      await pump();
      expect(server.state, 'play');
      output.lines.clear();

      await handler.click(MediaButton.media);
      expect(playerPuts(), contains('PUT /api/player/pause'));
      expect(server.state, 'pause');
      expect(
        output.matching('click(media)').single,
        'click(media) appForeground=false serverPlaying=true',
      );
    });

    test('next → skipToNext() reaches PUT /api/player/next, previous → '
        'skipToPrevious() reaches PUT /api/player/previous (AOSP KeyEvent '
        '87=MEDIA_NEXT → next, 88=MEDIA_PREVIOUS → previous)', () async {
      final before = server.itemId;
      await handler.click(MediaButton.next);
      expect(playerPuts(), contains('PUT /api/player/next'));
      expect(server.itemId, before + 1);

      await handler.click(MediaButton.previous);
      expect(playerPuts(), contains('PUT /api/player/previous'));
      expect(server.itemId, before);

      expect(output.matching('click(next)'), hasLength(1));
      expect(output.matching('click(previous)'), hasLength(1));
    });
  });

  group('failure / cleanup (R-04, #82):', () {
    test('a key whose server call dies to an unreachable server still logs '
        'the arrival, completes normally, and leaves the session usable '
        '(the mirror is the only route to a server that is reachable again '
        'later)', () async {
      server.failPutPath = '/api/player/next';
      await handler.click(MediaButton.next); // must not throw
      expect(
        output.matching('click(next)').single,
        'click(next) appForeground=false serverPlaying=false',
      );

      // Not wedged: the next key still logs and still reaches the server.
      server.failPutPath = null;
      final before = server.itemId;
      await handler.click(MediaButton.next);
      expect(output.matching('click(next)'), hasLength(2));
      expect(server.itemId, before + 1);
    });

    test('a key while disconnected (phone in the car, out of home Wi-Fi) '
        'logs the arrival and issues no request', () async {
      conn.disconnect();
      await pump();
      final putsBefore = playerPuts().length;
      await handler.click(MediaButton.media); // must not throw
      expect(playerPuts(), hasLength(putsBefore));
      expect(
        output.matching('click(media)').single,
        'click(media) appForeground=false serverPlaying=false',
      );
    });
  });
}
