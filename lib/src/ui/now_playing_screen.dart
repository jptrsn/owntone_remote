import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../outputs/outputs_controller.dart';
import '../outputs/output.dart';
import '../player/player_controller.dart';
import '../player/player_state.dart';
import '../settings/settings_store.dart';
import 'connection_banner.dart';
import 'settings_screen.dart';

/// The connected state of the app: the live now-playing mirror of the
/// server, with the app-wide offline banner (unit 001 criterion 6) and
/// controls disabled while offline.
class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  Timer? _ticker;
  int? _displayMs;
  int? _baseMs;
  DateTime? _baseTime;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// While the server plays, extrapolate progress locally between refetches
  /// (OwnTone sends no periodic `player` events).
  void _startTicker(PlayerState p) {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final current = context.read<PlayerController>().player;
      if (current == null || !current.isPlaying) return;
      if (current.itemProgressMs != _baseMs) {
        _baseMs = current.itemProgressMs;
        _baseTime = DateTime.now();
      }
      var ms =
          (_baseMs ?? 0) + DateTime.now().difference(_baseTime!).inMilliseconds;
      final total = current.itemLengthMs;
      if (total != null && ms > total) ms = total;
      _displayMs = ms;
      setState(() {});
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final outputs = context.watch<OutputsController>();
    final controller = context.watch<PlayerController>();
    final p = controller.player;
    final enabled = conn.phase == ConnectionPhase.connected;

    if (p == null) _stopTicker();
    if (p != null && p.isPlaying && _ticker == null) _startTicker(p);
    if (p != null && !p.isPlaying) _stopTicker();

    final syncLabel = switch (conn.wsPhase) {
      WsPhase.open => 'sync: live',
      WsPhase.reconnecting => 'sync: reconnecting…',
      WsPhase.disabled => 'sync: off (server)',
      WsPhase.none => 'sync: …',
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('OwnTone Remote'),
        actions: [
          if (conn.serverVersion != null) ...[
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'OwnTone ${conn.serverVersion}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Text(
              syncLabel,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          IconButton(
            tooltip: 'Server settings',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsScreen(
                  initial: conn.config ?? context.read<SettingsStore>().config,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (!enabled)
            const ConnectionBanner(
              message: 'Server unreachable — retrying. Controls disabled.',
            ),
          Expanded(
            child: p == null
                ? Center(
                    child: enabled
                        ? const CircularProgressIndicator()
                        : const Text('Waiting for the server…'),
                  )
                : NowPlayingBody(
                    controller: controller,
                    outputs: outputs.selected,
                    enabled: enabled,
                    displayMs: _displayMs,
                  ),
          ),
        ],
      ),
    );
  }
}

/// The now-playing content (no Scaffold of its own — the
/// [NowPlayingScreen] shell owns the app bar and the offline banner).
class NowPlayingBody extends StatelessWidget {
  const NowPlayingBody({
    super.key,
    required this.controller,
    required this.outputs,
    required this.enabled,
    required this.displayMs,
  });

  final PlayerController controller;
  final List<Output> outputs;
  final bool enabled;
  final int? displayMs;

  static String _fmt(Duration d) => DateFormat('mm:ss').format(
    DateTime.fromMillisecondsSinceEpoch(d.inSeconds.clamp(0, 86399) * 1000),
  );

  @override
  Widget build(BuildContext context) {
    final p = controller.player!;
    final item = controller.nowPlaying;
    final theme = Theme.of(context);

    final totalMs = item?.lengthMs ?? p.itemLengthMs ?? 0;
    final currentMs = displayMs ?? p.itemProgressMs ?? 0;
    final sliderValue = totalMs > 0
        ? (currentMs / totalMs).clamp(0.0, 1.0)
        : 0.0;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.syncError != null)
            Material(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  controller.syncError!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          if (outputs.isNotEmpty) ...[
            Text(
              'Playing via: ${outputs.map((o) => o.name).join(', ')}',
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: 12),
          ],
          // The artwork absorbs the slack: it takes the viewport width on a
          // tall screen and shrinks on a short one — always 1:1, never
          // scrolling (unit 001 criterion 8).
          Expanded(
            child: Center(child: ArtworkBox(url: item?.artworkUrl)),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              item?.title ?? (p.isStopped ? 'Stopped' : 'No current item'),
              style: theme.textTheme.headlineSmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              [
                if (item?.artist != null) item!.artist,
                if (item?.album != null) item!.album,
              ].join(' · '),
              style: theme.textTheme.bodyLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _fmt(Duration(milliseconds: currentMs)),
            textAlign: TextAlign.start,
          ),
          Slider(
            // Direct seek (spike Finding 14's local drag state is deferred to
            // unit 002 with the notification hardening).
            value: sliderValue,
            onChanged: enabled && totalMs > 0
                ? (v) => controller.seekMs((v * totalMs).round())
                : null,
          ),
          Text(_fmt(Duration(milliseconds: totalMs)), textAlign: TextAlign.end),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                iconSize: 32,
                onPressed: enabled && !p.isStopped ? controller.previous : null,
                icon: const Icon(Icons.skip_previous),
              ),
              const SizedBox(width: 24),
              // Playable from the stopped state too: after a stop the current
              // item is still queued and PUT /play restarts it. Disabling the
              // button here would leave the app unable to start playback again.
              IconButton.filled(
                iconSize: 48,
                onPressed: enabled
                    ? (p.isPlaying ? controller.pause : controller.play)
                    : null,
                icon: Icon(p.isPlaying ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 24),
              IconButton.filledTonal(
                iconSize: 32,
                onPressed: enabled && !p.isStopped ? controller.next : null,
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.outlined(
                icon: Icon(
                  p.shuffle ? Icons.shuffle_on : Icons.shuffle,
                  color: p.shuffle ? theme.colorScheme.primary : null,
                ),
                onPressed: enabled
                    ? () => controller.setShuffle(!p.shuffle)
                    : null,
              ),
              IconButton.outlined(
                icon: Icon(
                  switch (p.repeat) {
                    Repeat.off => Icons.repeat,
                    Repeat.all => Icons.repeat,
                    Repeat.single => Icons.repeat_one,
                  },
                  color: p.repeat != Repeat.off
                      ? theme.colorScheme.primary
                      : null,
                ),
                onPressed: enabled ? controller.cycleRepeat : null,
              ),
              IconButton.outlined(
                icon: Icon(
                  p.consume ? Icons.hourglass_bottom : Icons.hourglass_empty,
                  color: p.consume ? theme.colorScheme.primary : null,
                ),
                onPressed: enabled
                    ? () => controller.setConsume(!p.consume)
                    : null,
              ),
              IconButton.outlined(
                icon: const Icon(Icons.stop),
                onPressed: enabled && !p.isStopped ? controller.stop : null,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              const Icon(Icons.volume_down),
              Expanded(
                child: Slider(
                  min: 0,
                  max: 100,
                  value: p.volume.toDouble(),
                  // The displayed value tracks the server (WS `volume` event
                  // → refetch); no local state needed while a finger is down.
                  onChanged: enabled
                      ? (v) => unawaited(controller.setVolume(v.round()))
                      : null,
                ),
              ),
              SizedBox(width: 40, child: Text('${p.volume}')),
              const Icon(Icons.volume_up),
            ],
          ),
        ],
      ),
    );
  }
}

class ArtworkBox extends StatelessWidget {
  const ArtworkBox({super.key, required this.url});

  final Uri? url;

  /// Downscale server-hosted artwork (the unit spec: `?maxwidth=600`).
  static Uri? withMaxWidth(Uri? url) {
    if (url == null || url.queryParameters.containsKey('maxwidth')) return url;
    return url.replace(
      queryParameters: {'maxwidth': '600', ...url.queryParameters},
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artworkUrl = withMaxWidth(url);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
            if (artworkUrl != null)
              Image.network(
                artworkUrl.toString(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Center(
                  child: Icon(Icons.music_note, size: 96, color: Colors.grey),
                ),
              )
            else
              const Center(
                child: Icon(Icons.music_note, size: 96, color: Colors.grey),
              ),
          ],
        ),
      ),
    );
  }
}
