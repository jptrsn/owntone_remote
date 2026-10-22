import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/audio/mirror_handler.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// A minimal stateful OwnTone for volume assertions (same shape as the
/// StatefulServer in player_controller_call_test.dart, volume path only).
class VolumeServer {
  VolumeServer();

  int volume = 75;

  Response<dynamic> handle(RequestOptions o) {
    if (o.method == 'GET') {
      switch (o.path) {
        case '/api/config':
          return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
        case '/api/player':
          return jsonResponse(o, {
            'state': 'stop',
            'repeat': 'off',
            'consume': false,
            'shuffle': false,
            'volume': volume,
            'item_id': null,
          });
        default:
          return jsonResponse(o, <String, dynamic>{});
      }
    }
    if (o.path == '/api/player/volume') {
      final q = o.queryParameters.map((k, v) => MapEntry(k, v.toString()));
      if (q['volume'] != null) {
        volume = int.parse(q['volume']!).clamp(0, 100);
      } else if (q['step'] != null) {
        volume = (volume + int.parse(q['step']!)).clamp(0, 100);
      }
    }
    return jsonResponse(o, <String, dynamic>{});
  }
}

/// D20 (R-06, rescoped 2026-10-22): the rocker maps to the server's master
/// volume only while the app is foregrounded. Backgrounded, the session is
/// published with the `fixed` volume-control type (Android then leaves the
/// volume keys to the system streams) and the handler's volume overrides
/// stay no-ops — even while the server would otherwise be selected (playing).
void main() {
  late VolumeServer server;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late MirrorAudioHandler handler;

  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);

  Future<void> pump([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  List<String> volumePuts() =>
      adapter.requests.where((r) => r.contains('/api/player/volume')).toList();

  setUp(() async {
    server = VolumeServer();
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
    handler = MirrorAudioHandler(player);
    await handler.start();
    await pump();
  });

  tearDown(() {
    player.dispose();
    conn.dispose();
  });

  group('volumeControlTypeFor (D20):', () {
    test('foreground → absolute', () {
      expect(volumeControlTypeFor(true), AndroidVolumeControlType.absolute);
    });

    test('backgrounded → fixed', () {
      expect(volumeControlTypeFor(false), AndroidVolumeControlType.fixed);
    });
  });

  group('handler while backgrounded (default — no resumed yet):', () {
    test('rocker raise/lower never touch the server', () async {
      await handler.androidAdjustRemoteVolume(AndroidVolumeDirection.raise);
      await handler.androidAdjustRemoteVolume(AndroidVolumeDirection.lower);
      expect(volumePuts(), isEmpty);
      expect(server.volume, 75);
    });

    test('absolute set never touches the server', () async {
      await handler.androidSetRemoteVolume(42);
      expect(volumePuts(), isEmpty);
      expect(server.volume, 75);
    });

    test(
      'the session is published fixed (keys stay with the system)',
      () async {
        final info = handler.androidPlaybackInfo.value;
        expect(info, isA<RemoteAndroidPlaybackInfo>());
        final remote = info as RemoteAndroidPlaybackInfo;
        expect(remote.volumeControlType, AndroidVolumeControlType.fixed);
        expect(remote.maxVolume, 100);
        expect(remote.volume, 75);
      },
    );
  });

  group('handler while foregrounded:', () {
    setUp(() async {
      handler.setAppForeground(true);
      await pump();
    });

    test('rocker raise → +step, lower → −step, same → no-op', () async {
      await handler.androidAdjustRemoteVolume(AndroidVolumeDirection.raise);
      expect(volumePuts(), ['PUT /api/player/volume?step=5']);
      expect(server.volume, 80);

      await handler.androidAdjustRemoteVolume(AndroidVolumeDirection.lower);
      expect(server.volume, 75);

      await handler.androidAdjustRemoteVolume(AndroidVolumeDirection.same);
      expect(server.volume, 75);
      expect(volumePuts(), [
        'PUT /api/player/volume?step=5',
        'PUT /api/player/volume?step=-5',
      ]);
    });

    test('absolute set lands as ?volume=', () async {
      await handler.androidSetRemoteVolume(42);
      expect(server.volume, 42);
      expect(volumePuts().last, 'PUT /api/player/volume?volume=42');
    });

    test('the session is published absolute', () async {
      final info = handler.androidPlaybackInfo.value;
      final remote = info as RemoteAndroidPlaybackInfo;
      expect(remote.volumeControlType, AndroidVolumeControlType.absolute);
    });

    test(
      'backgrounding again re-publishes fixed and re-arms the no-op',
      () async {
        handler.setAppForeground(false);
        await pump();

        final info = handler.androidPlaybackInfo.value;
        final remote = info as RemoteAndroidPlaybackInfo;
        expect(remote.volumeControlType, AndroidVolumeControlType.fixed);

        await handler.androidAdjustRemoteVolume(AndroidVolumeDirection.raise);
        expect(volumePuts(), isEmpty);
        expect(server.volume, 75);
      },
    );
  });
}
