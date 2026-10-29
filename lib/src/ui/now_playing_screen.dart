import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../core/artwork_probe.dart';
import '../outputs/outputs_controller.dart';
import '../outputs/output.dart';
import '../player/player_controller.dart';
import '../player/player_state.dart';
import '../queue/queue_controller.dart';
import '../rating/rating_controller.dart';
import '../settings/settings_store.dart';
import 'browse_screens.dart';
import 'connection_banner.dart';
import 'outputs_screen.dart';
import 'queue_screen.dart';
import 'rating_stars.dart';
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

  PlayerController? _snackController;
  int _seenActionErrorSeq = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_snackController != null) return;
    final c = context.read<PlayerController>();
    _snackController = c;
    _seenActionErrorSeq = c.actionErrorSeq;
    c.addListener(_onActionError);
  }

  /// A failed control press rolls the UI back (PlayerController) and
  /// surfaces a snackbar with the typed error (unit 002, SCREENS.md).
  void _onActionError() {
    final c = _snackController;
    if (c == null) return;
    if (c.actionErrorSeq != _seenActionErrorSeq) {
      _seenActionErrorSeq = c.actionErrorSeq;
      final message = c.actionError;
      if (message != null && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      }
    }
  }

  @override
  void dispose() {
    _snackController?.removeListener(_onActionError);
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
    final queue = context.watch<QueueController>();
    final rating = context.watch<RatingController>();
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
                    outputs: outputs.outputs,
                    queueCount: queue.queue.length,
                    nowPlayingRating:
                        rating.nowPlayingTrackId ==
                            controller.nowPlaying?.trackId
                        ? rating.nowPlayingRating
                        : null,
                    onRate: (newRating) async {
                      final trackId = controller.nowPlaying?.trackId;
                      if (trackId == null) {
                        return 'Rating failed — no current track.';
                      }
                      final ok = await rating.setRating(trackId, newRating);
                      return ok
                          ? null
                          : (rating.actionError ?? 'Rating failed.');
                    },
                    enabled: enabled,
                    displayMs: _displayMs,
                  ),
          ),
        ],
      ),
    );
  }
}

