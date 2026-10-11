import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../settings/settings_store.dart';
import 'now_playing_screen.dart';
import 'settings_screen.dart';

/// Switches the app on the connection phase (R-01, unit 001 criterion 6):
///   idle       → settings (first launch / after disconnect)
///   connecting → spinner
///   error      → typed error screen (retry / settings)
///   connected / offline → now playing (banner while offline)
class RootScreen extends StatelessWidget {
  const RootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final store = context.watch<SettingsStore>();
    return switch (conn.phase) {
      ConnectionPhase.idle => SettingsScreen(initial: store.config),
      ConnectionPhase.connecting => _ConnectingScreen(config: conn.config),
      ConnectionPhase.error => _ConnectionErrorScreen(
        message: conn.errorMessage ?? 'Connection failed.',
      ),
      ConnectionPhase.connected ||
      ConnectionPhase.offline => const NowPlayingScreen(),
    };
  }
}

class _ConnectingScreen extends StatelessWidget {
  const _ConnectingScreen({this.config});

  final dynamic config;

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    return Scaffold(
      appBar: AppBar(title: const Text('OwnTone Remote')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(
              'Connecting to ${config ?? 'server'}…',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: conn.disconnect, child: const Text('Cancel')),
          ],
        ),
      ),
    );
  }
}

/// R-01 criterion: a *specific, readable* error — DNS vs refused vs 401.
class _ConnectionErrorScreen extends StatelessWidget {
  const _ConnectionErrorScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final conn = context.read<ConnectionController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Cannot connect')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.wifi_off,
                  size: 56,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: conn.retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SettingsScreen(
                        initial:
                            conn.config ?? context.read<SettingsStore>().config,
                      ),
                    ),
                  ),
                  child: const Text('Change server…'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
