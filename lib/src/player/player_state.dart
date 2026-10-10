// Mirrors of `GET /api/player` and the now-playing queue item.
// Pure parsing — no I/O (testable, R-03).

enum Repeat {
  off,
  all,
  single;

  String get wire => name;

  static Repeat parse(String? wire) =>
      Repeat.values.firstWhere((m) => m.wire == wire, orElse: () => off);
}

class PlayerState {
  const PlayerState({
    required this.state,
    required this.repeat,
    required this.consume,
    required this.shuffle,
    required this.volume,
    this.itemId,
    this.itemLengthMs,
    this.itemProgressMs,
    this.artworkUrl,
  });

  /// `play`, `pause` or `stop` (OwnTone wire value).
  final String state;
  final Repeat repeat;
  final bool consume;
  final bool shuffle;

  /// Master volume, 0–100.
  final int volume;

  /// Current track id (null when stopped).
  final int? itemId;
  final int? itemLengthMs;
  final int? itemProgressMs;

  /// Raw (possibly relative) artwork URL from the server.
  final String? artworkUrl;

  bool get isPlaying => state == 'play';
  bool get isPaused => state == 'pause';
  bool get isStopped => state == 'stop';

  factory PlayerState.fromJson(Map<String, dynamic> json) => PlayerState(
    state: json['state'] as String? ?? 'stop',
    repeat: Repeat.parse(json['repeat'] as String?),
    consume: json['consume'] as bool? ?? false,
    shuffle: json['shuffle'] as bool? ?? false,
    volume: json['volume'] as int? ?? 0,
    itemId: json['item_id'] as int?,
    itemLengthMs: json['item_length_ms'] as int?,
    itemProgressMs: json['item_progress_ms'] as int?,
    artworkUrl: json['artwork_url'] as String?,
  );

  /// Resolves a possibly-relative artwork URL against the web root.
  /// Returns null for null/empty input.
  static Uri? resolveArtwork(Uri webRoot, String? url) {
    if (url == null || url.isEmpty) return null;
    return webRoot.resolve(url);
  }
}

/// The currently playing item, from `GET /api/queue?id=now_playing`.
class NowPlayingItem {
  const NowPlayingItem({
    this.id,
    this.trackId,
    required this.title,
    required this.artist,
    required this.album,
    this.lengthMs,
    this.artworkUrl,
    this.uri,
  });

  /// Queue-item id (string in the OwnTone API).
  final String? id;
  final int? trackId;
  final String? title;
  final String? artist;
  final String? album;
  final int? lengthMs;

  /// Absolute artwork URL (resolved), or null.
  final Uri? artworkUrl;
  final String? uri;

  factory NowPlayingItem.fromJson(Map<String, dynamic> json, Uri webRoot) =>
      NowPlayingItem(
        id: json['id']?.toString(),
        trackId: json['track_id'] as int?,
        title: json['title'] as String?,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        lengthMs: json['length_ms'] as int?,
        artworkUrl: PlayerState.resolveArtwork(
          webRoot,
          (json['artwork_url'] as String?) ??
              (json['album_id'] != null
                  ? './artwork/album/${json['album_id']}'
                  : null),
        ),
        uri: json['uri'] as String?,
      );
}
