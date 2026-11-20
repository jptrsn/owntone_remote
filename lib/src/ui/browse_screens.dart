import 'package:flutter/material.dart';
import 'dart:async';

import 'package:provider/provider.dart';

import '../api/owntone_api.dart';
import '../connection/connection_controller.dart';
import '../queue/queue_controller.dart';
import '../rating/rating_controller.dart';
import '../library/library_models.dart';
import '../library/paged_list.dart';
import 'app_drawer.dart';
import 'browse_rows.dart';
import 'browse_screen_scaffold.dart';
import 'paged_browse_screen.dart';
import 'search_screen.dart';

/// The row-tap rating commit (R-12, unit 006): `RatingStars` contract —
/// null on success, the typed error text for the snackbar on failure. The
/// [RatingController] read is deferred to tap time so screens without the
/// provider (or rows never tapped) never touch it.
Future<String?> Function(int newRating) rateTrack(
  BuildContext context,
  int trackId,
) => (newRating) async {
  final rating = context.read<RatingController>();
  final ok = await rating.setRating(trackId, newRating);
  return ok ? null : (rating.actionError ?? 'Rating failed.');
};

/// R-19 (issue #41) — the app-bar overflow ReTune's detail screens carry
/// (`09-album-detail`, `18b-overflow-playlist`): **Play All · Shuffle ·
/// Play Next · Add to Up Next** for the whole set the screen shows.
///
/// The two playback-starting entries (Play All, Shuffle) keep [QueueController]'s
/// replace-and-start contract — **supervised** actions, never triggered in
/// tests against the real server or on device unattended. Play Next / Add
/// to Up Next are the no-clear `playback=add` path.
///
/// Empty-set rule (minimal, chosen for the issue): while the list has not
/// loaded or is empty the WHOLE button is disabled — every entry would be
/// a no-op, and a stable (disabled) app bar beats a menu of dead entries.
class SetPlaybackOverflow extends StatelessWidget {
  const SetPlaybackOverflow({
    super.key,
    required this.empty,
    required this.onPlayAll,
    required this.onShuffle,
    required this.onPlayNext,
    required this.onAddToUpNext,
  });

  final bool empty;
  final VoidCallback onPlayAll;
  final VoidCallback onShuffle;
  final VoidCallback onPlayNext;
  final VoidCallback onAddToUpNext;

  static const _entries = [
    ('play-all', 'Play All'),
    ('shuffle', 'Shuffle'),
    ('play-next', 'Play Next'),
    ('add', 'Add to Up Next'),
  ];

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      key: const ValueKey('detail-overflow'),
      tooltip: 'Playback options',
      enabled: !empty,
      onSelected: (value) {
        switch (value) {
          case 'play-all':
            onPlayAll();
          case 'shuffle':
            onShuffle();
          case 'play-next':
            onPlayNext();
          case 'add':
            onAddToUpNext();
        }
      },
      itemBuilder: (context) => [
        for (final (value, label) in _entries)
          PopupMenuItem<String>(value: value, child: Text(label)),
      ],
    );
  }
}

/// R-19: the Shuffle entry's client-side pre-shuffle path. The full set is
/// materialized as item URIs first (one unbounded `limit=-1` page —
/// verified live against this server 2026-11-20), shuffled by
/// [QueueController.playUrisShuffled], then replace-and-started. The
/// add-time `?shuffle` param is NOT used: it is the server's GLOBAL
/// shuffle-mode setter (live-verified 2026-11-20), and R-19 requires
/// leaving that flag untouched. A load failure gets a snackbar — no
/// silent no-op.
Future<void> _shufflePlaySet(
  BuildContext context,
  Future<List<String>> Function(OwntoneApi api) loadUris,
) async {
  final api = context.read<ConnectionController>().api;
  if (api == null) return;
  final uris = await loadUris(api).catchError((e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load the tracks to shuffle.')),
      );
    }
    return <String>[];
  });
  if (uris.isEmpty) return;
  await context.read<QueueController>().playUrisShuffled(uris);
}

/// R-10 (unit 005a): the library home — the browse menu (Search, Playlists,
/// Artists, Albums, Genres), reached from the now-playing app bar. Search
/// lives here (R-13, unit 007), not in the now-playing app bar: a second
/// app-bar action overflows the 360-logical-px viewport (unit 004 finding).
class LibraryHomeScreen extends StatelessWidget {
  const LibraryHomeScreen({super.key});

