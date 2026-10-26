import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:logger/logger.dart';
import 'package:provider/provider.dart';

import 'src/audio/mirror_handler.dart';
import 'src/call/call_state.dart';
import 'src/connection/connection_controller.dart';
import 'src/outputs/outputs_controller.dart';
import 'src/player/player_controller.dart';
import 'src/queue/queue_controller.dart';
import 'src/rating/rating_controller.dart';
import 'src/settings/settings_store.dart';
import 'src/ui/root_screen.dart';

/// Debug handle for the UI-debug loop (evaluate_expression).
Object? debugGlobals;

final _logger = Logger(printer: PrettyPrinter(methodCount: 0));

bool _audioStarted = false;

/// D20: the rocker may touch the server volume only while foregrounded; the
/// handler needs the lifecycle state even though the audio service starts
/// independently of the UI.
MirrorAudioHandler? _audioHandler;

/// Forwards app lifecycle transitions to the audio handler (D20).
class _AppForegroundTracker extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _audioHandler?.setAppForeground(state == AppLifecycleState.resumed);
  }
}

Future<void> main() async {
  // Debug builds: expose the semantics tree to uiautomator so UI checks can
  // read labels/bounds without image input. (3.41: SemanticsBinding is a
  // mixin on the root binding.)
  WidgetsFlutterBinding.ensureInitialized().ensureSemantics();

  final callState = CallStateService();
  await callState.start();
  final pending = await callState.requestPermissions();
  _logger.i('pending runtime permissions after request: ${pending.keys}');

  final store = await SettingsStore.create();
  final conn = ConnectionController(logger: _logger);
  final player = PlayerController(connection: conn);
  final outputs = OutputsController(connection: conn);
  final queue = QueueController(connection: conn);
  final rating = RatingController(connection: conn, player: player);
  await player.init();
  await outputs.init();
  await queue.init();
  await rating.init();
  debugGlobals = {
    'conn': conn,
    'player': player,
    'outputs': outputs,
    'queue': queue,
    'rating': rating,
  };

  // Call handling (D9): pause on ringing, auto-resume on idle when the call
  // caused the pause.
  callState.states.listen((state) {
    _logger.i('call state: $state');
    switch (state) {
      case 'ringing':
        player.onCallRinging();
      case 'active':
        player.onCallActive();
      case 'idle':
        unawaited(player.onCallEnded());
      default:
        break;
    }
  });

  // The media session / FGS/notification come up on the first successful
  // connection (R-07: present "while the app is connected").
  conn.addListener(() {
    if (conn.isConnected && !_audioStarted) {
      _audioStarted = true;
      unawaited(_initAudio(player));
    }
  });

  // R-01: auto-connect on launch when a server is configured.
  final saved = store.config;
  if (saved != null) {
    _logger.i('auto-connecting to $saved');
    await conn.connectTo(saved);
  }

  WidgetsBinding.instance.addObserver(_AppForegroundTracker());

  runApp(
    MultiProvider(
      providers: [
        Provider<SettingsStore>.value(value: store),
        ChangeNotifierProvider<ConnectionController>.value(value: conn),
        ChangeNotifierProvider<PlayerController>.value(value: player),
        ChangeNotifierProvider<OutputsController>.value(value: outputs),
        ChangeNotifierProvider<QueueController>.value(value: queue),
        ChangeNotifierProvider<RatingController>.value(value: rating),
      ],
      child: const OwntoneRemoteApp(),
    ),
  );
}

/// audio_service wiring — the FGS/notification plumbing (spike-validated).
/// Failures here degrade to a headless app (controls still work in-UI);
/// they must never take the app down.
Future<void> _initAudio(PlayerController player) async {
  try {
    // androidStopForegroundOnPause: false — keep the mediaPlayback FGS
    // alive while the server is paused (spike criterion 7, Finding 3).
    final handler = await AudioService.init(
      builder: () => MirrorAudioHandler(player),
      config: const AudioServiceConfig(
        androidStopForegroundOnPause: false,
        androidNotificationChannelName: 'OwnTone Remote',
      ),
    );
    _audioHandler = handler;
    // Seed the D20 foreground flag with the current lifecycle (a normal
    // launch is resumed; a service-only restart is not — and must not map
    // rocker presses to the server until the app actually foregrounds).
    handler.setAppForeground(
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    await handler.start();
  } catch (e) {
    _logger.e('audio init failed (app stays functional)', error: e);
  }
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
      home: const RootScreen(),
    );
  }
}
