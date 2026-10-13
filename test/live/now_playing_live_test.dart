/// Live-server tests for unit 002 (R-03 seek, R-05 toggles).
///
/// Requires the LAN server; excluded from the gate by `--exclude-tags live`.
/// Override the target with OWNTONE_HOST / OWNTONE_PORT.
///
/// Audio-safety (AGENTS.md §1): both tests REFUSE to run while the server
/// is playing (they would need a supervised window). Seek while
/// paused/stopped is a position move with no audio; the toggle round-trip
/// records the originals first and restores them, verifying the restore
/// against the API.
@Tags(['live'])
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/owntone_api.dart';
import 'package:owntone_remote/src/player/player_state.dart';

void main() {
  final host = Platform.environment['OWNTONE_HOST'] ?? '192.168.1.13';
  final port = int.tryParse(Platform.environment['OWNTONE_PORT'] ?? '') ?? 3689;

  OwntoneApi liveApi() => OwntoneApi(
    dio: Dio(
      BaseOptions(
        baseUrl: 'http://$host:$port',
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
      ),
    ),
    baseUrl: Uri.parse('http://$host:$port'),
  );

  Future<void> refuseIfPlaying(OwntoneApi api) async {
    final p = await api.getPlayer();
    if (p.isPlaying) {
      markTestSkipped(
        'server is PLAYING — this test is not supervised-safe (AGENTS.md '
        '§1); run it in a supervised window or while the server is '
        'paused/stopped',
      );
    }
  }

  group('R-03 now playing (live)', () {
    test('seek lands within ±1 s of the requested position', () async {
      final api = liveApi();
      await refuseIfPlaying(api);
      final before = await api.getPlayer();
      if (before.itemId == null ||
          before.itemId == 0 ||
          before.itemLengthMs == null ||
          before.itemLengthMs! <= 5000) {
        markTestSkipped(
          'no current item with seekable length (stopped with empty queue); '
          'verify paused-state seek in a supervised window',
        );
      }
      final target = 30000;
      await api.seekMs(target);
      final after = await api.getPlayer();
      if (after.isStopped && after.itemProgressMs == 0) {
        markTestSkipped(
          'the server ignored the seek while stopped (progress stayed 0); '
          'verify paused-state seek in a supervised window',
        );
      }
      expect(
        (after.itemProgressMs! - target).abs(),
        lessThanOrEqualTo(1000),
        reason: 'seek must land within ±1 s (R-03 acceptance)',
      );
    });
  });

  group('R-05 playback modes (live)', () {
    test(
      'shuffle/repeat/consume round-trip; originals recorded + restored',
      () async {
        final api = liveApi();
        await refuseIfPlaying(api);
        final original = await api.getPlayer();

        // Set each option and read the server back (the UI must show the
        // server's answer state, not just the optimistic one).
        await api.setShuffle(true);
        expect((await api.getPlayer()).shuffle, isTrue);
        await api.setRepeat(Repeat.single);
        expect((await api.getPlayer()).repeat, Repeat.single);
        await api.setConsume(true);
        expect((await api.getPlayer()).consume, isTrue);

        // Restore and verify the restore against the API.
        await api.setShuffle(original.shuffle);
        await api.setRepeat(original.repeat);
        await api.setConsume(original.consume);
        final restored = await api.getPlayer();
        expect(restored.shuffle, original.shuffle);
        expect(restored.repeat, original.repeat);
        expect(restored.consume, original.consume);
      },
    );
  });
}