  static const _sections = [
    (Icons.search, 'Search'),
    (Icons.queue_music, 'Playlists'),
    (Icons.person, 'Artists'),
    (Icons.album, 'Albums'),
    (Icons.music_note, 'Songs'),
    (Icons.label_outline, 'Genres'),
  ];

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final enabled = conn.phase == ConnectionPhase.connected;
    return BrowseScreenScaffold(
      title: 'Library',
      // R-18: outputs one tap away from every browse screen (D-09).
      actions: const [OutputsAppBarAction()],
      drawer: const AppDrawer(selected: DrawerDestination.library),
      body: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: _sections.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final (icon, label) = _sections[i];
          return BrowseRow(
            primary: label,
            semanticsLabel: label,
            leading: Icon(icon, size: 24),
            trailing: const Icon(Icons.chevron_right),
            enabled: enabled,
            onTap: enabled
                ? () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => switch (label) {
                        'Search' => const SearchScreen(),
                        'Playlists' => const PlaylistsScreen(),
                        'Artists' => const ArtistsScreen(),
                        'Albums' => const AlbumsScreen(),
                        'Songs' => const TracksScreen(),
                        _ => const GenresScreen(),
                      },
                    ),
                  )
                : null,
          );
        },
      ),
    );
  }
}

class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PagedBrowseScreen<Playlist>(
      title: 'Playlists',
      drawer: const AppDrawer(selected: DrawerDestination.playlists),
      what: 'playlists',
      emptyMessage: 'No playlists in the library.',
      emptyIcon: Icons.queue_music,
      buildList: (conn) => PagedList(
        fetch: (offset, limit) async {
          final api = conn.api;
          if (api == null) throw StateError('no api');
          return api.playlists(offset: offset, limit: limit);
        },
        keyOf: (playlist) => playlist.id,
      ),
      itemBuilder: (context, i, playlist, enabled) => PlaylistRow(
        playlist: playlist,
        enabled: enabled,
        onOpen: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => PlaylistTracksScreen(playlist: playlist),
          ),
        ),
        onPlay: () =>
            unawaited(context.read<QueueController>().playUris([playlist.uri])),
      ),
    );
  }
}

class PlaylistTracksScreen extends StatelessWidget {
  const PlaylistTracksScreen({super.key, required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    return PagedBrowseScreen<Track>(
      title: playlist.name,
      what: 'tracks',
      emptyMessage: 'This playlist is empty.',
      emptyIcon: Icons.queue_music,
      buildList: (conn) => PagedList(
        fetch: (offset, limit) async {
          final api = conn.api;
          if (api == null) throw StateError('no api');
          return api.playlistTracks(playlist.id, offset: offset, limit: limit);
        },
        keyOf: (track) => track.id.toString(),
      ),
      // R-19 (issue #41): whole-set actions. Play All / Play Next / Add
      // ride the CONTAINER uri (server expands it, order preserved);
      // Shuffle expands to track URIs client-side (see _shufflePlaySet).
      appActions: (context, list) => [
        SetPlaybackOverflow(
          empty: !list.hasLoaded || list.total == 0,
          onPlayAll: () => unawaited(
            context.read<QueueController>().playUris([playlist.uri]),
          ),
          onShuffle: () => unawaited(
            _shufflePlaySet(context, (api) async {
              final all = await api.playlistTracks(
                playlist.id,
                offset: 0,
                limit: -1,
              );
              return [for (final t in all.items) t.uri];
            }),
          ),
          onPlayNext: () => unawaited(
            context.read<QueueController>().addUris(
              [playlist.uri],
              ahead: true,
            ),
          ),
          onAddToUpNext: () => unawaited(
            context.read<QueueController>().addUris([playlist.uri]),
          ),
        ),
      ],
      itemBuilder: (context, i, track, enabled) => TrackRow(
        track: track,
        enabled: enabled,
        showArtist: true,
        onRate: rateTrack(context, track.id),
        onPlay: () =>
            unawaited(context.read<QueueController>().playUris([track.uri])),
      ),
    );
  }
}

class ArtistsScreen extends StatelessWidget {
  const ArtistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PagedBrowseScreen<Artist>(
      title: 'Artists',
      drawer: const AppDrawer(selected: DrawerDestination.artists),
      what: 'artists',
      emptyMessage: 'No artists in the library.',
      emptyIcon: Icons.person,
      buildList: (conn) => PagedList(
        fetch: (offset, limit) async {
          final api = conn.api;
          if (api == null) throw StateError('no api');
          return api.artists(offset: offset, limit: limit);
        },
        keyOf: (artist) => artist.id,
      ),
      // R-25: group by the server's sort key (name_sort), not the display
      // name — the server orders by name_sort ("Daniela Andrade" lands
      // under Andrade; verified live 2026-11-20), so only it yields
      // contiguous letter groups.
      groupKeyOf: (artist) => artist.sortName,
      itemBuilder: (context, i, artist, enabled) => ArtistRow(
        artist: artist,
        enabled: enabled,
        onOpen: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ArtistAlbumsScreen(artist: artist),
          ),
        ),
        onPlay: () => unawaited(
          context.read<QueueController>().playUris([
            'library:artist:${artist.id}',
          ]),
        ),
      ),
    );
  }
}

