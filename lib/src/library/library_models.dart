// Mirrors of the library objects from the OwnTone browse endpoints
// (docs/API.md § Library). Pure parsing — no I/O (testable, R-10).

/// A page of library objects from a `GET …?offset&limit` endpoint.
class Paging<T> {
  const Paging({
    required this.items,
    required this.total,
    required this.offset,
    required this.limit,
  });

  final List<T> items;
  final int total;
  final int offset;

  /// The limit as the server reports it (`-1` = unbounded request).
  final int limit;

  static Paging<T> fromJson<T>(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) itemFromJson,
  ) => Paging<T>(
    items: [
      for (final e in (json['items'] as List<dynamic>? ?? const []))
        itemFromJson(e as Map<String, dynamic>),
    ],
    total: (json['total'] as num?)?.toInt() ?? 0,
    offset: (json['offset'] as num?)?.toInt() ?? 0,
    limit: (json['limit'] as num?)?.toInt() ?? -1,
  );
}

/// A playlist from `GET /api/library/playlists`.
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.type,
    required this.smartPlaylist,
    required this.folder,
    this.itemCount,
    required this.uri,
  });

  /// Wire id is an int; normalized to a string (used as a path segment).
  final String id;
  final String name;

  /// `special`, `folder`, `smart`, `plain` — display-only string.
  final String type;
  final bool smartPlaylist;
  final bool folder;
  final int? itemCount;
  final String uri;

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: (json['id'] ?? '').toString(),
    name: json['name'] as String? ?? '',
    type: json['type'] as String? ?? 'plain',
    smartPlaylist: json['smart_playlist'] as bool? ?? false,
    folder: json['folder'] as bool? ?? false,
    itemCount: (json['item_count'] as num?)?.toInt(),
    uri: json['uri'] as String? ?? '',
  );
}

/// An artist from `GET /api/library/artists`.
class Artist {
  const Artist({
    required this.id,
    required this.name,
    required this.albumCount,
    required this.trackCount,
    required this.lengthMs,
  });

  final String id;
  final String name;
  final int albumCount;
  final int trackCount;
  final int lengthMs;

  factory Artist.fromJson(Map<String, dynamic> json) => Artist(
    id: (json['id'] ?? '').toString(),
    name: json['name'] as String? ?? '',
    albumCount: (json['album_count'] as num?)?.toInt() ?? 0,
    trackCount: (json['track_count'] as num?)?.toInt() ?? 0,
    lengthMs: (json['length_ms'] as num?)?.toInt() ?? 0,
  );
}

/// An album from `GET /api/library/albums` (and the artist/genre variants).
class Album {
  const Album({
    required this.id,
    required this.name,
    required this.artist,
    required this.artistId,
    required this.trackCount,
    required this.lengthMs,
    this.year,
  });

  final String id;
  final String name;
  final String artist;
  final String artistId;
  final int trackCount;
  final int lengthMs;
  final int? year;

  factory Album.fromJson(Map<String, dynamic> json) => Album(
    id: (json['id'] ?? '').toString(),
    name: json['name'] as String? ?? '',
    artist: json['artist'] as String? ?? '',
    artistId: (json['artist_id'] ?? '').toString(),
    trackCount: (json['track_count'] as num?)?.toInt() ?? 0,
    lengthMs: (json['length_ms'] as num?)?.toInt() ?? 0,
    year: (json['year'] as num?)?.toInt(),
  );
}

/// A track from the album / playlist track listings. [rating] (0–100) is
/// consumed from unit 006 onward; [uri] is the play target from 005b.
class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumId,
    required this.lengthMs,
    this.trackNumber,
    this.discNumber,
    this.rating,
    required this.uri,
  });

  /// Wire id is an int; the rating endpoint (R-12) takes it as-is.
  final int id;
  final String title;
  final String artist;
  final String album;
  final String albumId;
  final int lengthMs;
  final int? trackNumber;
  final int? discNumber;
  final int? rating;
  final String uri;

  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: (json['id'] as num?)?.toInt() ?? 0,
    title: json['title'] as String? ?? '',
    artist: json['artist'] as String? ?? '',
    album: json['album'] as String? ?? '',
    albumId: (json['album_id'] ?? '').toString(),
    lengthMs: (json['length_ms'] as num?)?.toInt() ?? 0,
    trackNumber: (json['track_number'] as num?)?.toInt(),
    discNumber: (json['disc_number'] as num?)?.toInt(),
    rating: (json['rating'] as num?)?.toInt(),
    uri: json['uri'] as String? ?? '',
  );
}

/// A genre from `GET /api/library/genres`. Browse-info objects have no id —
/// the name is the identity (and the search expression target).
class Genre {
  const Genre({
    required this.name,
    required this.trackCount,
    required this.albumCount,
    required this.artistCount,
  });

  final String name;
  final int trackCount;
  final int albumCount;
  final int artistCount;

  factory Genre.fromJson(Map<String, dynamic> json) => Genre(
    name: json['name'] as String? ?? '',
    trackCount: (json['track_count'] as num?)?.toInt() ?? 0,
    albumCount: (json['album_count'] as num?)?.toInt() ?? 0,
    artistCount: (json['artist_count'] as num?)?.toInt() ?? 0,
  );
}

/// The smart-playlist expression for a genre: genre→albums goes through
/// `GET /api/search?type=albums&expression=genre is "…"` (docs/API.md).
/// Embedded double quotes are backslash-escaped.
String genreExpression(String name) =>
    'genre is "${name.replaceAll('"', r'\"')}"';
