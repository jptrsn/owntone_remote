import 'package:dio/dio.dart';

import '../library/library_models.dart';
import '../outputs/output.dart';
import '../player/player_state.dart';
import '../queue/queue_item.dart';

/// Thin OwnTone JSON API client (docs/API.md). One instance per configured
/// server; the base URL is set by the ConnectionController (R-01).
class OwntoneApi {
  OwntoneApi({required Dio dio, required Uri baseUrl})
    : _dio = dio,
      _baseUrl = baseUrl;

  final Dio _dio;
  final Uri _baseUrl;

  Uri get baseUrl => _baseUrl;

  Future<Map<String, dynamic>> getConfig() async {
    final res = await _dio.get('/api/config');
    return res.data as Map<String, dynamic>;
  }

  Future<PlayerState> getPlayer() async {
    final res = await _dio.get('/api/player');
    return PlayerState.fromJson(res.data as Map<String, dynamic>);
  }

  /// Now-playing item, or null when stopped / no queue item (R-03).
  Future<NowPlayingItem?> getNowPlaying() async {
    final res = await _dio.get(
      '/api/queue',
      queryParameters: const {'id': 'now_playing'},
    );
    final data = res.data as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? const [];
    if (items.isEmpty) return null;
    return NowPlayingItem.fromJson(
      items.first as Map<String, dynamic>,
      _baseUrl,
    );
  }

  Future<List<Output>> getOutputs() async {
    final res = await _dio.get('/api/outputs');
    final data = res.data as Map<String, dynamic>;
    final list = data['outputs'] as List<dynamic>? ?? const [];
    return [for (final e in list) Output.fromJson(e as Map<String, dynamic>)];
  }

  // -- Library browse (R-10, unit 005a) ------------------------------------

  Future<Paging<Playlist>> playlists({int offset = 0, int limit = 50}) async {
    final res = await _dio.get(
      '/api/library/playlists',
      queryParameters: {'offset': offset, 'limit': limit},
    );
    return Paging.fromJson(res.data as Map<String, dynamic>, Playlist.fromJson);
  }

  Future<Paging<Track>> playlistTracks(
    String id, {
    int offset = 0,
    int limit = 50,
  }) async {
    final res = await _dio.get(
      '/api/library/playlists/$id/tracks',
      queryParameters: {'offset': offset, 'limit': limit},
    );
    return Paging.fromJson(res.data as Map<String, dynamic>, Track.fromJson);
  }

  Future<Paging<Artist>> artists({int offset = 0, int limit = 50}) async {
    final res = await _dio.get(
      '/api/library/artists',
      queryParameters: {'offset': offset, 'limit': limit},
    );
    return Paging.fromJson(res.data as Map<String, dynamic>, Artist.fromJson);
  }

  Future<Paging<Album>> artistAlbums(
    String id, {
    int offset = 0,
    int limit = 50,
  }) async {
    final res = await _dio.get(
      '/api/library/artists/$id/albums',
      queryParameters: {'offset': offset, 'limit': limit},
    );
    return Paging.fromJson(res.data as Map<String, dynamic>, Album.fromJson);
  }

  Future<Paging<Album>> albums({int offset = 0, int limit = 50}) async {
    final res = await _dio.get(
      '/api/library/albums',
      queryParameters: {'offset': offset, 'limit': limit},
    );
    return Paging.fromJson(res.data as Map<String, dynamic>, Album.fromJson);
  }

  Future<Paging<Track>> albumTracks(
    String id, {
    int offset = 0,
    int limit = 50,
  }) async {
    final res = await _dio.get(
      '/api/library/albums/$id/tracks',
      queryParameters: {'offset': offset, 'limit': limit},
    );
    return Paging.fromJson(res.data as Map<String, dynamic>, Track.fromJson);
  }

  /// Every library track, in server (name) order — the Songs list (R-15).
  ///
  /// There is **no `GET /api/library/tracks` collection route** on this
  /// server: the 29.3 JSON-API route table carries only
  /// `/api/library/tracks/{id}` (GET/PUT), the batch PUT, and the
  /// track→playlists GET (source-checked + live 400 for every parameter
  /// combination, 2026-11-20). The all-tracks list therefore rides the
  /// proven search endpoint — the same route [genreAlbums] uses:
  /// `GET /api/search?type=tracks&query=` where the server's empty-query
  /// branch is `title LIKE '%%'` (source: `search_tracks`), i.e. every
  /// track, `Q_ITEMS` sorted by name (`title_sort`). Verified live
  /// 2026-11-20: total 3265; `offset=100` (page 3 at the default limit 50)
  /// serves distinct rows.
  /// Do NOT "simplify" this onto `/api/library/tracks` — it does not exist.
  Future<Paging<Track>> tracks({int offset = 0, int limit = 50}) =>
      _searchGroup('tracks', '', Track.fromJson, offset: offset, limit: limit);

