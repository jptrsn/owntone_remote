import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/audio/mirror_handler.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/artwork_probe.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/player/player_state.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_artwork_http_gated.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// R-03 unit 010 — TEST-ADVERSARY suite for the mirror_handler `artUri`
/// gate (the second fetch site of the unit's Goal 1). Falsification targets
/// taken from the unit contract (`.ai-dlc/remote-app/units/010-artwork-204-
/// filter.md` lines 110-119): `_sync()` awaits `isNoArtwork(item.artworkUrl)`
/// and publishes with `hideArtwork: true` on a probed 204, with a claimed
/// stale-publish guard `_sameNowPlaying` across the await. These tests race
/// a mediaItem republish against a pending probe and try to produce (a) a
/// NEW item keeping a hidden artUri it shouldn't, or (b) a shown artUri for
/// a 204, and pin the one-GET-per-URL / verdict-consistency clauses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GatedArtworkHttp http;
  setUpAll(() => http = GatedArtworkHttp.installOnce());
  tearDownAll(() => HttpOverrides.global = null);

  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);
  final webRoot = Uri.parse('http://10.0.0.5:3689/');

  Future<void> pump([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Map<String, dynamic> itemJson(String title, String artworkId) => {
    'id': '1',
    'track_id': 197001,
    'title': title,
    'artist': 'Adv',
    'album': 'AA',
    'length_ms': 1000,
    'uri': 'library:track:197001',
    'artwork_url': './artwork/item/$artworkId',
  };

  late ArtworkServer server;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;

  setUp(() async {
    server = ArtworkServer();
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

  Future<MirrorAudioHandler> startHandler() async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.create();
    final handler = MirrorAudioHandler(player, settings: store);
    return handler;
  }

  void setNowPlaying(Map<String, dynamic>? json) {
    server.nowPlaying = json;
    channels.single.serverSend('{"notify":["queue"]}');
  }

  group('mirror artUri gate — republish races (R-03, unit 010)', () {
    test('stale-publish guard FALSIFICATION attempt: a late 204 probe for a '
        'REPLACED item must not clobber the NEW item\'s shown artUri — the '
        '200 item publishes with artUri and no stale publish hides it (unit '
        'lines 116-118: "stale-publish guard _sameNowPlaying across the '
        'await")', () async {
      final idA = nextArtworkId('mA1a');
      final idB = nextArtworkId('mA1b');
      http.serve(idA, status: 204);
      http.hang(idA);
      http.serve(idB, status: 200, body: 'png');

      setNowPlaying(itemJson('Alpha', idA));
      await pump(120);
      final handler = await startHandler();
      final published = <MediaItem?>[];
      final sub = handler.mediaItem.listen(published.add);

      final started = handler.start();
      await pump(80);
      expect(
        published.whereType<MediaItem>(),
        isEmpty,
        reason:
            'sync1 parked behind the hung probe (a leading null is the '
            'BehaviorSubject seed, not a publish)',
      );

      setNowPlaying(itemJson('Beta', idB));
      await pump(150); // sync2 probes B (immediate) and publishes
      final beta = handler.mediaItem.value;
      expect(beta?.title, 'Beta');
      expect(
        beta?.artUri,
        artworkUri(idB),
        reason: 'the new 200 item shows its artUri',
      );

      http.release(idA);
      await started;
      await pump(150);
      await sub.cancel();

      expect(
        published.where((m) => m?.title == 'Beta' && m?.artUri == null),
        isEmpty,
        reason: 'the late stale 204 for the replaced Alpha hid Beta\'s art',
      );
      expect(
        published.where((m) => m?.title == 'Alpha'),
        isEmpty,
        reason: 'the blocked stale sync never published Alpha at all',
      );
      expect(
        http.requestCount(idA),
        1,
        reason: 'the stale probe ran exactly once (no retry storm)',
      );
    });

    test('the reverse race: a 204 item swapping in behind a hung probe is '
        'NEVER published with a shown artUri, and its late true verdict '
        'publishes artUri null (unit lines 110-113: "never publish an '
        'artUri the server answers with 204")', () async {
      final idA = nextArtworkId('mA2a');
      final idB = nextArtworkId('mA2b');
      http.serve(idA, status: 200, body: 'png');
      http.serve(idB, status: 204);
      http.hang(idB);

      setNowPlaying(itemJson('Alpha', idA));
      await pump(120);
      final handler = await startHandler();
      final published = <MediaItem?>[];
      final sub = handler.mediaItem.listen(published.add);
      await handler.start();
      expect(handler.mediaItem.value?.title, 'Alpha');
      expect(handler.mediaItem.value?.artUri, artworkUri(idA));

      setNowPlaying(itemJson('Beta', idB));
      await pump(150);
      expect(
        published.where((m) => m?.title == 'Beta'),
        isEmpty,
        reason:
            'no premature Beta publish while the probe is pending — the '
            'gate decides BEFORE publishing (unit 010 shape)',
      );

      http.release(idB);
      await pump(150);
      await sub.cancel();
      expect(handler.mediaItem.value?.title, 'Beta');
      expect(
        handler.mediaItem.value?.artUri,
        isNull,
        reason: 'the probed 204 publishes with artUri null',
      );
      expect(
        published.where((m) => m?.title == 'Beta' && m?.artUri != null),
        isEmpty,
        reason: 'a 204 was never published with a shown artUri',
      );
      expect(http.requestCount(idB), 1);
    });

    test(
      'guard must not DROP metadata: a same-item refetch (fresh instance, '
      'identical identity fields — PlayerController replaces _nowPlaying '
      'on every GET /api/queue, unit line 117) during a pending probe '
      'still yields exactly one, correctly-hidden publish — one GET total',
      () async {
        final idA = nextArtworkId('mA3');
        http.serve(idA, status: 204);
        http.hang(idA);

        setNowPlaying(itemJson('Alpha', idA));
        await pump(120);
        final handler = await startHandler();
        final published = <MediaItem?>[];
        final sub = handler.mediaItem.listen(published.add);
        final started = handler.start();
        await pump(80);

        setNowPlaying(itemJson('Alpha', idA)); // same item, fresh instance
        await pump(120);

        http.release(idA);
        await started;
        await pump(150);
        await sub.cancel();

        expect(
          published.where((m) => m?.title == 'Alpha' && m?.artUri == null),
          isNotEmpty,
          reason: 'the (correct) publish is not dropped by the guard',
        );
        expect(
          published.where((m) => m?.title == 'Alpha' && m?.artUri != null),
          isEmpty,
        );
        expect(http.requestCount(idA), 1, reason: 'shared cached Future held');
      },
    );

    test('probe identity at the mirror site: exactly ONE plain GET per '
        'artwork URL across repeated notifies — no maxwidth rewrite at this '
        'site (unit Result fetch profile: plain mirror probe), no retry '
        'storm (unit lines 90-93)', () async {
      final idA = nextArtworkId('mA4');
      http.serve(idA, status: 200, body: 'png');
      setNowPlaying(itemJson('Alpha', idA));
      await pump(120);
      final handler = await startHandler();
      await handler.start();
      for (var i = 0; i < 3; i++) {
        setNowPlaying(itemJson('Alpha', idA));
        await pump(120);
      }
      expect(
        http.requestCount(idA),
        1,
        reason: 'start + four syncs shared one probe GET',
      );
      expect(
        http.requests.where((r) => r.contains('/artwork/item/$idA?')),
        isEmpty,
        reason:
            'the mirror probes the raw artworkUrl (no maxwidth) — the '
            'unit-005a maxwidth contract belongs to ArtworkBox only',
      );
    });
  });

  group('mediaItemFor purity (R-03, unit 010)', () {
    test('hideArtwork defaults to false — a cached 204 verdict must not '
        'leak into the pure mapping (unit lines 114-115: "mediaItemFor '
        'gained the optional hideArtwork param (default false — its '
        'pure-function tests unchanged)")', () async {
      final idP = nextArtworkId('pure');
      http.serve(idP, status: 204);
      final url = artworkUri(idP);
      expect(await ArtworkProbe.isNoArtwork(url), isTrue); // cache poisoned

      final item = NowPlayingItem.fromJson(itemJson('Pure', idP), webRoot);
      final p = PlayerState(
        state: 'pause',
        repeat: Repeat.off,
        consume: false,
        shuffle: false,
        volume: 40,
        itemId: 197001,
        itemLengthMs: 1000,
        itemProgressMs: 10,
      );
      expect(
        mediaItemFor(item: item, p: p)!.artUri,
        url,
        reason: 'default call site unaffected by the probe cache',
      );
      expect(
        mediaItemFor(item: item, p: p, hideArtwork: true)!.artUri,
        isNull,
        reason: 'the opt-in gate still works',
      );
    });
  });
}

/// Minimal stateful OwnTone for the mirror path: player (pause, with item),
/// config, and a `GET /api/queue?id=now_playing` slice whose item the tests
/// swap at will (a WS `queue` notify triggers the refetch).
class ArtworkServer {
  ArtworkServer();

  Map<String, dynamic>? nowPlaying;

  Response<dynamic> handle(RequestOptions o) {
    if (o.method == 'GET') {
      switch (o.path) {
        case '/api/config':
          return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
        case '/api/player':
          return jsonResponse(o, {
            'state': 'pause',
            'repeat': 'off',
            'consume': false,
            'shuffle': false,
            'volume': 42,
            'item_id': 197001,
            'item_progress_ms': 10,
            'item_length_ms': 1000,
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
