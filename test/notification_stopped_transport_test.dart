import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/audio/mirror_handler.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/player/player_state.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// Issue #83 (R-07 "notification shows the current track + **working
/// controls**"): the SystemUI media tile rendered a fully live transport
/// card while the server was `stop`ped — the mirror published
/// `PAUSED(2)`/`ready` with play + next + previous and the metadata still
/// set, but OwnTone does not honour a skip while stopped (Pixel 6 host
/// pass: `PUT /api/player/next` → 204 with the queue pointer frozen,
/// `previous` → HTTP 500). The tile therefore advertised controls the
/// server silently ignores, and the one failure it can produce (the 500)
/// surfaces only as an in-app snackbar the shade cannot show.
///
/// The contract these tests pin is "the session exposes only what the
/// server honours": `stop` publishes `play` (which IS honoured — the item
/// stays queued and `PUT /api/player/play` restarts it, which is also why
/// NowPlaying keeps its play button live while stopped) and no metadata.
/// `pause` keeps the full trio untouched — the discriminator between the
/// two is the server state, never "is there an item in the queue".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final webRoot = Uri.parse('http://10.0.0.5:3689/');

  PlayerState state({
    String s = 'stop',
    int? progress = 0,
    int? length = 353512,
  }) => PlayerState(
    state: s,
    repeat: Repeat.off,
    consume: false,
    shuffle: false,
    volume: 75,
    itemId: 196000,
    itemLengthMs: length,
    itemProgressMs: progress,
  );

  /// An artwork-less item: `_sync` only awaits `ArtworkProbe` when
  /// `artworkUrl != null`, so these stay offline.
  Map<String, dynamic> itemJson({String title = 'Killing Me Softly'}) => {
    'id': '1',
    'track_id': 196000,
    'title': title,
    'artist': 'Fugees',
    'album': 'The Score',
    'length_ms': 353512,
    'uri': 'library:track:196000',
  };

  group('controlsFor (R-04 transport, R-07 tile) — stop exposes only what '
      'the server honours (#83)', () {
    test(
      'R-04/R-07 stopped → play ONLY: no skipToNext/skipToPrevious (server no-ops '
      'next and 500s previous while stopped), and no stop control '
      '(SCREENS.md v1 notification has no stop)',
      () {
        expect(controlsFor(state(s: 'stop')), [MediaControl.play]);
        expect(
          controlsFor(state(s: 'stop')),
          isNot(contains(MediaControl.stop)),
        );
      },
    );

    test(
      'R-04/R-07 paused keeps the full trio (the fix is scoped to stop, not to '
      '"not playing" — a paused server DOES honour next/previous)',
      () {
        expect(controlsFor(state(s: 'pause')), [
          MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.skipToPrevious,
        ]);
      },
    );

    test('R-04/R-07 playing keeps pause/next/previous', () {
      expect(controlsFor(state(s: 'play')), [
        MediaControl.pause,
        MediaControl.skipToNext,
        MediaControl.skipToPrevious,
      ]);
    });

    test('R-07 regression guard: all three states keep processingState ready, '
        'never idle — audio_service 0.18.19 routes an idle publication '
        'through AudioService.stop(), which would tear down the R-07 '
        'notification + mediaPlayback FGS', () {
      for (final st in ['play', 'pause', 'stop']) {
        expect(
          playbackStateFor(state(s: st)).processingState,
          AudioProcessingState.ready,
          reason: '`$st` must stay ready — idle would kill the tile',
        );
      }
    });
    test(
      'R-04 the mapping keys on the server state, not on the item: a stopped '
      'slice that still carries item_id (what the server really returns) '
      'gets the same play-only row as one without it',
      () {
        final withItem = state(s: 'stop');
        final withoutItem = PlayerState(
          state: 'stop',
          repeat: Repeat.off,
          consume: false,
          shuffle: false,
          volume: 75,
          itemId: null,
        );
        expect(controlsFor(withItem), controlsFor(withoutItem));
        expect(controlsFor(withoutItem), [MediaControl.play]);
      },
    );
  });

  group('playbackStateFor / mediaItemFor while stopped (#83)', () {
    test(
      'R-07 stopped publishes playing=false + ready: the honest paused shape '
      '(no faked PLAYING to buy tappability — that is #82 session shape, '
      'and the tile is not gated on state anyway: the host pass dispatched '
      'transport taps fine from PAUSED)',
      () {
        final ps = playbackStateFor(state(s: 'stop', progress: 0));
        expect(ps.playing, isFalse);
        expect(ps.processingState, AudioProcessingState.ready);
        expect(ps.updatePosition, Duration.zero);
        expect(ps.controls, [MediaControl.play]);
      },
    );

    test(
      'R-07 the metadata clear lives in MirrorAudioHandler._sync, not in the '
      'pure mapper: mediaItemFor still maps a stopped slice exactly as it '
      'maps a paused one (R-07 metadata purity, unit 010)',
      () {
        final item = NowPlayingItem.fromJson(itemJson(), webRoot);
        expect(
          mediaItemFor(
            item: item,
            p: state(s: 'stop'),
          )?.title,
          'Killing Me Softly',
        );
        expect(
          mediaItemFor(
            item: item,
            p: state(s: 'pause'),
          )?.title,
          'Killing Me Softly',
        );
      },
    );
  });

  group('MirrorAudioHandler publishes the honours-only shape (#83)', () {
    late StoppedServer server;
    late ScriptedAdapter adapter;
    late List<FakeWsChannel> channels;
    late ConnectionController conn;
    late PlayerController player;
    late MirrorAudioHandler handler;

    const cfg = ServerConfig(host: '10.0.0.5', port: 3689);

    Future<void> pump([int ms = 80]) =>
        Future<void>.delayed(Duration(milliseconds: ms));

    List<String> transportPuts() => adapter.requests
        .where(
          (r) =>
              r.contains('/api/player/next') ||
              r.contains('/api/player/previous') ||
              r.contains('/api/player/play'),
        )
        .toList();

    Future<MirrorAudioHandler> buildHandler() async {
      SharedPreferences.setMockInitialValues({});
      final store = await SettingsStore.create();
      return MirrorAudioHandler(player, settings: store);
    }

    setUp(() async {
      server = StoppedServer();
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
    });

    tearDown(() {
      player.dispose();
      conn.dispose();
    });

    test('R-07 cold start with the server stopped (queue still answers the '
        'now-playing item, item_id still set — the measured server shape): '
        'NO metadata ever published, controls = play only', () async {
      server.state = 'stop';
      server.nowPlaying = itemJson();
      await pump();

      handler = await buildHandler();
      final published = <MediaItem?>[];
      final sub = handler.mediaItem.listen(published.add);
      final states = <PlaybackState>[];
      final sub2 = handler.playbackState.listen(states.add);

      await handler.start();
      await pump(200);

      expect(
        published.whereType<MediaItem>(),
        isEmpty,
        reason:
            'a stopped server must not leave the previous track on the '
            'tile — the old code let the `item != null` branch win over '
            'the isStopped clear, which is what kept the card alive',
      );
      expect(handler.mediaItem.value, isNull);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.controls, [MediaControl.play]);
      expect(
        states.expand((s) => s.controls),
        isNot(contains(MediaControl.skipToNext)),
        reason: 'not even the one-shot wake may expose a dead skip',
      );
      await sub.cancel();
      await sub2.cancel();
    });

    test('R-07 paused → stop re-publishes: the live trio and the metadata '
        'both '
        'go away, so the tile stops offering a transport the server cannot '
        'service (the reported state)', () async {
      handler = await buildHandler();
      final published = <MediaItem?>[];
      final sub = handler.mediaItem.listen(published.add);

      // Paused with a loaded queue item — the genuinely-live shape.
      server.state = 'pause';
      server.nowPlaying = itemJson();
      channels.single.serverSend('{"notify":["player"]}');
      await pump();

      await handler.start();
      await pump(150);

      // Control leg: while paused the card is genuinely live.
      expect(handler.mediaItem.value?.title, 'Killing Me Softly');
      expect(handler.playbackState.value.controls, [
        MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.skipToPrevious,
      ]);
      expect(published.whereType<MediaItem>(), isNotEmpty);

      // The measured server shape: stopped, but the queue slice still
      // answers the item (OwnTone keeps item_id across a stop).
      server.state = 'stop';
      channels.single.serverSend('{"notify":["player"]}');
      await pump(200);

      expect(player.player?.isStopped, isTrue, reason: 'fixture reached stop');
      expect(handler.playbackState.value.controls, [MediaControl.play]);
      expect(
        published.whereType<MediaItem>().last.title,
        'Killing Me Softly',
        reason: 'the metadata was shown while paused…',
      );
      expect(
        handler.mediaItem.value,
        isNull,
        reason: '…and is cleared on stop',
      );
      await sub.cancel();
    });

    test(
      'R-04/R-07 stop → play restores next/previous: the restriction is '
      'the server '
      'state, not a one-way clamp (a fresh play from stop is honoured)',
      () async {
        server.state = 'stop';
        server.nowPlaying = itemJson();
        await pump();

        handler = await buildHandler();
        await handler.start();
        await pump(150);
        expect(handler.playbackState.value.controls, [MediaControl.play]);

        server.state = 'pause';
        channels.single.serverSend('{"notify":["player"]}');
        await pump(200);

        expect(handler.playbackState.value.controls, [
          MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.skipToPrevious,
        ]);
        expect(handler.mediaItem.value?.title, 'Killing Me Softly');
      },
    );

    test('R-04 the play control published while stopped is wired to the one '
        'command the server honours from stop (PUT /api/player/play), and '
        'the mirror still forwards a skip if something else asks for one '
        '(faithful mirror: the cached slice can lag the server)', () async {
      server.state = 'stop';
      server.nowPlaying = itemJson();
      await pump();

      handler = await buildHandler();
      await handler.start();
      await pump(150);

      await handler.play();
      await pump(120);
      expect(transportPuts(), contains('PUT /api/player/play'));
    });
  });
}

/// Minimal stateful OwnTone for the stopped-mirror path: `GET /api/player`
/// answers whatever [state] says (keeping `item_id` set across a stop, like
/// the real server), and `GET /api/queue?id=now_playing` keeps answering the
/// now-playing item regardless of state — the exact shape that let the old
/// `_sync` keep a live-looking card while stopped.
class StoppedServer {
  StoppedServer();

  /// The server's `state` wire value: `play`, `pause` or `stop`.
  String state = 'stop';

  /// The queue's now_playing item, or null for an empty queue.
  Map<String, dynamic>? nowPlaying;

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
            'volume': 42,
            // OwnTone keeps item_id across a stop — the retained id is why
            // the reported card still looked like a loaded track.
            'item_id': 196000,
            'item_progress_ms': state == 'stop' ? 0 : 10,
            'item_length_ms': 353512,
          });
        case '/api/queue':
          return jsonResponse(o, {
            'items': [if (nowPlaying != null) nowPlaying],
          });
      }
    }
    return jsonResponse(o, <String, dynamic>{});
  }
}