  /// `GET /api/library/genres` — this server ignores `offset`/`limit`
  /// (verified live 2026-10-23: `limit=3` returned all 79 genres), so no
  /// paging parameters are sent; the response is still modeled as
  /// [Paging].
  Future<Paging<Genre>> genres() async {
    final res = await _dio.get('/api/library/genres');
    return Paging.fromJson(res.data as Map<String, dynamic>, Genre.fromJson);
  }

  /// Genre → albums via the search endpoint (docs/API.md):
  /// `GET /api/search?type=albums&expression=genre is "…"`.
  ///
  /// The expression is pre-encoded with [Uri.encodeComponent] and placed in
  /// the path rather than `queryParameters`: dio 5.11 percent-encodes
  /// string query values with `Uri.encodeQueryComponent`, which would
  /// (a) double-encode an already-encoded value and (b) emit `+` for
  /// spaces instead of the spec'd `%20` (unit 005a C4). An existing query
  /// string in the path is left untouched.
  Future<Paging<Album>> genreAlbums(
    String genre, {
    int offset = 0,
    int limit = 50,
  }) async {
    final expression = Uri.encodeComponent(genreExpression(genre));
    final res = await _dio.get(
      '/api/search?type=albums&expression=$expression'
      '&offset=$offset&limit=$limit',
    );
    final data = res.data as Map<String, dynamic>;
    return Paging.fromJson(
      data['albums'] as Map<String, dynamic>,
      Album.fromJson,
    );
  }

  // -- Search (R-13, unit 007) ------------------------------------------------

  /// One result group of `GET /api/search` (docs/API.md): the server answers
  /// one `paging` object per requested `type`, with `offset`/`limit` applied
  /// per group — so each group pages independently by re-requesting just its
  /// type. A missing group key (type not requested) parses as empty.
  ///
  /// The query is pre-encoded with [Uri.encodeComponent] and placed in the
  /// path rather than `queryParameters` — the same dio trap as [genreAlbums]
  /// (unit 005a C4): `encodeQueryComponent` writes spaces as `+`, which this
  /// server does not decode back to a space in a search query.
  Future<Paging<T>> _searchGroup<T>(
    String type,
    String query,
    T Function(Map<String, dynamic>) fromJson, {
    required int offset,
    required int limit,
  }) async {
    final res = await _dio.get(
      '/api/search?type=$type&query=${Uri.encodeComponent(query)}'
      '&offset=$offset&limit=$limit',
    );
    final data = res.data as Map<String, dynamic>;
    final group = data[type];
    if (group is! Map<String, dynamic>) {
      return const Paging(items: [], total: 0, offset: 0, limit: -1);
    }
    return Paging.fromJson(group, fromJson);
  }

  Future<Paging<Track>> searchTracks(
    String query, {
    int offset = 0,
    int limit = 25,
  }) => _searchGroup(
    'tracks',
    query,
    Track.fromJson,
    offset: offset,
    limit: limit,
  );

  Future<Paging<Artist>> searchArtists(
    String query, {
    int offset = 0,
    int limit = 25,
  }) => _searchGroup(
    'artists',
    query,
    Artist.fromJson,
    offset: offset,
    limit: limit,
  );

  Future<Paging<Album>> searchAlbums(
    String query, {
    int offset = 0,
    int limit = 25,
  }) => _searchGroup(
    'albums',
    query,
    Album.fromJson,
    offset: offset,
    limit: limit,
  );

  Future<Paging<Playlist>> searchPlaylists(
    String query, {
    int offset = 0,
    int limit = 25,
  }) => _searchGroup(
    'playlists',
    query,
    Playlist.fromJson,
    offset: offset,
    limit: limit,
  );

  // -- Rating (R-12, unit 006) ----------------------------------------------