/// The compact style shared by the body's entry buttons (unit 004/005a/
/// 005b).
ButtonStyle _entryButtonStyle(ThemeData theme) => TextButton.styleFrom(
  textStyle: theme.textTheme.labelSmall,
  iconSize: 16,
  visualDensity: VisualDensity.compact,
  minimumSize: const Size(0, 32),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// The now-playing content (no Scaffold of its own — the
/// [NowPlayingScreen] shell owns the app bar and the offline banner).
///
/// Stateful only for the drag-state sliders (spike Finding 14,
/// SCREENS.md "Interaction design"): while a finger is down the slider
/// shows the finger's position and ignores server updates; one REST call
/// is committed on release.
class NowPlayingBody extends StatefulWidget {
  const NowPlayingBody({
    super.key,
    required this.controller,
    required this.outputs,
    required this.queueCount,
    required this.enabled,
    required this.displayMs,
    this.nowPlayingRating,
    this.onRate,
  });

  final PlayerController controller;

  /// All server outputs; the "Playing via" line shows the selected ones and
  /// is the entry point to the Outputs screen (unit 004).
  final List<Output> outputs;

  /// Live queue length for the "Queue · N" entry (unit 005b).
  final int queueCount;
  final bool enabled;
  final int? displayMs;

  /// Server rating (0–100) of the current item, or null while the rating
  /// slice hasn't caught up with the player's item (the stars then read
  /// 0 — still tappable, R-12).
  final int? nowPlayingRating;

  /// Commits a rating for the current track (`RatingStars` contract).
  final Future<String?> Function(int newRating)? onRate;

  /// The progress the screen displays, from most to least authoritative:
  /// the finger's dragged position, then the ticker's local extrapolation
  /// (playing only — the ticker freezes on pause, so after an item change
  /// in a paused state it still holds the *previous* item's position and
  /// must not be shown), then the server's live progress.
  static int displayedProgressMs({
    int? dragMs,
    required bool isPlaying,
    int? tickerMs,
    int? serverMs,
  }) => dragMs ?? (isPlaying ? tickerMs : null) ?? serverMs ?? 0;

  @override
  State<NowPlayingBody> createState() => _NowPlayingBodyState();
}

class _NowPlayingBodyState extends State<NowPlayingBody> {
  /// Dragged position while the seek slider is touched (null = not
  /// dragging; the server-extrapolated position applies).
  int? _seekDragMs;

  /// Dragged volume 0–100 while the volume slider is touched.
  double? _volumeDrag;

  static String _fmt(Duration d) => DateFormat('mm:ss').format(
    DateTime.fromMillisecondsSinceEpoch(d.inSeconds.clamp(0, 86399) * 1000),
  );

  @override
  Widget build(BuildContext context) {
    final p = widget.controller.player!;
    final item = widget.controller.nowPlaying;
    final theme = Theme.of(context);
    final enabled = widget.enabled;
    final outputs = widget.outputs;
    final selectedNames = outputs
        .where((o) => o.selected)
        .map((o) => o.name)
        .join(', ');

    final totalMs = item?.lengthMs ?? p.itemLengthMs ?? 0;
    final currentMs = NowPlayingBody.displayedProgressMs(
      dragMs: _seekDragMs,
      isPlaying: p.isPlaying,
      tickerMs: widget.displayMs,
      serverMs: p.itemProgressMs,
    );
    final sliderValue = totalMs > 0
        ? (currentMs / totalMs).clamp(0.0, 1.0)
        : 0.0;

    // While dragging, the local value wins over the server's.
    final volume = (_volumeDrag ?? p.volume.toDouble()).clamp(0.0, 100.0);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.controller.syncError != null)
            Material(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  widget.controller.syncError!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          // Entry rows (unit 004 / 005a / 005b): "Playing via" is the
          // remote's "current speaker" indicator (ReTune IA, D6) and opens
          // the Outputs screen; "Queue · N" opens the queue (R-11);
          // "Library" opens the browse section. All live here — not in the
          // app bar — because a second app-bar icon overflows the
          // 360-logical-pixel viewport by 9px (unit 004 finding). The row is
          // always present so the entries exist even with no outputs.
          Row(
            children: [
              if (outputs.isNotEmpty)
                Expanded(
                  child: TextButton.icon(
                    onPressed: enabled
                        ? () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const OutputsScreen(),
                            ),
                          )
                        : null,
                    icon: const Icon(Icons.cast, size: 16),
                    label: Text(
                      'Playing via: ${selectedNames.isEmpty ? 'none' : selectedNames}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: _entryButtonStyle(theme),
                  ),
                ),
              TextButton.icon(
                onPressed: enabled
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const QueueScreen(),
                        ),
                      )
                    : null,
                icon: const Icon(Icons.queue_music, size: 16),
                label: Text('Queue · ${widget.queueCount}'),
                style: _entryButtonStyle(theme),
              ),
              TextButton.icon(
                onPressed: enabled
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const LibraryHomeScreen(),
                        ),
                      )
                    : null,
                icon: const Icon(Icons.library_music, size: 16),
                label: const Text('Library'),
                style: _entryButtonStyle(theme),
              ),
            ],
          ),
          const SizedBox(height: 12),
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
          // R-12 (unit 006): the now-playing rating — tappable stars for the
          // *track* of the current queue item (the queue item itself carries
          // no rating; RatingController resolves track_id → track). Inline
          // with the artist line, not a row of its own: the unit-001
          // viewport-fit contract (artwork shrinks, nothing scrolls) has
          // ~16px of fixed-height slack on a short surface, and a separate
          // stars row overflowed the Column by 28px. Hidden with no item
          // (stopped).
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
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
                  if (item?.trackId != null && widget.onRate != null) ...[
                    const SizedBox(width: 8),
                    RatingStars(
                      key: const ValueKey('now-playing-rating'),
                      rating: widget.nowPlayingRating,
                      enabled: enabled,
                      onRate: widget.onRate!,
                      iconSize: 22,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            _fmt(Duration(milliseconds: currentMs)),
            textAlign: TextAlign.start,
          ),
          // Drag-state seek (spike Finding 14): the slider follows the
          // finger; the one `seek?position_ms=` call goes out on release,
          // and server refetches arriving mid-drag do not move it.
          Slider(
            value: sliderValue,
            onChanged: enabled && totalMs > 0
                ? (v) => setState(() => _seekDragMs = (v * totalMs).round())
                : null,
            onChangeEnd: enabled && totalMs > 0
                ? (v) {
                    final ms = (v * totalMs).round();
                    setState(() => _seekDragMs = null);
                    unawaited(widget.controller.seekMs(ms));
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
                onPressed: enabled && !p.isStopped
                    ? widget.controller.previous
                    : null,
                icon: const Icon(Icons.skip_previous),
              ),
              const SizedBox(width: 24),
              // Playable from the stopped state too: after a stop the current
              // item is still queued and PUT /play restarts it. Disabling the
              // button here would leave the app unable to start playback again.
              IconButton.filled(
                iconSize: 48,
                onPressed: enabled
                    ? (p.isPlaying
                          ? widget.controller.pause
                          : widget.controller.play)
                    : null,
                icon: Icon(p.isPlaying ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 24),
              IconButton.filledTonal(
                iconSize: 32,
                onPressed: enabled && !p.isStopped
                    ? widget.controller.next
                    : null,
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
                    ? () => widget.controller.setShuffle(!p.shuffle)
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
                onPressed: enabled ? widget.controller.cycleRepeat : null,
              ),
              IconButton.outlined(
                icon: Icon(
                  p.consume ? Icons.hourglass_bottom : Icons.hourglass_empty,
                  color: p.consume ? theme.colorScheme.primary : null,
                ),
                onPressed: enabled
                    ? () => widget.controller.setConsume(!p.consume)
                    : null,
              ),
              IconButton.outlined(
                icon: const Icon(Icons.stop),
                onPressed: enabled && !p.isStopped
                    ? widget.controller.stop
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Drag-state volume (spike Finding 14): while the finger is down
          // the slider + label follow the finger and a remote update
          // (rocker, web UI) cannot yank it; one `volume?volume=` call goes
          // out on release — a failed send rolls the value back.
          Row(
            children: [
              const Icon(Icons.volume_down),
              Expanded(
                child: Slider(
                  min: 0,
                  max: 100,
                  value: volume,
                  onChanged: enabled
                      ? (v) => setState(() => _volumeDrag = v)
                      : null,
                  onChangeEnd: enabled
                      ? (v) {
                          final vol = v.round();
                          setState(() => _volumeDrag = null);
                          unawaited(widget.controller.setVolume(vol));
                        }
                      : null,
                ),
              ),
              SizedBox(width: 40, child: Text('${volume.round()}')),
              const Icon(Icons.volume_up),
            ],
          ),
        ],
      ),
    );
  }
}

