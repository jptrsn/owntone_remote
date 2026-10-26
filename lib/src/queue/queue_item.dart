import '../player/player_state.dart';

/// A queue-item object from `GET /api/queue` (docs/API.md § Queue).
class QueueItem {
  const QueueItem({
    required this.id,
    required this.position,
    required this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    required this.lengthMs,
    this.artworkUrl,
    required this.uri,
  });

  /// The per-queue-entry id (string in the OwnTone API, like
  /// [NowPlayingItem.id]). **This is what `PlayerState.itemId` points to**
  /// (verified live 2026-10-23: `item_id` 196174 matched the entry's `id`,
  /// not its `track_id` 1195) — the R-11 highlight compares against this.
  final String id;

  /// 0-based position in the server queue.
  final int position;

  /// The library track id (`uri` is `library:track:<trackId>`).
  final int trackId;
  final String title;
  final String artist;
  final String album;
  final int lengthMs;

  /// Absolute artwork URL (resolved), or null.
  final Uri? artworkUrl;

  /// The play target (e.g. `library:track:1195`).
  final String uri;

  factory QueueItem.fromJson(Map<String, dynamic> json, Uri webRoot) =>
      QueueItem(
        id: json['id']?.toString() ?? '',
        position: (json['position'] as num?)?.toInt() ?? 0,
        trackId: (json['track_id'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String? ?? '',
        lengthMs: (json['length_ms'] as num?)?.toInt() ?? 0,
        artworkUrl: PlayerState.resolveArtwork(
          webRoot,
          (json['artwork_url'] as String?) ??
              (json['album_id'] != null
                  ? './artwork/album/${json['album_id']}'
                  : null),
        ),
        uri: json['uri'] as String? ?? '',
      );
}
