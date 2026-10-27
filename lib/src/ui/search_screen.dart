import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/owntone_api.dart';
import '../connection/connection_controller.dart';
import '../library/library_models.dart';
import '../library/paged_list.dart';
import '../queue/queue_controller.dart';
import 'browse_rows.dart';
import 'browse_screen_scaffold.dart';
import 'browse_screens.dart';
import 'list_states.dart';

/// Search of the OwnTone library (R-13, unit 007):
/// `GET /api/search?type=…&query=` per result group (tracks, artists,
/// albums, playlists), rendered as grouped sections of the shared browse
/// rows, each group paging independently (server `offset`/`limit`) behind a
/// per-group "Load more". Rows reuse `browse_rows.dart` so visuals and
/// semantics labels cannot drift from the browse screens; tapping a
/// collection row opens the same detail screens the browse lists use.
///
/// Distinct states (R-13): the empty query never queries the server (idle
/// hint), a query whose every group comes back empty shows the no-results
/// state, and a failed search shows the error state with retry — the three
/// are never conflated. The query is debounced so typing is one burst of
/// requests, not one per keystroke.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  /// Keystroke quiescence before the query goes out.
  static const debounce = Duration(milliseconds: 300);

  /// Results per group per page (the app's search page size).
  static const pageSize = 25;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _field = TextEditingController();
  Timer? _debounce;

  /// The query the currently-rendered groups belong to (null = idle: empty
  /// query, nothing searched).
  String? _query;

  PagedList<Track>? _tracks;
  PagedList<Artist>? _artists;
  PagedList<Album>? _albums;
  PagedList<Playlist>? _playlists;

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      _disposeLists();
      setState(() => _query = null);
      return;
    }
    _debounce = Timer(SearchScreen.debounce, () => _runSearch(value));
  }

  void _runSearch(String raw) {
    _debounce?.cancel();
    final q = raw.trim();
    _disposeLists();
    if (q.isEmpty) {
      setState(() => _query = null);
      return;
    }
    // The conn is captured so each fetch resolves the *current* API client
    // at call time (same contract as PagedBrowseScreen.buildList).
    final conn = context.read<ConnectionController>();
    PagedList<T> make<T>(
      Future<Paging<T>> Function(int offset, int limit, OwntoneApi api) fetch,
      String Function(T item) keyOf,
    ) {
      final list = PagedList<T>(
        fetch: (offset, limit) {
          final api = conn.api;
          if (api == null) throw StateError('no api');
          return fetch(offset, limit, api);
        },
        keyOf: keyOf,
        pageSize: SearchScreen.pageSize,
      );
      list.addListener(_rebuild);
      return list;
    }

    _tracks = make<Track>(
      (o, l, api) => api.searchTracks(q, offset: o, limit: l),
      (t) => t.id.toString(),
    );
    _artists = make<Artist>(
      (o, l, api) => api.searchArtists(q, offset: o, limit: l),
      (a) => a.id,
    );
    _albums = make<Album>(
      (o, l, api) => api.searchAlbums(q, offset: o, limit: l),
      (a) => a.id,
    );
    _playlists = make<Playlist>(
      (o, l, api) => api.searchPlaylists(q, offset: o, limit: l),
      (p) => p.id,
    );
    setState(() => _query = q);
    if (conn.isConnected) _eachList((l) => unawaited(l.loadFirst()));
  }

  void _disposeLists() {
    for (final l in <PagedList<dynamic>?>[
      _tracks,
      _artists,
      _albums,
      _playlists,
    ]) {
      l?.dispose();
    }
    _tracks = _artists = _albums = _playlists = null;
  }

  void _eachList(void Function(PagedList<dynamic> list) action) {
    for (final l in <PagedList<dynamic>?>[
      _tracks,
      _artists,
      _albums,
      _playlists,
    ]) {
      if (l != null) action(l);
    }
  }

  /// Reconnect (BrowseScreenScaffold): already-tried lists refetch, lists
  /// that never started (searched while offline) start now.
  void _onReconnect() {
    _eachList((l) => unawaited(l.started ? l.reload() : l.loadFirst()));
  }

  /// WS `database`/`update` while connected: refetch what is on screen
  /// (R-02 — every event is an invalidation).
  void _onLibraryChanged() {
    _eachList((l) {
      if (l.started) unawaited(l.reload());
    });
  }

  void _retryAll() {
    _eachList((l) => unawaited(l.retry()));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _disposeLists();
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BrowseScreenScaffold(
      title: 'Search',
      onReconnect: _onReconnect,
      onLibraryChanged: _onLibraryChanged,
      body: _Body(state: this),
    );
  }
}

/// The screen body: search field + the grouped results (or the state that
/// replaces them). A separate widget only to keep the state class about
/// state; it reads everything through [_SearchScreenState].
class _Body extends StatelessWidget {
  const _Body({required this.state});

