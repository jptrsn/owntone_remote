import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Fake `dart:io` HTTP layer for `Image.network` artwork loads
/// (R-03 unit 010). `Image.network` goes through `HttpClient`, which
/// `HttpOverrides.global` swaps — `ScriptedAdapter` in
/// `fake_owntone_server.dart` only fakes the dio path, not this one.
///
/// `network_image_io` creates its `HttpClient` once per isolate and reuses
/// it, so the stub must be **installed once for the whole test file**
/// (`installOnce`) and dispatch per-request on the URL's `status` query
/// parameter — per-test overrides would leave every test behind the
/// first-created client.
///
/// URL contract (encoded by [artworkUrl]):
/// - `?status=<int>` — the HTTP status the stub answers with (default 404,
///   so an unconfigured URL fails loudly rather than silently succeeding);
/// - `&body=png` — a valid 1×1 PNG body; `&body=garbage` — non-image bytes;
///   anything else — empty body.
class FakeArtworkHttp extends HttpOverrides {
  /// Install as `HttpOverrides.global` and restore on teardown. Call once
  /// from `setUpAll` (see the isolate-wide client-cache note above).
  static FakeArtworkHttp installOnce() {
    final fake = FakeArtworkHttp();
    HttpOverrides.global = fake;
    return fake;
  }

  /// Every request line the image loader issued, in order, e.g.
  /// `GET /artwork/item/c1a?maxwidth=600&status=204` (the fake sees the
  /// URL *after* `ArtworkBox.withMaxWidth` has appended `maxwidth=600`).
  final List<String> requests = [];

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _DispatchClient(this);
}

/// A URL for the stub: `http://10.0.0.5:3689/artwork/item/<id>?status=…`.
Uri artworkUrl(String id, {required int status, String? body}) => Uri.parse(
  'http://10.0.0.5:3689/artwork/item/$id'
  '?status=$status${body == null ? '' : '&body=$body'}',
);

/// 1×1 transparent PNG — decodable bytes for the 200-success case.
final List<int> _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _DispatchClient implements HttpClient {
  _DispatchClient(this._fake);
  final FakeArtworkHttp _fake;

  @override
  bool autoUncompress = true;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = const Duration(seconds: 30);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _request(method, url);

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _request('GET', url);

  Future<HttpClientRequest> _request(String method, Uri url) {
    final q = url.query;
    _fake.requests.add('$method ${url.path}${q.isEmpty ? '' : '?$q'}');
    final status = int.tryParse(url.queryParameters['status'] ?? '') ?? 404;
    final body = switch (url.queryParameters['body']) {
      'png' => _pngBytes,
      'garbage' => utf8.encode('this is definitely not a PNG'),
      _ => const <int>[],
    };
    return Future.value(_DispatchRequest(status, body));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'FakeArtworkHttp: unimplemented HttpClient member '
    '${invocation.memberName} — extend the fake, do not silence it',
  );
}

class _DispatchHeaders implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  String? value(String name) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'FakeArtworkHttp: unimplemented HttpHeaders member '
    '${invocation.memberName}',
  );
}

class _DispatchRequest implements HttpClientRequest {
  _DispatchRequest(this.statusCode, this._body);

  final int statusCode;
  final List<int> _body;

  @override
  bool followRedirects = true;

  @override
  int maxRedirects = 5;

  // Not an HttpClientRequest member (it lives on HttpClient) — carried
  // here because the image loader assigns it on both.
  bool autoUncompress = true;

  final HttpHeaders _headers = _DispatchHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async =>
      _DispatchResponse(statusCode, _body);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'FakeArtworkHttp: unimplemented HttpClientRequest member '
    '${invocation.memberName}',
  );
}

class _DispatchResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _DispatchResponse(this.statusCode, List<int> body) : _body = body;

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

  final HttpHeaders _headers = _DispatchHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'FakeArtworkHttp: unimplemented HttpClientResponse member '
    '${invocation.memberName}',
  );
}
