/// Live-server tests (R-01, R-02) — unit 001 criterion 7.
///
/// Requires the LAN server; excluded from the gate by `--exclude-tags live`.
/// Override the target with OWNTONE_HOST / OWNTONE_PORT.
///
/// Audio-safety (AGENTS.md §1): these tests never touch playback. The only
/// mutation is a master-volume change (safe in any state) which is recorded,
/// restored, and the restore verified against the API.
@Tags(['live'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';

/// connectTo() returns as soon as REST is up; the WS handshake is still in
/// flight, so tests must wait for [WsPhase.open] before acting.
Future<void> untilWsOpen(
  ConnectionController conn, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (conn.wsPhase == WsPhase.open) return;
  final done = Completer<void>();
  void check() {
    if (conn.wsPhase == WsPhase.open && !done.isCompleted) done.complete();
  }

  conn.addListener(check);
  try {
    await done.future.timeout(timeout);
  } on TimeoutException {
    throw StateError('WS did not open within $timeout: ${conn.wsPhase}');
  } finally {
    conn.removeListener(check);
  }
}

void main() {
  final host = Platform.environment['OWNTONE_HOST'] ?? '192.168.1.13';
  final port = int.tryParse(Platform.environment['OWNTONE_PORT'] ?? '') ?? 3689;

  group('R-01 connection (live)', () {
    test('valid host connects; WS port derived from /api/config', () async {
      final conn = ConnectionController();
      addTearDown(conn.dispose);

      await conn.connectTo(ServerConfig(host: host, port: port));

      expect(
        conn.phase,
        ConnectionPhase.connected,
        reason: conn.errorMessage ?? 'no message',
      );
      expect(conn.serverVersion, isNotEmpty);
      await untilWsOpen(conn);
      expect(conn.wsPhase, WsPhase.open);
      // The WS URL must come from /api/config's websocket_port.
      final serverWsPort =
          (await conn.api!.getConfig())['websocket_port'] as int;
      expect(conn.wsUri!.port, serverWsPort);
    });

    test('unresolvable host → DNS-specific error', () async {
      final conn = ConnectionController();
      addTearDown(conn.dispose);

      await conn.connectTo(
        const ServerConfig(host: 'no-such-owntone-server.invalid', port: 3689),
      );

      expect(conn.phase, ConnectionPhase.error);
      expect(conn.errorMessage!.toLowerCase(), contains('resolve'));
    });

    test('closed port → refused/unreachable error', () async {
      final conn = ConnectionController();
      addTearDown(conn.dispose);

      // A port OwnTone does not listen on (JSON port + an offset no
      // service uses on this box).
      await conn.connectTo(ServerConfig(host: host, port: port + 599));

      expect(conn.phase, ConnectionPhase.error);
      expect(conn.errorMessage, isNotNull);
      final lower = conn.errorMessage!.toLowerCase();
      expect(
        lower.contains('refused') ||
            lower.contains('unreachable') ||
            lower.contains('could not reach'),
        isTrue,
        reason: conn.errorMessage,
      );
    });
  });

  group('R-02 websocket sync (live)', () {
    test('server-side volume change (paused-state action) reaches the app '
        'via WS within ~2 s, then the volume is restored', () async {
      final conn = ConnectionController();
      addTearDown(conn.dispose);
      await conn.connectTo(ServerConfig(host: host, port: port));
      expect(
        conn.phase,
        ConnectionPhase.connected,
        reason: conn.errorMessage ?? 'no message',
      );
      // Only act once the WS is actually open — events emitted before the
      // handshake completes are lost (the server sends no backlog).
      await untilWsOpen(conn);

      final api = conn.api!;
      final before = (await api.getPlayer()).volume;
      final target = before >= 95 ? before - 5 : before + 5;

      final volumeSeen = Completer<int>();
      final sub = conn.events.listen((events) {
        if (events.contains('volume') && !volumeSeen.isCompleted) {
          // The event is an invalidation: read the fresh value back.
          unawaited(
            api.getPlayer().then((p) {
              if (!volumeSeen.isCompleted) volumeSeen.complete(p.volume);
            }),
          );
        }
      });
      addTearDown(sub.cancel);
      // The restore must run even when the assertion below fails (audio
      // safety: never leave the server's volume changed).
      addTearDown(() async {
        final v = (await api.getPlayer()).volume;
        if (v != before) await api.setVolume(before);
      });

      await api.setVolume(target);
      int observed = -1;
      try {
        observed = await volumeSeen.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // observed stays -1 → the expect below fails with a clear reason.
      }
      expect(
        observed,
        target,
        reason: 'the WS volume event must reach the app within ~2 s',
      );

      // Restore and verify the restore against the API.
      await api.setVolume(before);
      final restored = (await api.getPlayer()).volume;
      expect(restored, before);
    });
  });
}
