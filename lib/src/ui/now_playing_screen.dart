import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../player/player_controller.dart';
import '../player/player_state.dart';

/// The one screen of the spike: live now-playing mirror of the server.
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

  static String _fmt(Duration d) => DateFormat('mm:ss').format(
    DateTime.fromMillisecondsSinceEpoch(d.inSeconds.clamp(0, 86399) * 1000),
  );

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<PlayerController>();
    final p = controller.player;
    final item = controller.nowPlaying;

    if (p == null) {
      _stopTicker();
      return Scaffold(
        appBar: AppBar(title: const Text('OwnTone Remote')),
        body: Center(
          child: controller.error != null
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(controller.error!, textAlign: TextAlign.center),
                )
              : const CircularProgressIndicator(),
        ),
      );
    }

    if (p.isPlaying && _ticker == null) _startTicker(p);
    if (!p.isPlaying) _stopTicker();

    final totalMs = item?.lengthMs ?? p.itemLengthMs ?? 0;
    final displayMs = _displayMs ?? p.itemProgressMs ?? 0;
    final sliderValue = totalMs > 0
        ? (displayMs / totalMs).clamp(0.0, 1.0)
        : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('OwnTone Remote'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text(
              'WS: ${controller.wsState}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (controller.error != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(controller.error!),
              ),
            ),
          const SizedBox(height: 16),
          ArtworkBox(url: item?.artworkUrl),
          const SizedBox(height: 24),
          Center(
            child: Text(
              item?.title ?? (p.isStopped ? 'Stopped' : 'No current item'),
              style: Theme.of(context).textTheme.headlineSmall,
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
              style: Theme.of(context).textTheme.bodyLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _fmt(Duration(milliseconds: displayMs)),
            textAlign: TextAlign.start,
          ),
          Slider(
            value: sliderValue,
            onChanged: totalMs > 0
                ? (v) {
                    _displayMs = (v * totalMs).round();
                    setState(() {});
                    controller.seekMs(_displayMs!);
                  }
                : null,
          ),
          Text(_fmt(Duration(milliseconds: totalMs)), textAlign: TextAlign.end),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton.filledTonal(
                iconSize: 32,
                onPressed: p.isStopped ? null : controller.previous,
                icon: const Icon(Icons.skip_previous),
              ),
              const SizedBox(width: 24),
              // Playable from the stopped state too: after a stop the
              // current item is still queued and PUT /play restarts it.
              // Disabling the button here would leave the app unable to
              // start playback again.
              IconButton.filled(
                iconSize: 48,
                onPressed: p.isPlaying ? controller.pause : controller.play,
                icon: Icon(p.isPlaying ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 24),
              IconButton.filledTonal(
                iconSize: 32,
                onPressed: p.isStopped ? null : controller.next,
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
                  color: p.shuffle
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                onPressed: () => controller.setShuffle(!p.shuffle),
              ),
              IconButton.outlined(
                icon: Icon(
                  switch (p.repeat) {
                    Repeat.off => Icons.repeat,
                    Repeat.all => Icons.repeat,
                    Repeat.single => Icons.repeat_one,
                  },
                  color: p.repeat != Repeat.off
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                onPressed: controller.cycleRepeat,
              ),
              IconButton.outlined(
                icon: Icon(
                  p.consume ? Icons.hourglass_bottom : Icons.hourglass_empty,
                  color: p.consume
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                onPressed: () => controller.setConsume(!p.consume),
              ),
              IconButton.outlined(
                icon: const Icon(Icons.stop),
                onPressed: p.isStopped ? null : controller.stop,
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
                  onChanged: (v) {
                    final target = v.round();
                    setState(() {});
                    unawaited(controller.setVolume(target));
                  },
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
