import 'dart:io';

import 'package:dio/dio.dart';

import 'server_config.dart';

/// Why a connection attempt failed (R-01: the user must see a *specific*
/// error — DNS vs refused vs 401 — not a generic "it broke").
enum ConnectionErrorReason {
  /// The host name does not resolve.
  dns,

  /// Nothing is listening (refused) or the host is unreachable.
  refused,

  /// The connection or a response timed out.
  timeout,

  /// The server demands credentials (HTTP 401).
  unauthorized,

  /// The server answered, but with an unexpected HTTP status.
  http,

  /// Anything else.
  other,
}

/// A typed, human-readable connection failure (R-01).
class ConnectionError implements Exception {
  const ConnectionError(this.reason, this.message, {this.httpStatus});

  final ConnectionErrorReason reason;
  final String message;
  final int? httpStatus;

  @override
  String toString() => message;
}

/// Maps a dio failure against the attempted [cfg] to a typed
/// [ConnectionError].
///
/// On this SDK a DNS failure and a refused/unreachable connection both
/// surface as [SocketException] (DNS: "Failed host lookup: …", errno 8;
/// refused: errno 61; unreachable: errno 101), so the *wording* decides
/// (test: `connection_error_test.dart`).
ConnectionError connectionErrorFromDio(DioException e, ServerConfig cfg) {
  final target = cfg.toString();
  switch (e.type) {
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
      return ConnectionError(
        ConnectionErrorReason.timeout,
        'Could not reach $target — the connection timed out.',
      );
    case DioExceptionType.badCertificate:
      return ConnectionError(
        ConnectionErrorReason.other,
        'TLS error reaching $target.',
      );
    case DioExceptionType.connectionError:
      return _networkError(e, target, cfg);
    case DioExceptionType.badResponse:
      final status = e.response?.statusCode;
      if (status == 401) {
        return ConnectionError(
          ConnectionErrorReason.unauthorized,
          '$target requires authentication (HTTP 401).',
          httpStatus: 401,
        );
      }
      return ConnectionError(
        ConnectionErrorReason.http,
        '$target answered with HTTP ${status ?? 'an error status'}.',
        httpStatus: status,
      );
    default:
      return ConnectionError(
        ConnectionErrorReason.other,
        'Could not reach $target${e.message == null || e.message!.isEmpty ? '' : ' — ${e.message}'}.',
      );
  }
}

ConnectionError _networkError(DioException e, String target, ServerConfig cfg) {
  // Combine the inner error's wording with dio's own message: the type of
  // failure is only visible in the text on this platform.
  String detail;
  final err = e.error;
  if (err is SocketException) {
    detail = '${err.message} ${err.osError?.message ?? ''} ${e.message ?? ''}';
  } else {
    detail = '${err ?? ''} ${e.message ?? ''}';
  }
  detail = detail.toLowerCase();

  if (detail.contains('host lookup') ||
      detail.contains('nodename') ||
      detail.contains('resolve') ||
      detail.contains('dns')) {
    return ConnectionError(
      ConnectionErrorReason.dns,
      'Host "${cfg.host}" could not be resolved (DNS).',
    );
  }
  if (detail.contains('refused')) {
    return ConnectionError(
      ConnectionErrorReason.refused,
      'Connection to $target was refused — is the server running there?',
    );
  }
  if (detail.contains('unreachable') || detail.contains('no route')) {
    return ConnectionError(
      ConnectionErrorReason.refused,
      '$target is unreachable from this network.',
    );
  }
  return ConnectionError(
    ConnectionErrorReason.refused,
    'Could not reach $target (connection failed).',
  );
}
