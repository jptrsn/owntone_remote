import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../settings/settings_store.dart';
import 'browse_screens.dart';
import 'outputs_screen.dart';
import 'queue_screen.dart';
import 'root_screen.dart';
import 'settings_screen.dart';

/// A drawer destination (R-21, issue #44). The [label] is the row text;
/// the enum value doubles as the `selected:` identity the hosting screen
/// passes to [AppDrawer] so its own row carries `Semantics(selected:)`.
enum DrawerDestination {
  nowPlaying('Now Playing', Icons.play_arrow),
  queue('Queue', Icons.queue_music),
  library('Library', Icons.library_music),
  playlists('Playlists', Icons.playlist_play),
  artists('Artists', Icons.person),
  albums('Albums', Icons.album),
  songs('Songs', Icons.music_note),
  genres('Genres', Icons.label_outline),
  settings('Settings', Icons.settings),
  outputs('Outputs', Icons.speaker);

  const DrawerDestination(this.label, this.icon);

  final String label;
  final IconData icon;

  /// Destinations whose screen fetches from the server on open — inert
  /// while [ConnectionPhase.offline], matching the now-playing entry-row
  /// contract ("Controls disabled"). Now Playing (a plain pop) and
  /// Settings (the server-entry form itself, the offline escape hatch)
  /// stay live; the app-bar Outputs action keeps its own pressable-while-
  /// offline contract (R-18) — the two entry points were adjudicated
  /// separately, do not "unify" them.
  bool get serverTouching => switch (this) {
    DrawerDestination.nowPlaying || DrawerDestination.settings => false,
    _ => true,
  };
}

