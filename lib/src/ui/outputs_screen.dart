import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../outputs/output.dart';
import '../outputs/outputs_controller.dart';
import '../player/player_controller.dart';
import 'app_drawer.dart';
import 'connection_banner.dart';
import 'mini_player.dart';

/// R-09 outputs / speakers screen (unit 004, SCREENS.md "Outputs").
///
/// One checkbox per output; a tap toggles membership with exactly one
/// `PUT /api/outputs/set` carrying the full selected-id list. Enabling a
/// protected output goes through the PIN dialog first. Per-output volume
/// sliders commit one `PUT /api/player/volume?output_id=…` on release
/// (drag-state pattern, spike Finding 14).
class OutputsScreen extends StatefulWidget {
  const OutputsScreen({super.key});

  @override
  State<OutputsScreen> createState() => _OutputsScreenState();
}

class _OutputsScreenState extends State<OutputsScreen> {
  OutputsController? _snackController;
  int _seenActionErrorSeq = 0;

  /// Output whose volume slider is under a finger (null = not dragging);
  /// while set, the slider shows the finger's value and server updates
  /// (WS refetches) must not move it (spike Finding 14).
  String? _draggingId;
  double _dragValue = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_snackController != null) return;
    final c = context.read<OutputsController>();
    _snackController = c;
    _seenActionErrorSeq = c.actionErrorSeq;
    c.addListener(_onActionError);
  }

  /// A failed toggle / unlock / volume write rolls the UI back
  /// (OutputsController) and surfaces a snackbar with the typed error.
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
    super.dispose();
  }

  /// The enable-side guardrail (unit 004): while the server plays, enabling
  /// an output redirects/duplicates live audio onto it — confirm before
  /// proceeding. Paused/stopped: no dialog. Issue #20 moved the DESELECT
  /// paths out of here: multi-deselect is silent (see [_onCheckbox]) and
  /// the last-output deselect has its own confirm (see
  /// [_lastDeselectFlow]).
  Future<void> _withPlayingGuard(
    Future<void> Function() action,
    PlayerController player,
  ) async {
    // The decision must not rest on the cached slice (see refreshState):
    // refetch, and only fall back to the cache when the refetch is
    // impossible (disconnected / never loaded).
    final fresh = await player.refreshState();
    if (fresh?.isPlaying != true) {
      await action();
      return;
    }
    if (!mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Server is playing'),
        content: const Text(
          'Moving outputs redirects live audio to the selected outputs. '
          'Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    await action();
  }

  void _onCheckbox(
    Output o,
    OutputsController outputs,
    PlayerController player,
  ) {
    if (o.selected) {
      if (OutputsController.emptiesSelection(outputs.outputs, o.id)) {
        // The LAST selected output: its own confirm, then stop-if-playing
        // (issue #20).
        unawaited(_lastDeselectFlow(o, outputs, player));
      } else {
        // One of SEVERAL selected outputs (issue #20): silent, even while
        // playing — audio simply continues on the remaining outputs, so
        // there is nothing to warn about. Do not route this back through
        // [_withPlayingGuard]: the unconditional playing confirm on every
        // deselect was the defect (OwnTone's own web UI confirms nothing
        // here).
        unawaited(outputs.toggle(o.id));
      }
      return;
    }
    final needPin = o.hasPassword || o.needsAuthKey;
    unawaited(
      _withPlayingGuard(() async {
        if (needPin) {
          final pin = await _pinDialog(o);
          if (pin == null || pin.isEmpty) return;
          await outputs.enableWithPin(o.id, pin);
        } else {
          await outputs.toggle(o.id);
        }
      }, player),
    );
  }

  /// Issue #20: deselecting the only selected output silences the server,
  /// so it gets a confirm — in any player state (a "paused" cache is
  /// exactly what a stale slice looks like while the server plays). On
  /// confirm the output is deactivated and, when the server is freshly
  /// read as playing, playback is STOPPED server-side (`PUT
  /// /api/player/stop`, not pause): a playing server with zero outputs
  /// burns through the queue while emitting nothing audible, and a pause
  /// would keep advancing it.
  Future<void> _lastDeselectFlow(
    Output o,
    OutputsController outputs,
    PlayerController player,
  ) async {
    if (!mounted) return;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('No outputs left selected'),
        content: const Text(
          'This is the only selected output. Deselecting it leaves the '
          'server with no audio output. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    final ok = await outputs.toggle(o.id);
    // A failed toggle rolled the selection back — nothing emptied, no stop.
    if (!ok) return;
    // Fresh read, never the cached slice (unit 004 contract): a stale
    // cached 'pause' must not skip the stop while the server actually
    // plays (2026-10-23 C3 lesson).
    final fresh = await player.refreshState();
    if (fresh?.isPlaying == true) await player.stop();
  }

  Future<String?> _pinDialog(Output o) => showDialog<String>(
    context: context,
    builder: (context) => _PinDialog(name: o.name),
  );

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final outputs = context.watch<OutputsController>();
    final enabled = conn.phase == ConnectionPhase.connected;

    return Scaffold(
      // R-21 (issue #44): hamburger on the standalone Outputs Scaffold too
      // (drawerAwareLeading keeps the BackButton — AppBar would otherwise
      // replace it with the DrawerButton alone).
      appBar: AppBar(
        title: const Text('Outputs'),
        leading: drawerAwareLeading(context),
        leadingWidth: drawerAwareLeadingWidth(context),
      ),
      drawer: const AppDrawer(selected: DrawerDestination.outputs),
      body: Column(
        children: [
          if (!enabled)
            const ConnectionBanner(
              message: 'Server unreachable — retrying. Controls disabled.',
            ),
          if (outputs.syncError != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  outputs.syncError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          Expanded(child: _buildBody(enabled, outputs)),
        ],
      ),
      // R-22 (issue #45): mini transport bar here too (own Scaffold — see
      // browse_screen_scaffold.dart for the layering contract).
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  Widget _buildBody(bool enabled, OutputsController outputs) {
    final list = outputs.outputs;
    if (list.isEmpty && !outputs.hasLoaded) {
      return enabled
          ? const Center(child: CircularProgressIndicator())
          : const Center(child: Text('Waiting for the server…'));
    }
    if (list.isEmpty) {
      return const Center(child: Text('No outputs on this server.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => _OutputRow(
        output: list[i],
        enabled: enabled,
        draggingId: _draggingId,
        dragValue: _dragValue,
        onCheckbox: (o) =>
            _onCheckbox(o, outputs, context.read<PlayerController>()),
        onVolumeChange: (o, v) => setState(() {
          _draggingId = o.id;
          _dragValue = v;
        }),
        onVolumeRelease: (o, v) {
          setState(() {
            _draggingId = null;
          });
          unawaited(outputs.setOutputVolume(o.id, v.round()));
        },
      ),
    );
  }
}

class _OutputRow extends StatelessWidget {
  const _OutputRow({
    required this.output,
    required this.enabled,
    required this.draggingId,
    required this.dragValue,
    required this.onCheckbox,
    required this.onVolumeChange,
    required this.onVolumeRelease,
  });

  final Output output;
  final bool enabled;
  final String? draggingId;
  final double dragValue;
  final void Function(Output) onCheckbox;
  final void Function(Output, double) onVolumeChange;
  final void Function(Output, double) onVolumeRelease;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final protected = output.hasPassword || output.needsAuthKey;
    final volume =
        (draggingId == output.id ? dragValue : (output.volume ?? 0).toDouble())
            .clamp(0.0, 100.0);

    return Semantics(
      container: true,
      label:
          '${output.name}, ${output.type}, '
          '${output.selected ? 'selected' : 'not selected'}, '
          'volume ${output.volume ?? 0}',
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.fromLTRB(12, 4, 16, 8),
        child: Column(
          children: [
            Row(
              children: [
                Checkbox(
                  value: output.selected,
                  onChanged: enabled ? (_) => onCheckbox(output) : null,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        output.name,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Row(
                        children: [
                          Text(output.type, style: theme.textTheme.labelSmall),
                          if (protected)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Icon(
                                Icons.lock_outline,
                                size: 14,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 36,
                  child: Text(
                    '${(output.volume ?? 0).toInt()}',
                    textAlign: TextAlign.end,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              ],
            ),
            // R-09 (issue #19): an unselected output gets no audio, so its
            // volume control is meaningless — OwnTone's own web UI renders it
            // disabled-but-visible. `output.selected` comes from the slice,
            // which refetches on every `outputs`/`volume` WS event, so a
            // server-side selection change flips this in place without a
            // rebuild from scratch. Do not "simplify" back to `enabled`
            // alone: that re-enables sliders that cannot affect the server's
            // audible mix (the widget test pins it).
            Slider(
              min: 0,
              max: 100,
              value: volume,
              onChanged: enabled && output.selected
                  ? (v) => onVolumeChange(output, v)
                  : null,
              onChangeEnd: enabled && output.selected
                  ? (v) => onVolumeRelease(output, v)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _PinDialog extends StatefulWidget {
  const _PinDialog({required this.name});

  final String name;

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('PIN for ${widget.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            // Rebuild on change: the Unlock button's enabled state reads
            // the controller's text at build time.
            onChanged: (_) => setState(() {}),
            onSubmitted: (text) {
              if (text.isNotEmpty) {
                Navigator.of(context).pop(text);
              }
            },
            decoration: const InputDecoration(labelText: 'PIN'),
          ),
          const SizedBox(height: 8),
          Text(
            'A wrong PIN is rejected by the server and the output '
            'stays disabled.',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text),
          child: const Text('Unlock'),
        ),
      ],
    );
  }
}
