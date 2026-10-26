import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/rating/rating_controller.dart';
import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// A stateful rating fixture: a paused player on queue item `q1` /
/// track 42, a mutable server-side rating per track, and a gateable PUT so
/// the optimistic window is observable.
class RatingServer {
  RatingServer();

  String state = 'pause';
  int trackId = 42;

  /// Server truth, per track id (null = the field is absent).
  final Map<int, int?> ratings = {42: 60, 43: 20};

  bool failPut = false;

  /// When set, the PUT resolves only after this completes (optimistic-
  /// window observation).
  Completer<void>? putGate;

  /// Every `PUT /api/library/tracks/{id}?rating=` line seen.
  final List<String> puts = [];

  FutureOr<Response<dynamic>> handle(RequestOptions o) {
    final p = o.path;
    switch (p) {
      case '/api/config':
        return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
      case '/api/player':
        return jsonResponse(o, {
          'state': state,
          'repeat': 'off',
          'consume': false,
          'shuffle': false,
          'volume': 50,
          if (state != 'stop') 'item_id': 196174,
          'item_length_ms': 100000,
          'item_progress_ms': 0,
        });
      case '/api/queue':
        // Used by PlayerController.getNowPlaying (?id=now_playing).
        return jsonResponse(o, {
          'items': [
            if (state != 'stop')
              {
                'id': 'q1',
                'track_id': trackId,
                'title': 'Current',
                'artist': 'A',
                'album': 'B',
                'length_ms': 100000,
                'uri': 'library:track:$trackId',
              },
          ],
        });
      case '/api/outputs':
        return jsonResponse(o, {'outputs': []});
    }
    if (p.startsWith('/api/library/tracks/') && o.method == 'GET') {
      final id = int.parse(p.substring('/api/library/tracks/'.length));
      return jsonResponse(o, {
        'id': id,
        'title': 'Track $id',
        'artist': 'A',
        'album': 'B',
        'album_id': '1',
        'length_ms': 100000,
        if (ratings[id] != null) 'rating': ratings[id],
        'uri': 'library:track:$id',
      });
    }
    if (p.startsWith('/api/library/tracks/') && o.method == 'PUT') {
      puts.add('${o.method} $p?${o.uri.query}');
      if (failPut) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: o, statusCode: 500),
        );
      }
      final gate = putGate;
      if (gate != null) return gate.future.then((_) => _putDone(o));
      return _putDone(o);
    }
    return Response(requestOptions: o, statusCode: 404);
  }

  Response<dynamic> _putDone(RequestOptions o) {
    final p = o.path;
    final id = int.parse(p.substring('/api/library/tracks/'.length));
    final q = o.queryParameters.map((k, v) => MapEntry(k, v.toString()));
    ratings[id] = int.parse(q['rating']!);
    return Response(requestOptions: o, statusCode: 204);
  }
}

const _cfg = ServerConfig(host: '10.0.0.5', port: 3689);

/// R-12 (unit 006): the rating slice — now-playing rating resolution
/// (now_playing → track_id → track), optimistic set + rollback, and the
/// WS `database` / item-change refresh paths.
void main() {
  late RatingServer server;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late RatingController rating;

  Future<void> pump([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  setUp(() async {
    server = RatingServer();
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
    rating = RatingController(connection: conn, player: player);
    await rating.init();
    await conn.connectTo(_cfg);
    await pump();
  });

  tearDown(() {
    rating.dispose();
    player.dispose();
    conn.dispose();
  });

  test('now-playing rating: now_playing → track_id → track (C2 flow)', () {
    expect(player.nowPlaying?.trackId, 42);
    expect(rating.nowPlayingTrackId, 42);
    expect(rating.nowPlayingRating, 60, reason: 'GET /api/library/tracks/42');
  });

  test('absent rating field reads as unrated (0), still visible', () async {
    server.ratings[42] = null;
    channels.last.serverSend('{"notify":["database"]}');
    await pump();
    expect(rating.nowPlayingTrackId, 42);
    expect(rating.nowPlayingRating, 0);
  });

  test('setRating sends the PUT and confirms from the server', () async {
    final ok = await rating.setRating(42, 100);
    expect(ok, isTrue);
    expect(server.puts.single, 'PUT /api/library/tracks/42?rating=100');
    expect(server.ratings[42], 100);
    expect(rating.nowPlayingRating, 100);
  });

  test('setRating is optimistic during the PUT', () async {
    server.putGate = Completer<void>();
    final pending = rating.setRating(42, 20);
    await pump(10);
    expect(
      rating.nowPlayingRating,
      20,
      reason: 'stars flip before the server answers',
    );
    server.putGate!.complete();
    await pending;
    expect(rating.nowPlayingRating, 20);
  });

  test(
    'failed setRating: rollback + typed error + seq (optimistic-rollback)',
    () async {
      server.failPut = true;
      final ok = await rating.setRating(42, 80);
      expect(ok, isFalse);
      expect(rating.nowPlayingRating, 60, reason: 'restored');
      expect(rating.actionError, contains('Rating failed'));
      expect(rating.actionError, contains('HTTP 500'));
      expect(rating.actionErrorSeq, 1);
    },
  );

  test(
    'WS database event refetches a rating changed elsewhere (web UI)',
    () async {
      server.ratings[42] = 40; // changed by another client, silently
      expect(rating.nowPlayingRating, 60, reason: 'stale until the event');
      channels.last.serverSend('{"notify":["database"]}');
      await pump();
      expect(rating.nowPlayingRating, 40);
    },
  );

  test('item change re-keys the rating to the new track', () async {
    server.trackId = 43;
    await player.refreshState();
    await pump();
    expect(rating.nowPlayingTrackId, 43);
    expect(rating.nowPlayingRating, 20);
  });

  test('stop clears the rating slice', () async {
    server.state = 'stop';
    await player.refreshState();
    await pump();
    expect(player.nowPlaying, isNull);
    expect(rating.nowPlayingTrackId, isNull);
    expect(rating.nowPlayingRating, isNull);
  });

  test('setRating offline: false, no PUT, no optimistic state', () async {
    conn.disconnect();
    await pump(10);
    final ok = await rating.setRating(42, 100);
    expect(ok, isFalse);
    expect(server.puts, isEmpty);
    expect(rating.nowPlayingRating, 60, reason: 'untouched');
  });
}
