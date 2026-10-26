import 'package:flutter/material.dart';

import '../library/library_models.dart';
import '../library/rating.dart';
import 'rating_stars.dart';

/// The shared browse row (R-10, unit 005a): a rounded card with an
/// optional leading icon / numeric text, a primary line, a secondary line,
/// a trailing widget, and a compound semantics label so UI checks can read
/// it deterministically (the unit 004 convention).
class BrowseRow extends StatelessWidget {
  const BrowseRow({
    super.key,
    required this.primary,
    required this.semanticsLabel,
    this.leading,
    this.leadingText,
    this.secondary,
    this.trailing,
    this.enabled = true,
    this.onTap,
  });

  final String primary;
  final String semanticsLabel;
  final Widget? leading;

  /// Numeric text instead of [leading] (track numbers).
  final String? leadingText;
  final String? secondary;
  final Widget? trailing;
  final bool enabled;

  /// Null while the connection is down — the row renders but is inert
  /// (SCREENS.md: controls disabled while the offline banner is up).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = Semantics(
      container: true,
      label: semanticsLabel,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            if (leadingText != null)
              SizedBox(
                width: 28,
                child: Text(
                  leadingText!,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.labelMedium,
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    primary,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (secondary != null)
                    Text(
                      secondary!,
                      style: theme.textTheme.labelSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
      ),
    );
    if (!enabled || onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: content,
    );
  }
}

/// `mm:ss` for a track length (same shape as the now-playing screen).
String formatTrackLength(int ms) {
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The small play affordance on collection rows (unit 005b): row tap
/// navigates in, the button plays (`clear=true&playback=start`).
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.enabled, required this.onPlay});

  final bool enabled;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Play',
      icon: const Icon(Icons.play_arrow, size: 22),
      visualDensity: VisualDensity.compact,
      onPressed: enabled ? onPlay : null,
    );
  }
}

class PlaylistRow extends StatelessWidget {
  const PlaylistRow({
    super.key,
    required this.playlist,
    required this.enabled,
    required this.onOpen,
    this.onPlay,
  });

  final Playlist playlist;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;

  static String _kind(Playlist p) =>
      p.folder ? 'folder' : (p.smartPlaylist ? 'smart playlist' : 'playlist');

  @override
  Widget build(BuildContext context) {
    final kind = _kind(playlist);
    final count = playlist.itemCount;
    final secondary = [kind, if (count != null) '$count items'].join(' · ');
    return BrowseRow(
      primary: playlist.name,
      secondary: secondary,
      semanticsLabel:
          '${playlist.name}, $kind${count != null ? ', $count items' : ''}',
      leading: Icon(Icons.queue_music, size: 24),
      trailing: onPlay == null
          ? null
          : _PlayButton(enabled: enabled, onPlay: onPlay!),
      enabled: enabled,
      onTap: onOpen,
    );
  }
}

class ArtistRow extends StatelessWidget {
  const ArtistRow({
    super.key,
    required this.artist,
    required this.enabled,
    required this.onOpen,
    this.onPlay,
  });

  final Artist artist;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    return BrowseRow(
      primary: artist.name,
      secondary: '${artist.albumCount} albums · ${artist.trackCount} tracks',
      semanticsLabel:
          '${artist.name}, artist, ${artist.albumCount} albums, '
          '${artist.trackCount} tracks',
      leading: Icon(Icons.person, size: 24),
      trailing: onPlay == null
          ? null
          : _PlayButton(enabled: enabled, onPlay: onPlay!),
      enabled: enabled,
      onTap: onOpen,
    );
  }
}

class AlbumRow extends StatelessWidget {
  const AlbumRow({
    super.key,
    required this.album,
    required this.enabled,
    required this.onOpen,
    this.onPlay,
  });

  final Album album;
  final bool enabled;
  final VoidCallback onOpen;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final secondary = [
      if (album.artist.isNotEmpty) album.artist,
      if (album.year != null) '${album.year}',
    ].join(' · ');
    return BrowseRow(
      primary: album.name,
      secondary: secondary.isEmpty ? null : secondary,
      semanticsLabel:
          '${album.name}, album, ${album.artist}, ${album.trackCount} tracks',
      leading: Icon(Icons.album, size: 24),
      trailing: onPlay == null
          ? null
          : _PlayButton(enabled: enabled, onPlay: onPlay!),
      enabled: enabled,
      onTap: onOpen,
    );
  }
}

class GenreRow extends StatelessWidget {
  const GenreRow({
    super.key,
    required this.genre,
    required this.enabled,
    required this.onOpen,
  });

  final Genre genre;
  final bool enabled;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return BrowseRow(
      primary: genre.name,
      secondary: '${genre.trackCount} tracks · ${genre.albumCount} albums',
      semanticsLabel: '${genre.name}, genre, ${genre.trackCount} tracks',
      leading: Icon(Icons.label_outline, size: 24),
      enabled: enabled,
      onTap: onOpen,
    );
  }
}

/// A track row (R-10). Unit 005b: the row's tap is the play action
/// (`QueueController.playUris([track.uri])` — one add call,
/// `clear=true&playback=start`). [showArtist] is the playlist context;
/// [trackNumber] is the album context (leading number).
///
/// Unit 006 (R-12): with [onRate] the row also carries the tappable star
/// control (trailing, before the length). The stars own their taps — the
/// row tap stays play. Null [onRate] (a context without rating support)
/// shows no stars at all.
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    required this.track,
    required this.enabled,
    this.onPlay,
    this.onRate,
    this.showArtist = false,
    this.trackNumber,
  });

  final Track track;
  final bool enabled;

  /// The row-tap action: play this track. Null while the connection is down.
  final VoidCallback? onPlay;

  /// Commits a rating (0–100); null on success, the snackbar text on
  /// failure (`RatingStars` contract).
  final Future<String?> Function(int newRating)? onRate;
  final bool showArtist;
  final int? trackNumber;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final len = formatTrackLength(track.lengthMs);
    final stars = starsForRating(track.rating);
    final base = showArtist
        ? '${track.title}, track, ${track.artist}, $len'
        : '${track.title}, track ${trackNumber ?? ''}, $len';
    return BrowseRow(
      primary: track.title,
      secondary: showArtist ? track.artist : null,
      leadingText: trackNumber?.toString(),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onRate != null) ...[
            RatingStars(
              rating: track.rating,
              enabled: enabled,
              onRate: onRate!,
            ),
            const SizedBox(width: 4),
          ],
          Text(len, style: theme.textTheme.labelMedium),
        ],
      ),
      semanticsLabel: '$base, $stars stars',
      enabled: enabled,
      onTap: enabled ? onPlay : null,
    );
  }
}
