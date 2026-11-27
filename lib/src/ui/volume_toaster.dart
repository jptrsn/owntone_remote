import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../player/player_controller.dart';

/// Auto-hide window. Inside the machine-verified ReTune Toast band of
/// ~1–2.5 s (`docs/retune-capture/22-volume-toaster/notes.md`, plan A-3);
/// fixed on purpose — the issue's Non-goals forbid a settings toggle.
const _kToasterAutoHide = Duration(milliseconds: 1500);

/// Route-depth gate for the volume toaster (issue #92 AC-2/AC-5).
///
/// The bar must stay hidden on the Now Playing **root route** (its 0–100
/// slider is the indicator) and show on every *pushed* route. The layer
/// mounts above the `Navigator` (MaterialApp's `builder` — the only layer
/// that also covers opaque pushed routes), so `ModalRoute.of` is null
/// there and route awareness must come from an observer instead.
///
/// `depth` counts live routes: `didPush` +1, `didPop`/`didRemove` −1,
/// `didReplace` unchanged. Under the documented nav invariant
/// (root_screen.dart: every listen screen is *pushed on top of* the NP
/// root, drawer destinations collapse to `[root, target]`) `depth <= 1`
/// means the NP root is what is on screen — suppressed; `depth >= 2`
/// means a pushed route is on top — eligible. T10
/// (`test/volume_toaster_test.dart`) pins the invariant from the UI side,
/// including `popUntil` (`showDrawerDestination` / `showNowPlaying`):
/// RouteObserver must deliver `didPop` for every popUntil pop (plan A-2).
///
/// The drawer open over NP is NOT a route — depth stays 1, suppressed
/// (NP is what is on screen, plan A-7).
class VolumeToasterRouteObserver extends RouteObserver<ModalRoute<void>> {
  int _depth = 0;

  /// Live route count (1 = the root route alone).
  int get depth => _depth;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _depth++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_depth > 0) _depth--;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_depth > 0) _depth--;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {}
}

/// Transient volume level bar ("toaster", issue #92, ReTune capture-22
/// parity): floats in the center band (device y≈900–1500 — the capture's
/// band, `Align.center` on a portrait phone) for [ _kToasterAutoHide]
/// after a rocker-driven server-volume step, then auto-hides.
///
/// Mounted from `OwntoneRemoteApp`'s `MaterialApp.builder` (main.dart) so
/// it renders above opaque pushed routes — ReTune's Toast sits above
/// everything the same way. It is this app's own widget layer: no
/// toast/overlay package, no ReTune assets (issue Non-goals).
///
/// Parity details, all load-bearing:
///  * `ExcludeSemantics` — ReTune's Toast exposes **no a11y node**
///    (capture-22; issue AC-6). This is parity, not an a11y gap to fix.
///  * `IgnorePointer` — a non-blocking layer: it must never consume taps
///    meant for list rows behind it (AC-5).
///  * Exactly one bar, updated in place: a step while visible resets the
///    timer and swaps the level (AC-3) — never a stack.
///
/// The trigger is `PlayerController.volumeStepSeq` — bumped by `stepVolume`
/// only when a request was actually issued (R-06/D20, AC-4), so offline /
/// declined presses never schedule the timer. A volume *diff* would
/// false-trigger on WS `volume` events and the NP slider.
///
/// With no `PlayerController` provider registered (theme/harness pumps) it
/// renders just [child] — the mini_player.dart nullable-`Provider.of`
/// idiom, which keeps the `OwntoneRemoteApp` harnesses working.
class VolumeToasterLayer extends StatefulWidget {
  const VolumeToasterLayer({
    super.key,
    required this.observer,
    required this.child,
  });

  final Widget child;
  final VolumeToasterRouteObserver observer;

  @override
  State<VolumeToasterLayer> createState() => _VolumeToasterLayerState();
}

class _VolumeToasterLayerState extends State<VolumeToasterLayer> {
  PlayerController? _controller;
  Timer? _hideTimer;

  /// Last `volumeStepSeq` already reacted to. Consumed even when
  /// suppressed: a press on the NP root must not leak a stale bar onto a
  /// route pushed afterwards (a WS refetch would re-notify and re-show
  /// the unconsumed signal).
  int _seenSeq = 0;
  int? _level;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // listen: false + a manual listener: reacting inside build() would
    // mean setState during build. The notify happens from async
    // controller paths (never synchronously inside a build), so the
    // listener-side setState is safe.
    final controller = Provider.of<PlayerController?>(context, listen: false);
    if (!identical(controller, _controller)) {
      _controller?.removeListener(_onPlayerChanged);
      _controller = controller;
      _seenSeq = controller?.volumeStepSeq ?? 0;
      _level = null;
      controller?.addListener(_onPlayerChanged);
    }
  }

  void _onPlayerChanged() {
    final controller = _controller;
    if (controller == null) return;
    final seq = controller.volumeStepSeq;
    if (seq == _seenSeq) return;
    final level = controller.volumeStepLevel;
    _seenSeq = seq; // consume even when suppressed (see _seenSeq)
    if (level == null) return; // connected-but-no-first-slice (plan A-4)
    if (widget.observer.depth < 2) return; // NP root — the slider is it
    setState(() => _level = level);
    _hideTimer?.cancel();
    _hideTimer = Timer(_kToasterAutoHide, () {
      if (mounted) setState(() => _level = null);
    });
  }

  @override
  void dispose() {
    // Cancel + unregister: flutter_test fails a test on a pending timer
    // (the unit-3 discovery_scan_test invariant this line protects).
    _hideTimer?.cancel();
    _controller?.removeListener(_onPlayerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final level = _level;
    final theme = Theme.of(context);
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        if (level != null)
          Align(
            alignment: Alignment.center,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: Material(
                  key: const ValueKey('volume-toaster'),
                  color: theme.colorScheme.surfaceContainerHigh,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(28),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.volume_up,
                          size: 20,
                          color: theme.colorScheme.onSurface,
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 140,
                          child: LinearProgressIndicator(
                            value: level / 100,
                            key: const ValueKey('volume-toaster-progress'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 32,
                          child: Text(
                            '$level',
                            key: const ValueKey('volume-toaster-level'),
                            textAlign: TextAlign.end,
                            style: theme.textTheme.labelLarge,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
