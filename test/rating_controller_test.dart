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

  /// One-shot: the next track GET answers 503 (transient-error paths).
  bool failNextTrackGet = false;

  /// When set, the PUT resolves only after this completes (optimistic-
  /// window observation).
  Completer<void>? putGate;

  /// When true, a successful rating PUT does NOT commit `ratings` —
  /// `GET /api/library/tracks/{id}` keeps serving the pre-write value
  /// until [commitRating] applies it. Models the OwnTone 29.3 async rating
  /// commit measured 2026-11-17 (GET served the stale rating for 0.1–1.6 s
  /// AFTER the PUT returned 2xx).
  bool lagCommit = false;

  /// Apply a deferred PUT (pairs with [lagCommit]).
  void commitRating(int id, int value) => ratings[id] = value;

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
      if (failNextTrackGet) {
        failNextTrackGet = false;
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: o, statusCode: 503),
        );
      }
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
    if (!lagCommit) ratings[id] = int.parse(q['rating']!);
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

  RatingController fastRating({required int polls, required Duration delay}) {
    // Replace the suite's default controller with a fast-polling one (the
    // production budget is ~3 s; these tests observe the window, not the
    // real timers). tearDown disposes whatever `rating` points at.
    rating.dispose();
    rating = RatingController(
      connection: conn,
      player: player,
      confirmPolls: polls,
      confirmPollDelay: delay,
    );
    return rating;
  }

  test('async server commit: the FIRST tap sticks — stale GETs and a database '
      'event inside the commit window cannot roll the optimistic stars back '
      '(R-12; OwnTone 29.3 async rating commit measured 2026-11-17)', () async {
    // Repro of the user report: PUT 2xx returns before the server's
    // commit; GET keeps serving the pre-write rating for 0.1–1.6 s
    // (curl-sampled). Pre-fix the single confirm-GET read stale and the
    // stars snapped back — the user had to tap twice.
    server.lagCommit = true;
    final fast = fastRating(polls: 2, delay: Duration.zero);
    await fast.init();
    await pump();
    expect(fast.nowPlayingRating, 60, reason: 'baseline loaded');

    final ok = await fast.setRating(42, 100);
    expect(ok, isTrue);
    expect(server.ratings[42], 60, reason: 'fake server has NOT committed');
    expect(
      fast.nowPlayingRating,
      100,
      reason: 'optimistic survives the exhausted confirm polls',
    );

    channels.last.serverSend('{"notify":["database"]}');
    await pump();
    expect(
      fast.nowPlayingRating,
      100,
      reason: 'a ws-driven refetch landing on stale data holds the shadow',
    );

    server.commitRating(42, 100); // the async commit finally lands
    channels.last.serverSend('{"notify":["database"]}');
    await pump();
    expect(fast.nowPlayingRating, 100);

    server.commitRating(42, 40); // external edit AFTER confirmation…
    channels.last.serverSend('{"notify":["database"]}');
    await pump();
    expect(
      fast.nowPlayingRating,
      40,
      reason: 'the confirming GET cleared the shadow — external edits apply',
    );
  });

  test('async server commit: the confirm poll reconciles mid-window without '
      'any ws event (R-12)', () async {
    server.lagCommit = true;
    final fast = fastRating(polls: 30, delay: const Duration(milliseconds: 10));
    await fast.init();
    await pump();

    final pending = fast.setRating(42, 20);
    await pump(40); // a few stale polls run
    expect(
      fast.nowPlayingRating,
      20,
      reason: 'optimistic through the stale window',
    );
    // …and a ws-driven refetch landing in the same window is refused by
    // the _refreshRating guard (this also pins the guard in this test).
    channels.last.serverSend('{"notify":["database"]}');
    await pump();
    expect(fast.nowPlayingRating, 20, reason: 'stale ws event held');
    server.commitRating(42, 20); // commit lands while the budget runs
    await pending;
    expect(fast.nowPlayingRating, 20);

    server.commitRating(42, 40);
    channels.last.serverSend('{"notify":["database"]}');
    await pump();
    expect(
      fast.nowPlayingRating,
      40,
      reason: 'the matching poll cleared the shadow',
    );
  });

  test('stop inside the unconfirmed window then replay: the stars re-key and '
      'stay tappable (PR #12 review R1 — the guard shadows the VALUE, never '
      'the track-id key)', () async {
    server.lagCommit = true;
    final fast = fastRating(polls: 1, delay: Duration.zero);
    await fast.init();
    await pump();
    await fast.setRating(42, 100);
    expect(fast.nowPlayingRating, 100, reason: 'shadow held');

    server.state = 'stop';
    await player.refreshState();
    await pump();
    expect(fast.nowPlayingTrackId, isNull);

    server.state = 'pause'; // the same track replays
    await player.refreshState();
    await pump();
    expect(
      fast.nowPlayingTrackId,
      42,
      reason: 'the row renders again (a null key hides the stars entirely)',
    );
    expect(
      fast.nowPlayingRating,
      60,
      reason: 'stop dropped the shadow; server (uncommitted) value shows',
    );
  });

  test('a reconnect resyncs server truth over a stuck shadow, even when it '
      'diverges from the user write (PR #12 review R1 — the escape list '
      'claimed reconnect; now it is true)', () async {
    server.lagCommit = true;
    final fast = fastRating(polls: 1, delay: Duration.zero);
    await fast.init();
    await pump();
    await fast.setRating(42, 100);
    server.commitRating(42, 40); // server settles on a DIFFERENT value
    expect(
      fast.nowPlayingRating,
      100,
      reason: 'same connection: the guard holds (documented trade)',
    );

    conn.disconnect();
    await pump();
    await conn.connectTo(_cfg);
    await pump(150);
    expect(
      fast.nowPlayingRating,
      40,
      reason: 'a fresh connection is a resync-from-reality point',
    );
  });

  test('a WS flap without a phase edge still clears a stuck shadow via '
      'refetchAll (PR #12 review R2 — the second reconnect clear is the '
      'only escape on this path)', () async {
    server.lagCommit = true;
    final fast = fastRating(polls: 1, delay: Duration.zero);
    await fast.init();
    await pump();
    await fast.setRating(42, 100);
    server.commitRating(42, 40); // server settles elsewhere
    expect(fast.nowPlayingRating, 100, reason: 'shadow holds, same socket');

    channels.last.serverClose(); // flap: server drops the websocket
    await pump();
    await pump(300); // ws backoff reconnect (test backoff is ~5-20 ms)
    expect(
      fast.nowPlayingRating,
      40,
      reason: 'reconnect resyncs server truth via refetchAll',
    );
  });

  test('a transient confirm-GET error keeps the poll window (PR #12 review '
      'R2 — continue, not abandon)', () async {
    server.lagCommit = true;
    final fast = fastRating(polls: 40, delay: const Duration(milliseconds: 10));
    await fast.init();
    await pump();
    server.failNextTrackGet = true; // first confirm poll 503s
    final pending = fast.setRating(42, 20);
    await pump(40);
    expect(fast.nowPlayingRating, 20, reason: 'window alive past error');
    server.commitRating(42, 20);
    await pending;
    expect(fast.nowPlayingRating, 20);
    // Prove the poll (not the hold) produced that state — a loop that
    // had ABANDONED on the 503 would leave the shadow masking a later
    // external edit (mutation-checked: continue→return reddens this).
    server.commitRating(42, 40);
    channels.last.serverSend('{"notify":["database"]}');
    await pump();
    expect(
      fast.nowPlayingRating,
      40,
      reason: 'poll continued past the error, matched, and cleared',
    );
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
      // Pin the rollback's shadow-release (PR #12 R1 mutation-check): a
      // failed write left shadowing the track would mask every later
      // external edit of it.
      server.failPut = false;
      server.commitRating(42, 30);
      channels.last.serverSend('{"notify":["database"]}');
      await pump();
      expect(
        rating.nowPlayingRating,
        30,
        reason: 'rollback released the shadow completely',
      );
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
