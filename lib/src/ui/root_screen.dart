import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../settings/settings_store.dart';
import 'now_playing_screen.dart';
import 'settings_screen.dart';

/// Switch the active screen to the Now Playing view (issue #24, R-13).
///
/// This is the app's "tab switch": there is no tab bar — [RootScreen]
/// renders [NowPlayingScreen] as the root route and every listen screen
/// (Library/Search, Queue, Outputs) is *pushed on top of it*, so landing on
/// Now Playing is popping the stack back to its first route. Play-from-a-
/// list taps (search results) call this after queueing playback so the user
/// ends up on the player instead of the list they played from. Do not
/// replace with a `push`: that would stack a second now-playing screen on
/// top and the back gesture would walk the duplicate.
void showNowPlaying(BuildContext context) =>
    Navigator.of(context).popUntil((route) => route.isFirst);

/// Land on a drawer destination without ever stacking a duplicate (R-21,
/// issue #44). Same trap as [showNowPlaying]'s warning: every listen screen
/// is *pushed on top of* the Now Playing root route, so a drawer tap from a
/// pushed screen that only pushed would leave the old stack below the new
/// screen — the back gesture would walk the duplicates. `popUntil(isFirst)`
/// collapses to the root first, then a single push: the stack is always
/// [root, target] (depth 2) no matter how deep the source screen was. The
/// regression test asserts exactly this depth (test/app_drawer_test.dart) —
/// do not replace with a bare push.
void showDrawerDestination(BuildContext context, Widget Function() screen) {
  final navigator = Navigator.of(context);
  navigator.popUntil((route) => route.isFirst);
  navigator.push(MaterialPageRoute<void>(builder: (_) => screen()));
}

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
///
/// PR #56 review (LOW) adjudication: these phase screens carry no
/// hamburger on purpose — R-21 enumerates the *main* screens; transient
/// connect/error states are not navigation surfaces. The error screen's
/// retry affordance is its own button (not the drawer).
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