  /// Single library track — the rating lives on the track, not on the queue
  /// item (unit 006: now-playing rating resolves
  /// `GET /api/queue?id=now_playing` → `track_id` → this endpoint).
  Future<Track> getTrack(int id) async {
    final res = await _dio.get('/api/library/tracks/$id');
    return Track.fromJson(res.data as Map<String, dynamic>);
  }

  /// `PUT /api/library/tracks/{id}?rating=` → 204 (docs/API.md). The one
  /// approved library mutation (AGENTS.md §4) — **supervised**: only inside
  /// a recorded user-confirmed window, with the original value restored
  /// afterwards. [rating] is the server's 0–100 scale; the UI sends the
  /// canonical 0/20/40/60/80/100 via `ratingForStars`.
  Future<void> setRating(int id, int rating) =>
      _put('/api/library/tracks/$id', {'rating': rating.clamp(0, 100)});

  // -- Queue (R-11, unit 005b) ----------------------------------------------

  /// The whole queue in server order (`GET /api/queue`).
  Future<List<QueueItem>> getQueue() async {
    final res = await _dio.get('/api/queue');
    final data = res.data as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? const [];
    return [
      for (final e in items)
        QueueItem.fromJson(e as Map<String, dynamic>, _baseUrl),
    ];
  }

  /// `PUT /api/queue/clear` — 204. Safe while paused/stopped (no audio
  /// flows); while playing it empties the live session's remaining items.
  Future<void> clearQueue() => _put('/api/queue/clear');

  /// Queue play (docs/API.md): **one** `POST /api/queue/items/add` replaces
  /// the clear→add→play ceremony. [uris] are the play targets
  /// (`library:track:…`, `library:album:…`, …) comma-joined server-side.
  /// [startPlayback] is the supervised path — it makes the server play.
  Future<List<QueueItem>> playUris(
    List<String> uris, {
    bool clear = false,
    bool startPlayback = false,
  }) async {
    final query = <String, dynamic>{'uris': uris.join(',')};
    if (clear) query['clear'] = 'true';
    if (startPlayback) query['playback'] = 'start';
    final res = await _dio.post('/api/queue/items/add', queryParameters: query);
    final data = res.data as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? const [];
    return [
      for (final e in items)
        QueueItem.fromJson(e as Map<String, dynamic>, _baseUrl),
    ];
  }

  /// Queue add WITHOUT playback change (R-19, issue #41): `POST
  /// /api/queue/items/add` with `playback=add` and **no `clear`** — Play
  /// Next / Add to Up Next. `playback=add` verified live 2026-11-20:
  /// accepted (200), player state stays `pause`.
  ///
  /// [position] is sent ONLY when non-null. Official json-api docs
  /// (docs-mcp 2026-11-20): "new items are inserted starting from this
  /// position" — the first added item ENDS UP at [position]. R-19 uses it
  /// for 0 (Play Next, list head) and the current length (Add to Up Next,
  /// tail); R-24's queue-row Play Next (issue #47, QueueController.playNext)
  /// reuses THIS method with `position = current + 1` — one position
  /// variant, deliberately not a duplicated add method. It must also stay
  /// the no-clear path: live-verified 2026-11-20, a position beyond the real length is treated like an
  /// omitted one — and with the server's shuffle mode on, an omitted/
  /// out-of-range position inserts at a RANDOM slot inside the unplayed
  /// region (observed 640/597/1061 in a 1396-item queue), not the tail.
  /// The caller (QueueController.addUris) passes its live queue length;
  /// do not "simplify" the tail case to omitting the position.
  /// The add-time `shuffle` param is deliberately never sent: it is the
  /// GLOBAL shuffle-mode setter (live-verified 2026-11-20 — `shuffle=false`
  /// on an add flipped `/api/player`'s shuffle), so using it would mutate
  /// the server-wide flag R-19 says to leave alone.
  Future<List<QueueItem>> addUris(List<String> uris, {int? position}) async {
    final query = <String, dynamic>{'uris': uris.join(','), 'playback': 'add'};
    if (position != null) query['position'] = position;
    final res = await _dio.post('/api/queue/items/add', queryParameters: query);
    final data = res.data as Map<String, dynamic>;
    final items = data['items'] as List<dynamic>? ?? const [];
    return [
      for (final e in items)
        QueueItem.fromJson(e as Map<String, dynamic>, _baseUrl),
    ];
  }

