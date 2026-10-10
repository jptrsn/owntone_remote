import 'dart:async';

import 'package:flutter/services.dart';

/// Dart side of the Kotlin platform plugin:
///  - call-state events pushed from TelephonyCallback
///  - the Android 13+ notification permission request
class CallStateService {
  static const _callChannel = MethodChannel('owntone_remote/call_state');
  static const _permChannel = MethodChannel('owntone_remote/permissions');

  final _states = StreamController<String>.broadcast();

  /// `ringing` | `active` | `idle`
  Stream<String> get states => _states.stream;

  /// Start receiving call-state pushes. Call once at startup.
  Future<void> start() async {
    _callChannel.setMethodCallHandler((call) async {
      if (call.method == 'callStateChanged') {
        final s = call.arguments;
        if (s is String) _states.add(s);
      }
    });
  }

  /// Requests the runtime permissions (POST_NOTIFICATIONS on 33+,
  /// READ_PHONE_STATE for the call listener). Returns the permission map
  /// the platform reported (name -> granted); empty when nothing was
  /// pending.
  Future<Map<String, bool>> requestPermissions() async {
    try {
      final res = await _permChannel.invokeMethod<dynamic>(
        'requestPermissions',
      );
      final map = <String, bool>{};
      if (res is Map) {
        res.forEach((k, v) {
          if (k is String) map[k] = v == true;
        });
      }
      return map;
    } on PlatformException {
      return {};
    }
  }

  Future<void> dispose() => _states.close();
}
