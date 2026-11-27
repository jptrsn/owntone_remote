import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// R-06 / D20, reworked by issue #84: the media session never exposes a volume
/// control — it is published `fixed` in every app state, so SystemUI's media
/// tile / output row renders no server-volume slider and Android never routes
/// the hardware rocker to `androidAdjustRemoteVolume`. The rocker reaches the
/// server through an app-local foreground path instead: the Activity's
/// `onKeyDown` hook forwards over `owntone_remote/volume_keys`, and the
/// handler steps the server via [PlayerController.stepVolume] — but only while
/// the app is resumed. Backgrounded, screen-off, or restarted by the audio
/// service with no UI, a key must never touch the server volume.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const volumeKeys = MethodChannel('owntone_remote/volume_keys');
  const codec = StandardMethodCodec();

  late VolumeServer server;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late SettingsStore store;
  late MirrorAudioHandler handler;

  /// Every `startForwarding`/`stopForwarding` the Dart side asked the
  /// platform for, in order.
  final platformCalls = <String>[];

  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);

  Future<void> pump([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  List<String> volumePuts() =>
      adapter.requests.where((r) => r.contains('/api/player/volume')).toList();

  /// Deliver one key over the platform channel exactly as the Kotlin hook
  /// does, and return what Dart answered: `true` = this app took the key (so
  /// MainActivity must not hand it to the phone), `false` = Dart declined,
  /// `null` = nothing is listening at all (the un-registered case).
  Future<Object?> deliverKey(String direction) async {
    Object? reply;
    await messenger.handlePlatformMessage(
      'owntone_remote/volume_keys',
      codec.encodeMethodCall(MethodCall('volumeKey', direction)),
      (data) => reply = data == null ? null : codec.decodeEnvelope(data),
    );
    await pumpEventQueue();
    return reply;
  }

  setUp(() async {
    platformCalls.clear();
    messenger.setMockMethodCallHandler(volumeKeys, (call) async {
      platformCalls.add(call.method);
      return true;
    });
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
    // R-14: the handler reads the step from the store at keypress time;
    // the mock starts empty → default 5, so the R-06 rows below are the
    // exact pre-R-14 expectations (±5).
    SharedPreferences.setMockInitialValues({});
    store = await SettingsStore.create();
    handler = MirrorAudioHandler(player, settings: store);
    await handler.start();
    await pump();
  });

  tearDown(() async {
    await handler.stopVolumeKeys();
    player.dispose();
    conn.dispose();
    messenger.setMockMethodCallHandler(volumeKeys, null);
  });

  /// The production sequence from main(): seed the lifecycle flag, then
  /// install the key path.
  Future<void> goForeground({MirrorAudioHandler? h}) async {
    final target = h ?? handler;
    target.setAppForeground(true);
    await target.startVolumeKeys();
    await pump();
  }

  group('session volume surface (R-06/D20, #84):', () {
    test(
      'every value published on androidPlaybackInfo after start() is '
      'non-absolute — fresh launch, wake, foregrounded and backgrounded',
      () async {
        // A handler of its own, subscribed to *before* start(), so the fresh
        // launch + one-shot wake publications are captured too.
        final probe = MirrorAudioHandler(player, settings: store);
        final emitted = <AndroidPlaybackInfo>[];
        final sub = probe.androidPlaybackInfo.listen(emitted.add);

        await probe.start();
        await pump();
        await probe.startVolumeKeys();
        await pump();

        // Force re-publications across both app states: a player change
        // drives _sync → _publishPlaybackInfo.
        probe.setAppForeground(true);
        await player.setVolume(60);
        await pump();
        probe.setAppForeground(false);
        await player.setVolume(70);
        await pump();
        await sub.cancel();
        await probe.stopVolumeKeys();

        expect(emitted, isNotEmpty, reason: 'the session must publish info');
        for (final info in emitted) {
          expect(
            info,
            isA<RemoteAndroidPlaybackInfo>(),
            reason: 'the mirror stays a remote provider (transport only)',
          );
          final remote = info as RemoteAndroidPlaybackInfo;
          expect(
            remote.volumeControlType,
            isNot(AndroidVolumeControlType.absolute),
            reason:
                'absolute is what renders the SystemUI server-volume '
                'slider and routes the rocker to the session',
          );
          expect(remote.volumeControlType, AndroidVolumeControlType.fixed);
        }
      },
    );

    test(
      'the volumeControlTypeFor absolute/fixed flip is gone — one constant',
      () {
        expect(sessionVolumeControlType, AndroidVolumeControlType.fixed);
      },
    );

    test(
      'the provider keeps maxVolume 100 and mirrors the server volume',
      () async {
        await goForeground();
        final remote =
            handler.androidPlaybackInfo.value as RemoteAndroidPlaybackInfo;
        expect(remote.volumeControlType, AndroidVolumeControlType.fixed);
        expect(remote.maxVolume, 100);
        expect(remote.volume, 75);
      },
    );

    test('androidSetRemoteVolume never moves the server in any app state '
        '(nothing renders an absolute slider any more)', () async {
      await goForeground();
      await handler.androidSetRemoteVolume(42);
      expect(volumePuts(), isEmpty);
      expect(server.volume, 75);

      handler.setAppForeground(false);
      await pump();
      await handler.androidSetRemoteVolume(42);
      expect(volumePuts(), isEmpty);
      expect(server.volume, 75);
    });
  });

  group('foreground key path (R-06/D20, #84):', () {
    test(
      'raise → +step, lower → −step, release (same) → no server call',
      () async {
        await goForeground();

        expect(await deliverKey('raise'), isTrue);
        expect(volumePuts(), ['PUT /api/player/volume?step=5']);
        expect(server.volume, 80);

        expect(await deliverKey('lower'), isTrue);
        expect(server.volume, 75);

        expect(await deliverKey('same'), isFalse);
        expect(server.volume, 75);
        expect(volumePuts(), [
          'PUT /api/player/volume?step=5',
          'PUT /api/player/volume?step=-5',
        ]);
      },
    );

    test(
      'the key path registers with the lifecycle and un-registers to a no-op',
      () async {
        expect(handler.volumeKeysStarted, isFalse);
        expect(platformCalls, isEmpty);

        await goForeground();
        expect(handler.volumeKeysStarted, isTrue);
        expect(platformCalls, ['startForwarding']);

        await handler.stopVolumeKeys();
        expect(handler.volumeKeysStarted, isFalse);
        expect(platformCalls, ['startForwarding', 'stopForwarding']);

        // Un-registered (the service-only / detached case): nobody is
        // listening on the channel any more, so a delivered key gets no
        // reply at all and the phone keeps handling it.
        expect(await deliverKey('raise'), isNull);
        expect(volumePuts(), isEmpty);
        expect(server.volume, 75);
      },
    );

    test('startVolumeKeys is idempotent and asks the platform once', () async {
      handler.setAppForeground(true);
      await handler.startVolumeKeys();
      await handler.startVolumeKeys();
      await pump();
      expect(platformCalls.where((m) => m == 'startForwarding'), hasLength(1));
    });

    test('installing the key path while backgrounded asks the platform NOT to '
        'forward (keys stay the phone\'s)', () async {
      await handler.startVolumeKeys();
      await pump();
      expect(platformCalls, ['stopForwarding']);
      expect(await deliverKey('raise'), isFalse);
      expect(volumePuts(), isEmpty);
    });

    test('backgrounding asks the platform to stop forwarding', () async {
      await goForeground();
      handler.setAppForeground(false);
      await pump();
      expect(platformCalls.last, 'stopForwarding');
    });

    test(
      'an unrecognised direction or argument is dropped, key not taken',
      () async {
        await goForeground();

        expect(await deliverKey('sideways'), isFalse);
        expect(await deliverKey(''), isFalse);

        Object? reply;
        await messenger.handlePlatformMessage(
          'owntone_remote/volume_keys',
          codec.encodeMethodCall(const MethodCall('volumeKey', 42)),
          (data) => reply = data == null ? null : codec.decodeEnvelope(data),
        );
        await pumpEventQueue();
        expect(reply, isFalse);

        await messenger.handlePlatformMessage(
          'owntone_remote/volume_keys',
          codec.encodeMethodCall(const MethodCall('somethingElse', 'raise')),
          (_) {},
        );
        await pumpEventQueue();
        expect(volumePuts(), isEmpty);
        expect(server.volume, 75);
      },
    );

    test('volumeDirectionForName maps only the three AOSP direction names', () {
      expect(volumeDirectionForName('raise'), AndroidVolumeDirection.raise);
      expect(volumeDirectionForName('lower'), AndroidVolumeDirection.lower);
      expect(volumeDirectionForName('same'), AndroidVolumeDirection.same);
      expect(volumeDirectionForName('SAME'), isNull);
      expect(volumeDirectionForName('up'), isNull);
      expect(volumeDirectionForName(''), isNull);
    });

    test(
      'the session-side override keeps the guards as a second layer',
      () async {
        // Foreground flag set but the key path never installed → no server call.
        handler.setAppForeground(true);
        await handler.androidAdjustRemoteVolume(AndroidVolumeDirection.raise);
        expect(volumePuts(), isEmpty);
        expect(server.volume, 75);

        await handler.startVolumeKeys();
        await pump();
        await handler.androidAdjustRemoteVolume(AndroidVolumeDirection.raise);
        expect(server.volume, 80);
      },
    );
  });

  group('backgrounded stays inert (R-06/D20, #84):', () {
    test(
      'default state — no resumed yet: keys never touch the server',
      () async {
        await handler.startVolumeKeys();
        await pump();
        expect(await deliverKey('raise'), isFalse);
        expect(await deliverKey('lower'), isFalse);
        expect(await deliverKey('same'), isFalse);
        expect(volumePuts(), isEmpty);
        expect(server.volume, 75);
      },
    );

    test(
      'backgrounding after a foreground session re-arms the guard',
      () async {
        await goForeground();
        expect(await deliverKey('raise'), isTrue);
        expect(server.volume, 80);

        handler.setAppForeground(false);
        await pump();

        expect(await deliverKey('raise'), isFalse);
        expect(await deliverKey('lower'), isFalse);
        expect(volumePuts(), ['PUT /api/player/volume?step=5']);
        expect(server.volume, 80);
      },
    );

    test(
      'a service-only restart (never resumed) makes zero server volume calls',
      () async {
        // As a process restarted by the bound audio service would build it:
        // no lifecycle callback has ever fired.
        final restarted = MirrorAudioHandler(player, settings: store);
        await restarted.start();
        await restarted.startVolumeKeys();
        await pump();

        expect(await deliverKey('raise'), isFalse);
        final remote =
            restarted.androidPlaybackInfo.value as RemoteAndroidPlaybackInfo;
        expect(remote.volumeControlType, AndroidVolumeControlType.fixed);
        expect(volumePuts(), isEmpty);
        expect(server.volume, 75);
        await restarted.stopVolumeKeys();
      },
    );
  });

  group('R-14 custom step (read at keypress time — applies to the next '
      'press, no restart):', () {
    setUp(() async {
      await goForeground();
    });

    test('step=1 → ±1 per press; step=10 → ±10 per press', () async {
      await store.saveRockerStep(1);
      await deliverKey('raise');
      expect(volumePuts(), ['PUT /api/player/volume?step=1']);
      expect(server.volume, 76);
      await deliverKey('lower');
      expect(server.volume, 75);

      await store.saveRockerStep(10);
      await deliverKey('raise');
      expect(volumePuts().last, 'PUT /api/player/volume?step=10');
      expect(server.volume, 85);
    });

    test('the *next* press after a Settings change uses the new step — '
        'no handler restart', () async {
      await deliverKey('raise');
      expect(volumePuts().last, 'PUT /api/player/volume?step=5');
      expect(server.volume, 80);

      await store.saveRockerStep(2);
      await deliverKey('raise');
      expect(volumePuts().last, 'PUT /api/player/volume?step=2');
      expect(server.volume, 82);
    });

    test(
      'an out-of-range stored value reaches the server clamped (1–10)',
      () async {
        SharedPreferences.setMockInitialValues({'rocker.step': 99});
        store = await SettingsStore.create();
        handler = MirrorAudioHandler(player, settings: store);
        handler.setAppForeground(true);
        await handler.startVolumeKeys();
        await pump();

        await deliverKey('raise');
        expect(volumePuts().last, 'PUT /api/player/volume?step=10');
      },
    );

    test(
      'R-06 regression guard: backgrounded stays inert at a custom step',
      () async {
        await store.saveRockerStep(10);
        handler.setAppForeground(false);
        await pump();

        expect(await deliverKey('raise'), isFalse);
        expect(await deliverKey('lower'), isFalse);
        expect(volumePuts(), isEmpty);
        expect(server.volume, 75);
      },
    );
  });
}