class ArtworkBox extends StatefulWidget {
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
  State<ArtworkBox> createState() => _ArtworkBoxState();
}

class _ArtworkBoxState extends State<ArtworkBox> {
  /// The [ArtworkProbe] verdict for the current URL: `null` while probing
  /// (render exactly like today — mount the Image), `false` when the probe
  /// saw anything but 204 (the Image stays; `errorBuilder` remains the
  /// last line of defence for 404/500/garbage, unit 010 keeps that path
  /// untouched), `true` when the server answered 204 — then the Image is
  /// unmounted entirely and the placeholder comes from the same no-image
  /// branch as a null URL (the unit's short-circuit-before-the-exception
  /// contract; do not "simplify" this back into errorBuilder-only handling
  /// — the 204 would reappear as a mounted failing load). Rendering the
  /// placeholder during the unknown window instead was tried and reverted:
  /// it delays the Image mount one frame past the fixed pump budgets the
  /// existing now_playing_screen artwork tests pin (test is immutable).
  bool? _noArtwork;

  /// Absorbing listeners on the unknown-window image loads (keyed by the
  /// exact [NetworkImage] `Image.network` will use, so the [ImageCache]
  /// hands out the SAME completer and the fetch stays a single GET). If a
  /// URL swap unmounts the unknown-window Image before its response
  /// lands, the completer rejects with zero listeners and Flutter's
  /// `reportError` would escalate the late `NetworkImageLoadException`
  /// (e.g. a 204) to `FlutterError.onError` — an uncaught framework
  /// error. A registered `onError` listener makes the completer treat the
  /// error as handled; we detach as soon as the load settles. Do not
  /// remove: it is what makes discarding a stale probe verdict (V1 guard
  /// in [_probe]) safe for the replaced URL's in-flight fetch.
  final Map<NetworkImage, ({ImageStream stream, ImageStreamListener listener})>
  _absorbers = {};

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void didUpdateWidget(ArtworkBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      setState(() => _noArtwork = null);
      _probe();
    }
  }

  @override
  void dispose() {
    for (final entry in _absorbers.values) {
      entry.stream.removeListener(entry.listener);
    }
    _absorbers.clear();
    super.dispose();
  }

  void _absorbLateFailure(Uri artworkUrl) {
    final provider = NetworkImage(artworkUrl.toString());
    if (_absorbers.containsKey(provider)) return;
    var resolved = false, settled = false;
    void onSettled() {
      settled = true;
      if (resolved) _dropAbsorber(provider);
    }

    final listener = ImageStreamListener((image, _) {
      image.dispose(); // our clone; Image.network holds its own
      onSettled();
    }, onError: (_, _) => onSettled());
    final stream = provider.resolve(ImageConfiguration.empty);
    stream.addListener(listener); // may dispatch a cached error synchronously
    resolved = true;
    _absorbers[provider] = (stream: stream, listener: listener);
    if (settled) _dropAbsorber(provider); // cache-hit error, dispatched sync
  }

  void _dropAbsorber(NetworkImage provider) {
    final entry = _absorbers.remove(provider);
    entry?.stream.removeListener(entry.listener);
  }

  Future<void> _probe() async {
    // V1 (unit-010 adversary): the awaited verdict is scoped to the URL it
    // probed — the now-playing item can be swapped mid-probe (same State,
    // didUpdateWidget path), and a stale continuation must then be
    // DISCARDED, not applied: a late 204 for the replaced URL must not
    // hide the new URL's rendered image (c1b), and a late `false` must not
    // re-mount the current URL's Image onto the failure branch of an
    // already-probed 204 (Goal 1 / c1a oracle). Same discipline as
    // mirror_handler's `_sameNowPlaying` stale-publish guard — do not drop
    // the `url` comparison back down to a bare `mounted` check.
    final url = widget.url;
    final artworkUrl = ArtworkBox.withMaxWidth(url);
    if (artworkUrl == null) return;
    // Mounting the Image this frame (unknown window) is the unit-010
    // adjudicated shape; absorb its response in case a URL swap orphans it.
    _absorbLateFailure(artworkUrl);
    final noArtwork = await ArtworkProbe.isNoArtwork(artworkUrl);
    if (!mounted || widget.url != url) return;
    setState(() => _noArtwork = noArtwork);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artworkUrl = ArtworkBox.withMaxWidth(widget.url);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 1,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
            if (artworkUrl != null && _noArtwork != true)
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