class ArtistAlbumsScreen extends StatelessWidget {
  const ArtistAlbumsScreen({super.key, required this.artist});

  final Artist artist;

  @override
  Widget build(BuildContext context) {
    return PagedBrowseScreen<Album>(
      title: artist.name,
      what: 'albums',
      emptyMessage: 'No albums for ${artist.name}.',
      emptyIcon: Icons.album,
      buildList: (conn) => PagedList(
        fetch: (offset, limit) async {
          final api = conn.api;
          if (api == null) throw StateError('no api');
          return api.artistAlbums(artist.id, offset: offset, limit: limit);
        },
        keyOf: (album) => album.id,
      ),
      // R-19 (issue #41): the whole-set uri is the artist container
      // (`library:artist:…`, same as ArtistsScreen's row play). Shuffle
      // here shuffles the ALBUM URIs — a block shuffle (album order),
      // not a per-track shuffle across the discography: expanding every
      // album's tracks would be an N+1 fetch for a judgement call the
      // issue does not ask for (recorded as an assumption).
      appActions: (context, list) => [
        SetPlaybackOverflow(
          empty: !list.hasLoaded || list.total == 0,
          onPlayAll: () => unawaited(
            context.read<QueueController>().playUris([
              'library:artist:${artist.id}',
            ]),
          ),
          onShuffle: () => unawaited(
            _shufflePlaySet(context, (api) async {
              final all = await api.artistAlbums(
                artist.id,
                offset: 0,
                limit: -1,
              );
              return [for (final a in all.items) a.uri];
            }),
          ),
          onPlayNext: () => unawaited(
            context.read<QueueController>().addUris(
              ['library:artist:${artist.id}'],
              ahead: true,
            ),
          ),
          onAddToUpNext: () => unawaited(
            context.read<QueueController>().addUris([
              'library:artist:${artist.id}',
            ]),
          ),
        ),
      ],
      itemBuilder: (context, i, album, enabled) => AlbumRow(
        album: album,
        enabled: enabled,
        onOpen: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AlbumTracksScreen(album: album),
          ),
        ),
        onPlay: () =>
            unawaited(context.read<QueueController>().playUris([album.uri])),
      ),
    );
  }
}

class AlbumsScreen extends StatelessWidget {
  const AlbumsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PagedBrowseScreen<Album>(
      title: 'Albums',
      drawer: const AppDrawer(selected: DrawerDestination.albums),
      what: 'albums',
      emptyMessage: 'No albums in the library.',
      emptyIcon: Icons.album,
      buildList: (conn) => PagedList(
        fetch: (offset, limit) async {
          final api = conn.api;
          if (api == null) throw StateError('no api');
          return api.albums(offset: offset, limit: limit);
        },
        keyOf: (album) => album.id,
      ),
      itemBuilder: (context, i, album, enabled) => AlbumRow(
        album: album,
        enabled: enabled,
        onOpen: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AlbumTracksScreen(album: album),
          ),
        ),
        onPlay: () =>
            unawaited(context.read<QueueController>().playUris([album.uri])),
      ),
    );
  }
}

