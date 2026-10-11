import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/core/server_config.dart';

void main() {
  group('ServerConfig (R-01)', () {
    test('valid config has no validation error', () {
      expect(
        const ServerConfig(host: '192.168.1.13', port: 3689).validationError,
        isNull,
      );
      expect(const ServerConfig(host: 'owntone.lan', port: 80).isValid, isTrue);
    });

    test('empty / blank host is rejected', () {
      expect(
        const ServerConfig(host: '', port: 3689).validationError,
        isNotNull,
      );
      expect(const ServerConfig(host: '   ', port: 3689).isValid, isFalse);
    });

    test('port out of range is rejected', () {
      expect(const ServerConfig(host: 'h', port: 0).validationError, isNotNull);
      expect(
        const ServerConfig(host: 'h', port: 65536).validationError,
        isNotNull,
      );
      expect(const ServerConfig(host: 'h', port: 65535).isValid, isTrue);
    });

    test('jsonBase is the JSON API root', () {
      final uri = const ServerConfig(host: '10.0.0.5', port: 3689).jsonBase;
      expect(uri, Uri.parse('http://10.0.0.5:3689/'));
    });

    test('equality is host+port', () {
      expect(
        const ServerConfig(host: 'a', port: 1),
        const ServerConfig(host: 'a', port: 1),
      );
      expect(
        const ServerConfig(host: 'a', port: 1) ==
            const ServerConfig(host: 'b', port: 1),
        isFalse,
      );
    });
  });
}
