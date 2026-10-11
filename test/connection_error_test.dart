import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/core/connection_error.dart';
import 'package:owntone_remote/src/core/server_config.dart';

void main() {
  group('connectionErrorFromDio (R-01: specific, readable errors)', () {
    const cfg = ServerConfig(host: '192.168.1.13', port: 3689);
    final options = RequestOptions(path: '/api/config');

    DioException ex(
      Object? error,
      DioExceptionType type, {
      int? status,
      String? message,
    }) {
      return DioException(
        requestOptions: options,
        type: type,
        error: error,
        message: message,
        response: status == null
            ? null
            : Response(requestOptions: options, statusCode: status),
      );
    }

    // On this SDK a DNS failure is a SocketException("Failed host lookup:
    // …", errno 8) — verified against the VM (no AddressException export).
    test('DNS failure (Failed host lookup) → dns, names the host', () {
      final e = connectionErrorFromDio(
        ex(
          SocketException(
            "Failed host lookup: 'nope.invalid'",
            osError: const OSError('nodename nor servname provided', 8),
          ),
          DioExceptionType.connectionError,
        ),
        cfg,
      );
      expect(e.reason, ConnectionErrorReason.dns);
      expect(e.message, contains('192.168.1.13'));
      expect(e.message.toLowerCase(), contains('resolve'));
    });

    test('refused connection (SocketException ECONNREFUSED) → refused', () {
      final e = connectionErrorFromDio(
        ex(
          SocketException(
            'Connection failed',
            osError: const OSError('Connection refused (ECONNREFUSED)', 111),
          ),
          DioExceptionType.connectionError,
        ),
        cfg,
      );
      expect(e.reason, ConnectionErrorReason.refused);
      expect(e.message, contains('refused'));
    });

    test('unreachable host (SocketException ENETUNREACH) → refused class', () {
      final e = connectionErrorFromDio(
        ex(
          SocketException(
            'Connection failed',
            osError: const OSError('Network is unreachable (ENETUNREACH)', 101),
          ),
          DioExceptionType.connectionError,
        ),
        cfg,
      );
      expect(e.reason, ConnectionErrorReason.refused);
      expect(e.message, contains('unreachable'));
    });

    test('DNS wording in the message only → dns', () {
      final e = connectionErrorFromDio(
        ex(
          StateError('Failed host lookup for nope.invalid'),
          DioExceptionType.connectionError,
          message: 'Failed host lookup',
        ),
        cfg,
      );
      expect(e.reason, ConnectionErrorReason.dns);
    });

    test('connectionTimeout / receiveTimeout → timeout', () {
      expect(
        connectionErrorFromDio(
          ex(null, DioExceptionType.connectionTimeout),
          cfg,
        ).reason,
        ConnectionErrorReason.timeout,
      );
      expect(
        connectionErrorFromDio(
          ex(null, DioExceptionType.receiveTimeout),
          cfg,
        ).reason,
        ConnectionErrorReason.timeout,
      );
    });

    test('HTTP 401 → unauthorized, names the status', () {
      final e = connectionErrorFromDio(
        ex(null, DioExceptionType.badResponse, status: 401),
        cfg,
      );
      expect(e.reason, ConnectionErrorReason.unauthorized);
      expect(e.httpStatus, 401);
      expect(e.message, contains('401'));
    });

    test('other HTTP status → http, names the status', () {
      final e = connectionErrorFromDio(
        ex(null, DioExceptionType.badResponse, status: 500),
        cfg,
      );
      expect(e.reason, ConnectionErrorReason.http);
      expect(e.message, contains('500'));
    });

    test('unknown failure → other, still mentions the target', () {
      final e = connectionErrorFromDio(
        ex('weird', DioExceptionType.unknown),
        cfg,
      );
      expect(e.reason, ConnectionErrorReason.other);
      expect(e.message, contains('192.168.1.13:3689'));
    });
  });
}
