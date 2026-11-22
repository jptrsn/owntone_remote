import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../audio/mirror_handler.dart';
import '../connection/connection_controller.dart';
import '../player/player_controller.dart';
import 'root_screen.dart';

/// R-22 (issue #45, N-01): the persistent bottom mini transport bar.
///
/// Pinned on every main screen except Now Playing (hosted as
/// `Scaffold.bottomNavigationBar` by [BrowseScreenScaffold], the Outputs
/// screen, and the Settings screen — its own layer, never a list footer:
/// it must not scroll away and must not steal taps from rows).
///
/// Visibility is exactly "a current item exists": playing OR paused
/// (ReTune keeps the bar through pause), hidden when stopped /
/// `nowPlaying == null`. ReTune keeps dead transport buttons when stopped
/// — that is deliberately NOT copied (recorded simplification, PR body).
/// There is no auto-hide (contrast the transient volume toast).
///
/// Presses route to [PlayerController] (`play`/`pause`/`next`/`previous`)
/// only. They must **never** reach `QueueController.playUris` — that call
/// carries `clear=true` and replaces the queue (the issue-#21 defect).
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    // Nullable-Provider.of (provider's nullable-generic idiom):
    // `Provider.of<T?>` answers null when no provider is registered, so
    // screens pumped without the player providers (some widget tests)
    // collapse to no bar instead of throwing; production always provides
    // both from main()'s MultiProvider. listen: true keeps the bar fresh.
    final player = Provider.of<PlayerController?>(context, listen: true);
    final conn = Provider.of<ConnectionController?>(context, listen: true);
    if (player == null || conn == null) return const SizedBox.shrink();
    final item = player.nowPlaying;
    final p = player.player;
    if (item == null || p == null || p.isStopped) {
      return const SizedBox.shrink();
    }
    final enabled = conn.phase == ConnectionPhase.connected;
    final theme = Theme.of(context);
    // Icon/state mapping identical to the media-session controls: the
    // first entry of `controlsFor` is the play/pause control itself
    // (R-22 — do not re-derive the condition beside it).
    final showPause = controlsFor(p).first == MediaControl.pause;
    final secondary = [
      item.artist,
      item.album,
    ].where((s) => s != null && s.isNotEmpty).join(' - ');

    return Material(
      key: const ValueKey('mini-player'),
      color: theme.colorScheme.surfaceContainer,
      // Scaffold does NOT apply SafeArea to a bottomNavigationBar child
      // (the M3 bottom widgets — NavigationBar/BottomAppBar — wrap their
      // own child in SafeArea; the M2 widget does not): without this the
      // transport buttons sit under the 3-button system nav strip / in the
      // gesture area (PR #57 review major; the device dump showed the bar
      // bottom at the 2400-px screen edge). The Material keeps painting
      // under the inset; only the content is lifted.
      child: SafeArea(
        top: false,
        left: false,
        right: false,
        child: Row(
          children: [
            // Metadata zone (ReTune's text rows; a tap lands on Now Playing).
            // Navigation only — live while offline like the drawer's
            // Now Playing entry.
            Expanded(
              child: Semantics(
                key: const ValueKey('mini-metadata-semantics'),
                button: true,
                label: 'Open now playing',
                child: InkWell(
                  key: const ValueKey('mini-metadata'),
                  onTap: () => showNowPlaying(context),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    // MainAxisSize.min is load-bearing: Scaffold lays out
                    // bottomNavigationBar with LOOSE constraints (up to the
                    // full screen height), and a max-sizing Column would
                    // then grow to the whole viewport — an 800-px bar and a
                    // zero-height body (pinned by the height assertion in
                    // test/mini_player_test.dart).
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.title ?? 'Unknown title',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        if (secondary.isNotEmpty)
                          Text(
                            secondary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('mini-previous'),
              tooltip: 'Previous',
              onPressed: enabled ? player.previous : null,
              icon: const Icon(Icons.skip_previous, semanticLabel: 'Previous'),
            ),
            IconButton(
              key: const ValueKey('mini-play-pause'),
              tooltip: showPause ? 'Pause' : 'Play',
              onPressed: enabled
                  ? (showPause ? player.pause : player.play)
                  : null,
              icon: Icon(
                showPause ? Icons.pause : Icons.play_arrow,
                semanticLabel: showPause ? 'Pause' : 'Play',
              ),
            ),
            IconButton(
              key: const ValueKey('mini-next'),
              tooltip: 'Next',
              onPressed: enabled ? player.next : null,
              icon: const Icon(Icons.skip_next, semanticLabel: 'Next'),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}
