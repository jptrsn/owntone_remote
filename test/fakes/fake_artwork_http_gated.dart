import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Server-side adversarial `dart:io` fake for the R-03 unit 010 artwork
/// probe hunt. Unlike `fake_artwork_http.dart` (the executable contract,
/// status encoded in the URL — a *client* stub), this fake models the
/// **server**: answers are configured per artwork id and can be flipped
/// after the fact (to test verdict staleness), requests to an id can be
/// hung behind a gate (to probe the probe's 3 s timeout and to interleave
/// a late verdict against a URL swap), and an id can be made unreachable
/// (probe failure must never cache a `true`).
///
/// Install once per test file (`installOnce` in `setUpAll`) — the
/// `network_image_io` loader caches one `HttpClient` per isolate, same
/// constraint as the contract fake. Ids must be unique per scenario
/// ([nextArtworkId]): `ArtworkProbe`'s verdict cache is static per isolate,
/// so a reused URL would silently inherit an earlier test's verdict.
class GatedArtworkHttp extends HttpOverrides {
  static GatedArtworkHttp installOnce() {
    final fake = GatedArtworkHttp();
    HttpOverrides.global = fake;
    return fake;
  }

  /// Every request line issued, in order (`GET /artwork/item/adv3` for the
  /// mirror's plain probe, `...?maxwidth=600` for the ArtworkBox sites).
  final List<String> requests = [];

  final Map<String, _Answer> _answers = {};
  final Map<String, Completer<void>> _gates = {};
  final Set<String> _unreachable = {};

  /// The server's answer for [id]. A 204 with a `png`/`garbage` body models
  /// the degenerate "204 that carries bytes" case. Flipping the answer
  /// mid-test models a server whose verdict for the same URL changes.
  void serve(String id, {required int status, String body = 'empty'}) {
    _answers[id] = _Answer(status, switch (body) {
      'png' => _pngBytes,
      'garbage' => utf8.encode('this is definitely not a PNG'),
      _ => const <int>[],
    });
  }

  /// Requests for [id] block until [release] — models a hung endpoint
  /// (probe timeout path) and lets a verdict land at a chosen moment.
  void hang(String id) => _gates.putIfAbsent(id, () => Completer<void>());

  /// Unblocks every currently-pending request for [id]; later requests
  /// answer immediately with the current [serve] answer.
  void release(String id) => _gates.remove(id)?.complete();

  /// Every request for [id] fails like a dead host (probe failure path).
  void unreachable(String id) => _unreachable.add(id);

  /// Requests targeting exactly this artwork id (boundary-checked, ids are
  /// prefixes of each other otherwise: `adv1` vs `adv12`).
  int requestCount(String id) {
    final needle = '/artwork/item/$id';
    return requests
        .where((r) => r.contains('$needle?') || r.endsWith(needle))
        .length;
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) => _GatedClient(this);
}

int _idCounter = 0;

/// A fresh artwork id — never reuse one across scenarios in a file
/// (static probe cache + global ImageCache are isolate-wide).
String nextArtworkId([String prefix = 'adv']) => '$prefix${_idCounter++}';

/// The server's artwork URL for [id] (no query — `ArtworkBox.withMaxWidth`
/// adds `maxwidth=600`; the mirror probes this raw form).
Uri artworkUri(String id) => Uri.parse('http://10.0.0.5:3689/artwork/item/$id');

class _Answer {
  const _Answer(this.status, this.body);
  final int status;
  final List<int> body;
}

/// 1×1 transparent PNG (decodable), same bytes as the contract fake.
final List<int> _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _GatedClient implements HttpClient {
  _GatedClient(this._fake);
  final GatedArtworkHttp _fake;

  @override
  bool autoUncompress = true;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = const Duration(seconds: 30);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final q = url.query;
    _fake.requests.add('$method ${url.path}${q.isEmpty ? '' : '?$q'}');
    if (!url.hasScheme || !url.hasAuthority) {
      // Mirrors the real HttpClient: relative URIs are rejected (and the
      // probe must treat that as a failed probe, not a verdict).
      throw ArgumentError('URI is not absolute: $url');
    }
    final id = url.pathSegments.isEmpty ? '' : url.pathSegments.last;
    if (_fake._unreachable.contains(id)) {
      throw const SocketException('artwork host unreachable (adversarial)');
    }
    final gate = _fake._gates[id];
    if (gate != null) await gate.future;
    final answer = _fake._answers[id] ?? const _Answer(404, <int>[]);
    return _GatedRequest(answer.status, answer.body);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'GatedArtworkHttp: unimplemented HttpClient member '
    '${invocation.memberName} — extend the fake, do not silence it',
  );
}

class _GatedHeaders implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  String? value(String name) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'GatedArtworkHttp: unimplemented HttpHeaders member '
    '${invocation.memberName}',
  );
}

class _GatedRequest implements HttpClientRequest {
  _GatedRequest(this.statusCode, this._body);

  final int statusCode;
  final List<int> _body;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  // Not an HttpClientRequest member (lives on HttpClient) — the image
  // loader assigns it on both.
  bool autoUncompress = true;

  final HttpHeaders _headers = _GatedHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async => _GatedResponse(statusCode, _body);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'GatedArtworkHttp: unimplemented HttpClientRequest member '
    '${invocation.memberName}',
  );
}

class _GatedResponse extends Stream<List<int>> implements HttpClientResponse {
  _GatedResponse(this.statusCode, List<int> body) : _body = body;

  @override
  final int statusCode;
  final List<int> _body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_body).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  int get contentLength => _body.length;

  final HttpHeaders _headers = _GatedHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'GatedArtworkHttp: unimplemented HttpClientResponse member '
    '${invocation.memberName}',
  );
}