  /// Queue-skip (issue #21, R-11): make an already-queued entry the current
  /// track, IN PLACE — the queue content is untouched (no add, no clear),
  /// only the current item moves. This is the OwnTone web UI's own queue-row
  /// click: read from the served webplayer JS on 2026-11-19, the
  /// `ListItemQueueItem` row handler is `IS.play({item_id})` → `PUT
  /// /api/player/play?item_id=…` (the queue-entry id). The `new_position`
  /// queue-item PUT
  /// is drag-reorder only and does NOT change the current track — do not
  /// "simplify" this onto it. [entryId] is the queue-entry `id` (same id the
  /// player reports as `item_id`, verified live 2026-10-23).
  /// SUPERVISED: it starts/keeps playback on a track (real speakers).
  Future<void> skipToQueueItem(String entryId) =>
      _put('/api/player/play', {'item_id': entryId});

  /// Drag-reorder (R-23, issue #46): move a queue entry to an absolute
  /// position — `PUT /api/queue/items/{id}?new_position=N` (`docs/API.md:94`;
  /// param name + QUERY placement verified 2026-11-20 against the official
  /// ownTone-server json-api docs via docs-mcp — `new_position` is the
  /// entry's FINAL 0-based index, the server move is remove + insert-at-N,
  /// not a delta and not a swap; the optimistic reorder in
  /// `QueueController.moveItem` mirrors exactly that). 204 on success. A
  /// queue edit WITHOUT `playback=start` — safe while paused (AGENTS safe
  /// list). The now-playing entry is pinned client-side (R-23: the web UI
  /// never drags it; server-side behaviour deliberately unprobed on the
  /// shared fixture — issue-46 report ASSUMPTIONS).
  Future<void> moveQueueItem(String entryId, int newPosition) =>
      _put('/api/queue/items/$entryId', {'new_position': newPosition});

  /// Per-row Remove (R-24, issue #47): delete ONE queue entry —
  /// `DELETE /api/queue/items/{id}` (`docs/API.md:95`; official json-api
  /// docs via docs-mcp 2026-11-20 — 204 on success). A queue edit WITHOUT
  /// `playback=start`: safe while paused (AGENTS safe list). Keyed on the
  /// queue-entry `id` (never an index) — the hide-cut can shift indices
  /// between build and tap, it cannot shift ids.
  Future<void> deleteQueueItem(String entryId) =>
      _dio.delete('/api/queue/items/$entryId');

  Future<void> play() => _put('/api/player/play');
  Future<void> pause() => _put('/api/player/pause');
  Future<void> stop() => _put('/api/player/stop');
  Future<void> next() => _put('/api/player/next');
  Future<void> previous() => _put('/api/player/previous');

  Future<void> seekMs(int positionMs) =>
      _put('/api/player/seek', {'position_ms': positionMs});

  Future<void> setShuffle(bool on) =>
      _put('/api/player/shuffle', {'state': on});

  Future<void> setRepeat(Repeat mode) =>
      _put('/api/player/repeat', {'state': mode.wire});

  Future<void> setConsume(bool on) =>
      _put('/api/player/consume', {'state': on});

  Future<void> setVolume(int volume) =>
      _put('/api/player/volume', {'volume': volume});

  /// Relative volume change — the volume-rocker path (±5 per press).
  Future<void> stepVolume(int step) =>
      _put('/api/player/volume', {'step': step});

  /// Per-output volume (R-09). OwnTone 29.3 takes `output_id` on the same
  /// player-volume endpoint as the master volume.
  Future<void> setOutputVolume(String outputId, int volume) =>
      _put('/api/player/volume', {'volume': volume, 'output_id': outputId});

  /// Enables exactly this set of outputs and disables the rest — one call
  /// for multi-select, never N per-output toggles (R-09, docs/API.md).
  Future<void> setOutputs(List<String> outputIds) =>
      _dio.put('/api/outputs/set', data: {'outputs': outputIds});

  /// Per-output write used by the PIN flow (R-09): enabling a
  /// `has_password` / `needs_auth_key` output sends `selected: true` plus
  /// the `pin` on the single-output endpoint — `/outputs/set` has no pin
  /// parameter.
  Future<void> setOutput(
    String outputId, {
    bool? selected,
    int? volume,
    String? pin,
  }) async {
    final body = <String, dynamic>{
      'selected': ?selected,
      'volume': ?volume,
      'pin': ?pin,
    };
    await _dio.put('/api/outputs/$outputId', data: body);
  }

  Future<void> _put(String path, [Map<String, dynamic>? query]) =>
      _dio.put(path, queryParameters: query);
}