  final _SearchScreenState state;

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final enabled = conn.phase == ConnectionPhase.connected;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            key: const ValueKey('search-field'),
            controller: state._field,
            textInputAction: TextInputAction.search,
            onChanged: state._onChanged,
            onSubmitted: state._runSearch,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search the library',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: state._field,
                builder: (context, value, _) => value.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        key: const ValueKey('search-clear'),
                        icon: const Icon(Icons.close),
                        tooltip: 'Clear',
                        onPressed: () {
                          state._field.clear();
                          state._onChanged('');
                        },
                      ),
              ),
            ),
          ),
        ),
        Expanded(child: _results(context, enabled)),
      ],
    );
  }

  Widget _results(BuildContext context, bool enabled) {
    final lists = <PagedList<dynamic>>[
      for (final l in <PagedList<dynamic>?>[
        state._tracks,
        state._artists,
        state._albums,
        state._playlists,
      ])
        ?l,
    ];
    // Idle: empty query, nothing searched (also the pre-first-search
    // state). No server request has gone out.
    if (state._query == null || lists.length < 4) {
      return const Center(
        child: ListEmptyState(
          icon: Icons.search,
          message: 'Type to search the library.',
        ),
      );
    }
    // Searched while offline: wait for the connection rather than spin.
    if (lists.every((l) => !l.started && !enabled)) {
      return const Center(child: Text('Waiting for the server…'));
    }
    // Every group failed its first page → the whole search failed.
    if (lists.every((l) => !l.hasLoaded && l.error != null)) {
      return Center(
        child: ListErrorState(
          what: 'search results',
          message: lists.first.error!,
          enabled: enabled,
          onRetry: state._retryAll,
        ),
      );
    }
    // Some group still waiting on its first page.
    if (!lists.every((l) => l.hasLoaded || l.error != null)) {
      return const ListSkeletonRows(rows: 6);
    }
    if (!lists.any((l) => l.items.isNotEmpty)) {
      // All groups answered (or failed) with nothing: the distinct
      // no-results state — never the idle hint, never an empty list.
      return Center(
        key: const ValueKey('search-no-results'),
        child: ListEmptyState(
          icon: Icons.search_off,
          message: 'No results for "${state._query}".',
        ),
      );
    }

    final rows = <Widget>[];
    void add<T>(
      String type,
      String label,
      PagedList<T> list,
      Widget Function(T item) row,
    ) {
      if (list.hasLoaded && list.items.isEmpty && list.error == null) {
        return; // empty groups are hidden — results stay grouped + compact
      }
      rows.add(
        _GroupHeader(
          type: type,
          label: label,
          total: list.hasLoaded ? list.total : null,
        ),
      );
      for (final item in list.items) {
        rows.add(
          Padding(padding: const EdgeInsets.only(bottom: 8), child: row(item)),
        );
      }
      if (list.error != null) {
        rows.add(
          _GroupErrorRow(
            type: type,
            message: list.error!,
            enabled: enabled,
            onRetry: () => unawaited(list.retry()),
          ),
        );
      } else if (!list.exhausted) {
        rows.add(
          _LoadMoreRow(
            type: type,
            loading: list.loading,
            enabled: enabled,
            onLoadMore: () => unawaited(list.loadNext()),
          ),
        );
      }
    }

    final queue = context.read<QueueController>();
    add<Track>(
      'tracks',
      'Tracks',
      state._tracks!,
      (t) => TrackRow(
        track: t,
        enabled: enabled,
        showArtist: true,
        onRate: rateTrack(context, t.id),
        onPlay: () => unawaited(queue.playUris([t.uri])),
      ),
    );
    add<Artist>(
      'artists',
      'Artists',
      state._artists!,
      (a) => ArtistRow(
        artist: a,
        enabled: enabled,
        onOpen: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ArtistAlbumsScreen(artist: a),
          ),
        ),
        onPlay: () => unawaited(queue.playUris(['library:artist:${a.id}'])),
      ),
    );
    add<Album>(
      'albums',
      'Albums',
      state._albums!,
      (a) => AlbumRow(
        album: a,
        enabled: enabled,
        onOpen: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => AlbumTracksScreen(album: a)),
        ),
        onPlay: () => unawaited(queue.playUris([a.uri])),
      ),
    );
    add<Playlist>(
      'playlists',
      'Playlists',
      state._playlists!,
      (p) => PlaylistRow(
        playlist: p,
        enabled: enabled,
        onOpen: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PlaylistTracksScreen(playlist: p),
          ),
        ),
        onPlay: () => unawaited(queue.playUris([p.uri])),
      ),
    );

    return ListView(padding: const EdgeInsets.all(8), children: rows);
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.type,
    required this.label,
    required this.total,
  });

  final String type;
  final String label;

  /// Server `total` for the group (null while its first page hasn't
  /// landed — label only then).
  final int? total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(
        key: ValueKey('search-group-$type'),
        total == null ? label : '$label · $total',
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _LoadMoreRow extends StatelessWidget {
  const _LoadMoreRow({
    required this.type,
    required this.loading,
    required this.enabled,
    required this.onLoadMore,
  });

  final String type;
  final bool loading;
  final bool enabled;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Center(
      child: TextButton(
        key: ValueKey('load-more-$type'),
        onPressed: enabled ? onLoadMore : null,
        child: Text('Load more ($type)'),
      ),
    );
  }
}

class _GroupErrorRow extends StatelessWidget {
  const _GroupErrorRow({
    required this.type,
    required this.message,
    required this.enabled,
    required this.onRetry,
  });

  final String type;
  final String message;
  final bool enabled;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.error_outline, size: 20, color: theme.colorScheme.error),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Load failed — $message',
            style: theme.textTheme.labelMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        TextButton(
          key: ValueKey('retry-$type'),
          onPressed: enabled ? onRetry : null,
          child: const Text('Retry'),
        ),
      ],
    );
  }
}
