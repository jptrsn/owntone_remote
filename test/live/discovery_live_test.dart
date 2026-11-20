/// Live LAN test for R-20 server auto-discovery (issue #42).
///
/// Run ON THE HOST (real LAN + mDNS multicast):
///   `flutter test --tags live test/live/discovery_live_test.dart`
/// Excluded from the gate by `--exclude-tags live`. Override the target
/// with OWNTONE_HOST / OWNTONE_PORT.
///
/// Audio safety (AGENTS.md §1): the scan is mDNS queries + `GET /api/config`
/// only — no playback, no mutations, nothing to pause-check.
///
/// Criterion (issue #42 repro): the discovered instance must resolve to the
/// host:port whose `/api/config` matches the direct one (version,
/// websocket_port, library_name) — i.e. discovery found the real server,
/// not a look-alike on the shared `_http._tcp` type.
@Tags(['live'])
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/owntone_api.dart';
import 'package:owntone_remote/src/discovery/mdns_discovery.dart';

void main() {
  final host = Platform.environment['OWNTONE_HOST'] ?? '192.168.1.13';
  final port = int.tryParse(Platform.environment['OWNTONE_PORT'] ?? '') ?? 3689;

  OwntoneApi apiAt(String h, int p) => OwntoneApi(
    dio: Dio(
      BaseOptions(
        baseUrl: 'http://$h:$p',
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
      ),
    ),
    baseUrl: Uri.parse('http://$h:$p'),
  );

  test('R-20 LAN scan finds the OwnTone server; the discovered host:port '
      'answers /api/config identically to the direct one', () async {
    final direct = await apiAt(host, port).getConfig();
    expect(direct['version'], isNotNull, reason: 'server must be up');

    final hits = await MdnsOwnToneDiscovery(
      browseWindow: const Duration(seconds: 4),
      answerWindow: const Duration(seconds: 3),
    ).discover();
    // Verbatim evidence for the run report.
    // ignore: avoid_print
    print('R-20 discovered: $hits');

    final matches = hits.where((h) => h.port == port).toList();
    expect(
      matches,
      isNotEmpty,
      reason:
          'no OwnTone hit on :$port — pre-flight (dns-sd) recorded the '
          'instance "My Music on hp-server" on _http._tcp :3689 with '
          'TXT ffid=/mtd-version=; hits: $hits',
    );
    final hit = matches.first;

    // The instance name is the advertised library_name (dns-sd pre-flight
    // cross-check) — and the discovered endpoint must BE the API server.
    expect(hit.name, direct['library_name']);
    final viaHit = await apiAt(hit.host, hit.port).getConfig();
    expect(viaHit['version'], direct['version']);
    expect(viaHit['websocket_port'], direct['websocket_port']);
    expect(viaHit['library_name'], direct['library_name']);
  }, timeout: const Timeout(Duration(seconds: 90)));
}
