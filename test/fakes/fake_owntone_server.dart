import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A dio [HttpClientAdapter] that answers from a scriptable [responder].
/// Lets the real [OwntoneApi] run in unit tests without a network — the
/// JSON parsing path is exercised for real.
///
/// To simulate a network failure, the responder *throws* a
/// [DioException] (see [networkError]); [fetch] lets it propagate so dio
/// treats it exactly like a real adapter failure.
class ScriptedAdapter implements HttpClientAdapter {
  ScriptedAdapter({
    Response<dynamic> Function(RequestOptions options)? responder,
  }) : responder = responder ?? _defaultNotFound;

  /// Swap this to change the server's behaviour mid-test.
  Response<dynamic> Function(RequestOptions options) responder;

  /// Every request line seen, in order (e.g. `GET /api/player`).
  final List<String> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add('${options.method} ${options.path}');
    final res = responder(options); // may throw a DioException
    final data = res.data;
    final bytes = data is String
        ? utf8.encode(data)
        : (data is Map || data is List)
        ? utf8.encode(jsonEncode(data))
        : <int>[];
    return ResponseBody.fromBytes(
      bytes,
      res.statusCode ?? 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Response<dynamic> _defaultNotFound(RequestOptions options) => Response(
  requestOptions: options,
  statusCode: 404,
  data: '<html>not found</html>',
);

/// A 200 JSON response for the given request.
Response<dynamic> jsonResponse(RequestOptions options, Object? data) =>
    Response(requestOptions: options, statusCode: 200, data: data);

/// A [DioException] shaped like a real network-layer failure.
DioException networkError(
  RequestOptions options,
  Object? error, {
  DioExceptionType type = DioExceptionType.connectionError,
  String? message,
}) => DioException(
  requestOptions: options,
  type: type,
  error: error,
  message: message,
);

/// A [SocketException] with a real [OSError] (the shape the VM produces for
/// refused / unreachable connections).
SocketException socketFailure(String osMessage, int errno) =>
    SocketException('Connection failed', osError: OSError(osMessage, errno));