/// The Songs view (R-15, issue #38 / diff-list D-02): every library track
/// as one paged two-line list (`title` / `artist - album`, ReTune's Songs
/// tab, `docs/retune-capture/12-songs/`). Rows are the existing
/// [TrackRow]s — row tap plays (R-10), stars rate (R-12) — with the #48
/// alphabetical section headers enabled (the deferred "Songs when #38
/// lands" clause): grouped by the server's `title_sort`, the order the
/// endpoint serves in (see `OwntoneApi.tracks`).
class TracksScreen extends StatelessWidget {
  const TracksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PagedBrowseScreen<Track>(
      title: 'Songs',
      drawer: const AppDrawer(selected: DrawerDestination.songs),
      what: 'tracks',
      emptyMessage: 'No tracks in the library.',
      emptyIcon: Icons.music_note,
      buildList: (conn) => PagedList(
        fetch: (offset, limit) async {
          final api = conn.api;
          if (api == null) throw StateError('no api');
          return api.tracks(offset: offset, limit: limit);
        },
        keyOf: (track) => track.id.toString(),
      ),
      // R-25 (via #48's deferral): group by the server's sort key
      // (title_sort), not the display title — the endpoint orders by it
      // ("The A Team" with title_sort "A Team" opens the list, verified
      // live 2026-11-20), so only it yields contiguous letter groups.
      groupKeyOf: (track) => track.sortTitle,
      itemBuilder: (context, i, track, enabled) => TrackRow(
        track: track,
        enabled: enabled,
        showArtist: true,
        showAlbum: true,
        onRate: rateTrack(context, track.id),
        onPlay: () =>
            unawaited(context.read<QueueController>().playUris([track.uri])),
      ),
    );
  }
}

class AlbumTracksScreen extends StatelessWidget {
  const AlbumTracksScreen({super.key, required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    return PagedBrowseScreen<Track>(
      title: album.name,
      what: 'tracks',
      emptyMessage: 'This album is empty.',
      emptyIcon: Icons.album,
      buildList: (conn) => PagedList(
        fetch: (offset, limit) async {
          final api = conn.api;
          if (api == null) throw StateError('no api');
          return api.albumTracks(album.id, offset: offset, limit: limit);
        },
        keyOf: (track) => track.id.toString(),
      ),
      // R-19 (issue #41): see PlaylistTracksScreen — same contract,
      // container uri for the ordered actions, track uri expansion for
      // the client-side shuffle.
      appActions: (context, list) => [
        SetPlaybackOverflow(
          empty: !list.hasLoaded || list.total == 0,
          onPlayAll: () =>
              unawaited(context.read<QueueController>().playUris([album.uri])),
          onShuffle: () => unawaited(
            _shufflePlaySet(context, (api) async {
              final all = await api.albumTracks(
                album.id,
                offset: 0,
                limit: -1,
              );
              return [for (final t in all.items) t.uri];
            }),
          ),
          onPlayNext: () => unawaited(
            context.read<QueueController>().addUris([album.uri], ahead: true),
          ),
          onAddToUpNext: () =>
              unawaited(context.read<QueueController>().addUris([album.uri])),
        ),
      ],
      itemBuilder: (context, i, track, enabled) => TrackRow(
        track: track,
        enabled: enabled,
        onRate: rateTrack(context, track.id),
        onPlay: () =>
            unawaited(context.read<QueueController>().playUris([track.uri])),
      ),
    );
  }
}

class GenresScreen extends StatelessWidget {
  const GenresScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return PagedBrowseScreen<Genre>(
      title: 'Genres',
      drawer: const AppDrawer(selected: DrawerDestination.genres),
      what: 'genres',
      emptyMessage: 'No genres in the library.',
      emptyIcon: Icons.label_outline,
      buildList: (conn) => PagedList(
        fetch: (offset, limit) async {
          final api = conn.api;
          if (api == null) throw StateError('no api');
          return api.genres();
        },
        keyOf: (genre) => genre.name,
      ),
      // R-25: same sort-key grouping as ArtistsScreen (name_sort verified
      // contiguous live 2026-11-20).
      groupKeyOf: (genre) => genre.sortName,
      itemBuilder: (context, i, genre, enabled) => GenreRow(
        genre: genre,
        enabled: enabled,
        onOpen: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => GenreAlbumsScreen(genre: genre),
          ),
        ),
      ),
    );
  }
}

class GenreAlbumsScreen extends StatelessWidget {
  const GenreAlbumsScreen({super.key, required this.genre});

  final Genre genre;

  @override
  Widget build(BuildContext context) {
    return PagedBrowseScreen<Album>(
      title: genre.name,
      what: 'albums',
      emptyMessage: 'No albums in ${genre.name}.',
      emptyIcon: Icons.album,
      buildList: (conn) => PagedList(
        fetch: (offset, limit) async {
          final api = conn.api;
          if (api == null) throw StateError('no api');
          return api.genreAlbums(genre.name, offset: offset, limit: limit);
        },
        keyOf: (album) => album.id,
      ),
      itemBuilder: (context, i, album, enabled) => AlbumRow(
        album: album,
        enabled: enabled,
        onOpen: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AlbumTracksScreen(album: album),
          ),
        ),
        onPlay: () =>
            unawaited(context.read<QueueController>().playUris([album.uri])),
      ),
    );
  }
}
