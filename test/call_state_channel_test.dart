import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/call/call_state.dart';

/// R-08: Dart side of the Kotlin `owntone_remote/call_state` channel —
/// call-state pushes (ringing | active | idle) and the permission request
/// on `owntone_remote/permissions`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const callChannel = MethodChannel('owntone_remote/call_state');
  const permChannel = MethodChannel('owntone_remote/permissions');

  tearDown(() {
    callChannel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(permChannel, null);
  });

  Future<void> push(MethodCall call) async {
    await messenger.handlePlatformMessage(
      'owntone_remote/call_state',
      const StandardMethodCodec().encodeMethodCall(call),
      (data) {},
    );
    await pumpEventQueue();
  }

  group('CallStateService (R-08: call_state channel)', () {
    test('start() delivers ringing -> active -> idle in order', () async {
      final svc = CallStateService();
      await svc.start();
      final got = <String>[];
      final sub = svc.states.listen(got.add);
      await push(const MethodCall('callStateChanged', 'ringing'));
      await push(const MethodCall('callStateChanged', 'active'));
      await push(const MethodCall('callStateChanged', 'idle'));
      expect(got, ['ringing', 'active', 'idle']);
      await sub.cancel();
    });

    test('non-String argument emits nothing', () async {
      final svc = CallStateService();
      await svc.start();
      final got = <String>[];
      final sub = svc.states.listen(got.add);
      await push(const MethodCall('callStateChanged', 42));
      expect(got, isEmpty);
      await sub.cancel();
    });

    test('null argument emits nothing', () async {
      final svc = CallStateService();
      await svc.start();
      final got = <String>[];
      final sub = svc.states.listen(got.add);
      await push(const MethodCall('callStateChanged', null));
      expect(got, isEmpty);
      await sub.cancel();
    });

    test('unrelated method name emits nothing', () async {
      final svc = CallStateService();
      await svc.start();
      final got = <String>[];
      final sub = svc.states.listen(got.add);
      await push(const MethodCall('otherMethod', 'ringing'));
      expect(got, isEmpty);
      await sub.cancel();
    });

    test(
      'push before start() is dropped; after start() it is delivered',
      () async {
        final svc = CallStateService();
        final got = <String>[];
        final sub = svc.states.listen(got.add);
        await push(const MethodCall('callStateChanged', 'ringing'));
        expect(got, isEmpty);
        await svc.start();
        await push(const MethodCall('callStateChanged', 'active'));
        expect(got, ['active']);
        await sub.cancel();
      },
    );

    test('requestPermissions returns the platform map verbatim', () async {
      messenger.setMockMethodCallHandler(
        permChannel,
        (call) async => {'POST_NOTIFICATIONS': true, 'READ_PHONE_STATE': false},
      );
      final svc = CallStateService();
      expect(await svc.requestPermissions(), {
        'POST_NOTIFICATIONS': true,
        'READ_PHONE_STATE': false,
      });
    });

    test('requestPermissions returns {} on PlatformException', () async {
      messenger.setMockMethodCallHandler(
        permChannel,
        (call) async => throw PlatformException(code: 'x'),
      );
      final svc = CallStateService();
      expect(await svc.requestPermissions(), isEmpty);
    });

    test('dispose() closes the states stream', () async {
      final svc = CallStateService();
      await svc.start();
      await svc.dispose();
      final done = Completer<void>();
      svc.states.listen(null, onDone: () => done.complete());
      await done.future;
    });

    test('two listeners both receive the same pushed event', () async {
      final svc = CallStateService();
      await svc.start();
      final a = <String>[];
      final b = <String>[];
      final s1 = svc.states.listen(a.add);
      final s2 = svc.states.listen(b.add);
      await push(const MethodCall('callStateChanged', 'ringing'));
      expect(a, ['ringing']);
      expect(b, ['ringing']);
      await s1.cancel();
      await s2.cancel();
    });
  });
}
