import 'package:flutter/material.dart';
import 'dart:async';

import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../queue/queue_controller.dart';
import '../rating/rating_controller.dart';
import '../library/library_models.dart';
import '../library/paged_list.dart';
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
    (Icons.label_outline, 'Genres'),
  ];

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final enabled = conn.phase == ConnectionPhase.connected;
    return BrowseScreenScaffold(
      title: 'Library',
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