/// The R-21 navigation drawer (ReTune's pattern, `docs/retune-capture/
/// 02-navigation-drawer/` + `23-playing-audit`): header **Connected To —
/// server name** (`library_name` from `/api/config`), sections
/// **Playing** (Now Playing · Queue), **Library** (home + direct deep
/// links into the views — Songs per R-15/#38), **Settings** (Settings ·
/// Outputs). ReTune's missing-drawer-on-UpNext quirk is NOT copied
/// (`23-playing-audit`: drawer opens from library/np/search/settings but
/// not UpNextActivity — ours opens everywhere).
///
/// Navigation contract (frozen, issue #44): every destination except Now
/// Playing lands through [showDrawerDestination] — `popUntil(isFirst)`
/// then push, so a pushed screen never stacks a duplicate route (the
/// [showNowPlaying] doc-comment warning, root_screen.dart). The selected
/// destination renders highlighted + `Semantics(selected:)` via
/// [ListTile.selected] (ReTune exposes no selection state — unit-009
/// pattern, do better).
class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key, this.selected});

  /// The destination whose screen hosts this drawer (null = a screen with
  /// no drawer destination, e.g. a playlist's tracks: no row is marked).
  final DrawerDestination? selected;

  void _open(BuildContext context, DrawerDestination dest) {
    // Close the drawer first: popUntil only removes routes, and a push on
    // the root route leaves this Scaffold's drawer sitting open underneath.
    Scaffold.of(context).closeDrawer();
    if (dest == DrawerDestination.nowPlaying) {
      showNowPlaying(context);
      return;
    }
    // issue #64: Settings is the only destination that needs app state, and
    // it must be read HERE, at tap time. The closure below is the pushed
    // route's page builder — `showDrawerDestination` already popped this
    // drawer's own route by the time it first runs, and re-runs it on every
    // later rebuild of that route, so a `context.read` inside it resolves
    // against a defunct element and red-screens the app. See the doc comment
    // on [showDrawerDestination].
    final settingsInitial = dest == DrawerDestination.settings
        ? (context.read<ConnectionController>().config ??
              context.read<SettingsStore>().config)
        : null;
    showDrawerDestination(
      context,
      (routeContext) => switch (dest) {
        DrawerDestination.queue => const QueueScreen(),
        DrawerDestination.library => const LibraryHomeScreen(),
        DrawerDestination.playlists => const PlaylistsScreen(),
        DrawerDestination.artists => const ArtistsScreen(),
        DrawerDestination.albums => const AlbumsScreen(),
        DrawerDestination.songs => const TracksScreen(),
        DrawerDestination.genres => const GenresScreen(),
        DrawerDestination.settings => SettingsScreen(initial: settingsInitial),
        DrawerDestination.outputs => const OutputsScreen(),
        DrawerDestination.nowPlaying => throw StateError(
          'handled by the pop above',
        ),
      },
    );
  }

  Widget _tile(BuildContext context, DrawerDestination dest, bool connected) {
    final enabled = !dest.serverTouching || connected;
    final isSelected = selected == dest;
    // ListTile.selected forwards to Semantics(selected:) + enabled:
    // (list_tile.dart's own Semantics node) — the explicit selected-state
    // a11y carry the frozen spec demands (ReTune has none).
    return ListTile(
      key: ValueKey('drawer-${dest.name}'),
      selected: isSelected,
      // ListTile's own `enabled` (defaults true — a null onTap does NOT
      // disable its semantics/colour): the offline-inert contract needs
      // the flag too, matching the now-playing entry rows' disabled look.
      enabled: enabled,
      leading: Icon(dest.icon),
      title: Text(dest.label),
      onTap: enabled ? () => _open(context, dest) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final connected = conn.phase == ConnectionPhase.connected;
    final theme = Theme.of(context);
    // PR #56 review (LOW): the idle Connect screen can open the drawer;
    // claiming "Connected To — <host>" there asserts a connection that
    // never happened. Pre-first-connect reads "Not connected" instead.
    final serverName = conn.phase == ConnectionPhase.idle
        ? null
        : (conn.serverName ?? conn.config?.host);
    return Drawer(
      child: SafeArea(
        right: false,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(
                      serverName == null
                          ? 'Not connected'
                          : 'Connected To — $serverName',
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // Server version (was the now-playing app bar's label —
                    // see the note there for why it moved here).
                    if (conn.serverVersion != null)
                      Text(
                        'OwnTone ${conn.serverVersion}',
                        style: theme.textTheme.labelSmall,
                      ),
                  ],
                ),
              ),
            ),
            _section(context, 'Playing'),
            for (final d in const [
              DrawerDestination.nowPlaying,
              DrawerDestination.queue,
            ])
              _tile(context, d, connected),
            _section(context, 'Library'),
            for (final d in const [
              DrawerDestination.library,
              DrawerDestination.playlists,
              DrawerDestination.artists,
              DrawerDestination.albums,
              DrawerDestination.songs,
              DrawerDestination.genres,
            ])
              _tile(context, d, connected),
            _section(context, 'Settings'),
            for (final d in const [
              DrawerDestination.settings,
              DrawerDestination.outputs,
            ])
              _tile(context, d, connected),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

/// AppBar leading for a screen that has a drawer (R-21).
///
/// AppBar's auto-leading shows a DrawerButton *instead of* a BackButton
/// once the Scaffold has a drawer (app_bar.dart's `if (hasDrawer)` branch
/// — never both), which would strand every pushed screen without a back
/// arrow the moment it gains the hamburger. So pushed screens pass this
/// pair explicitly (hamburger leftmost, per the Material nav-icon
/// position); root routes get the hamburger alone. Do not "simplify" to
/// `leading: null` — that deletes the back arrow on all browse/queue/
/// outputs/settings routes and breaks their back-navigation tests.
///
/// MUST be used together with [drawerAwareLeadingWidth] (the AppBar's
/// leading slot is otherwise pinned to 56 px and the pair overflows it by
/// 40 px — mutation-verified in test/app_drawer_test.dart).
Widget drawerAwareLeading(BuildContext context) =>
    Navigator.of(context).canPop()
    ? const Row(
        mainAxisSize: MainAxisSize.min,
        children: [DrawerButton(), BackButton()],
      )
    : const DrawerButton();

/// The `leadingWidth:` that pairs with [drawerAwareLeading] — AppBar wraps
/// the leading in a fixed-width slot (`_kLeadingWidth` = 56), so the
/// two-button pushed-screen variant needs both slots' worth (2 × 48).
/// Same `canPop` source as the leading itself; keep them paired.
double drawerAwareLeadingWidth(BuildContext context) =>
    Navigator.of(context).canPop() ? 96 : 56;
