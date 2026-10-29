import 'dart:async';
import 'dart:io';

/// Classifies an artwork URL's HTTP status *before* anything renders or
/// publishes it (R-03, unit 010).
///
/// OwnTone answers `204 No Content` for "this item has no artwork" — a
/// normal answer, not an error. Left unhandled it becomes an exception on
/// the happy path twice over: `Image.network` turns it into a
/// `NetworkImageLoadException` (placeholder still shows, but the load took
/// the failure branch), and audio_service's `flutter_cache_manager` fetch
/// of `MediaItem.artUri` logs `Invalid statusCode: 204` for every
/// artwork-less item (SESSION-LOG 2026-10-26 item 4). Both fetch sites ask
/// this probe first and only `true` (a probed 204) demotes the artwork to
/// the normal no-image branch. Every other outcome — 200, 404, 500, probe
/// failure, timeout — answers `false`, so today's `errorBuilder` path
/// stays the one that decides genuine failures, which is exactly what the
/// unit pins for non-204 statuses.
///
/// The probe is a plain GET (HEAD is deliberately unused: the endpoint's
/// HEAD behaviour is unverified, and the dart:io fake in
/// `test/fakes/fake_artwork_http.dart` — the executable contract — only
/// speaks GET). One probe per URL for the process lifetime: concurrent
/// callers share the same Future, so a screen rebuild or racing syncs never
/// cause a retry storm; a probe that *throws* (server down) is evicted so
/// the next screen entry re-checks — a probed verdict, right or wrong,
/// sticks for the session (server artwork is static per library entry).
///
/// The body is drained (not discarded mid-stream) so the keep-alive socket
/// survives for the real image fetch that follows a `false` verdict.
class ArtworkProbe {
  ArtworkProbe._();

  static const Duration _timeout = Duration(seconds: 3);

  static final Map<Uri, Future<bool>> _results = {};
  static HttpClient? _client;

  /// True when [url] answered HTTP 204 (the server says: no artwork).
  /// `false` means "not a 204" — including unknown/failed probes — so
  /// callers only ever take the no-image branch on positive evidence.
  static Future<bool> isNoArtwork(Uri url) {
    final cached = _results[url];
    if (cached != null) return cached;
    final future = _check(url).catchError((Object _) {
      _results.remove(url);
      return false;
    });
    _results[url] = future;
    return future;
  }

  static Future<bool> _check(Uri url) async {
    // Lazily created (never at library-load time): HttpOverrides must be in
    // place first, and the test fakes install theirs in setUpAll.
    final client = _client ??= HttpClient();
    final request = await client.openUrl('GET', url).timeout(_timeout);
    final response = await request.close().timeout(_timeout);
    final status = response.statusCode;
    try {
      await response.drain<void>().timeout(_timeout);
    } catch (_) {
      // The verdict is already read; failing to consume the body (test
      // doubles implement only the members the load path touches) must not
      // change it.
    }
    return status == 204;
  }
}
