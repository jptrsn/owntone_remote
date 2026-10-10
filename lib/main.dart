import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

import 'src/api/owntone_api.dart';
import 'src/audio/mirror_handler.dart';
import 'src/call/call_state.dart';
import 'src/player/player_controller.dart';
import 'src/ui/now_playing_screen.dart';

/// Spike server (hardcoded per unit 001; manual entry is remote-app work).
const _serverBase = 'http://192.168.1.13:3689';

/// Debug handle for the UI-debug loop (evaluate_expression).
Object? debugGlobals;

final _logger = Logger(printer: PrettyPrinter(methodCount: 0));

Future<void> main() async {
  // Debug builds: expose the semantics tree to uiautomator so UI checks can
  // read labels/bounds without image input. (3.41: SemanticsBinding is a
  // mixin on the root binding.)
  WidgetsFlutterBinding.ensureInitialized().ensureSemantics();

  final callState = CallStateService();
  await callState.start();
  final pending = await callState.requestPermissions();
  _logger.i('pending runtime permissions after request: ${pending.keys}');

  final dio = Dio(
    BaseOptions(
      baseUrl: _serverBase,
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );
  final api = OwntoneApi(dio: dio, baseUrl: Uri.parse(_serverBase));
  final player = PlayerController(api: api);
  debugGlobals = {'player': player, 'api': api};

  // Call handling (D9): pause on ringing, auto-resume on idle when the call
  // caused the pause.
  callState.states.listen((state) {
    _logger.i('call state: $state');
    switch (state) {
      case 'ringing':
        player.onCallRinging();
      case 'active':
        break;
      case 'idle':
        unawaited(player.onCallEnded());
      default:
        break;
    }
  });

  // First fetch (so the wake below sees real metadata), then the handler.
  await player.init();

  // androidStopForegroundOnPause: false — keep the mediaPlayback FGS alive
  // while the server is paused. This is the survival behaviour under test
  // (unit 001 criterion 7).
  final handler = await AudioService.init(
    builder: () => MirrorAudioHandler(player),
    config: const AudioServiceConfig(
      androidStopForegroundOnPause: false,
      androidNotificationChannelName: 'OwnTone Remote',
    ),
  );
  await handler.start();

  runApp(
    ChangeNotifierProvider<PlayerController>.value(
      value: player,
      child: const OwntoneRemoteApp(),
    ),
  );
}

class OwntoneRemoteApp extends StatelessWidget {
  const OwntoneRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OwnTone Remote',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7C5CBF)),
      ),
      home: const NowPlayingScreen(),
    );
  }
}
