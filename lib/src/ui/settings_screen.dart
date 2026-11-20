import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../core/server_config.dart';
import '../discovery/discovered_server.dart';
import '../discovery/discovery_source.dart';
import '../discovery/mdns_discovery.dart';
import '../settings/settings_store.dart';
import '../settings/theme_preference.dart';
import 'about_screen.dart';
import 'app_drawer.dart';
import 'mini_player.dart';

/// Ceiling on one scan before the panel shows its timeout state. The mDNS
/// client bounds itself per query (3 s browse + 3 s answers + 3 s A); this
/// is the belt-and-braces ceiling that guarantees the *panel* always
/// resolves — discovery must never block manual entry (R-20).
const Duration kScanTimeout = Duration(seconds: 12);

/// Side-panel scan state (R-20).
enum _ScanPhase { idle, scanning, done }

/// Settings (R-01, R-14, R-20, R-26): manual host + JSON-port entry persisted via
/// [SettingsStore], the volume-rocker step (1–10, applied to the next
/// press — the mirror handler reads the store at keypress time), the theme
/// picker (Light · Dark · System, applied on select), and the
/// entry to the read-only [AboutScreen].
///
/// R-20 (issue #42): a **Scan** affordance browses the LAN for the OwnTone
/// advertisement (`_http._tcp` + OwnTone TXT fingerprint — see
/// [MdnsOwnToneDiscovery]) and lists hits for one-tap selection. The scan is
/// a *side panel* with its own loading/timeout/error states: the manual
/// host/port form above it is never disabled by a scan, and a hit pre-fills
/// the fields and goes through the existing R-01 [_saveAndConnect] — there
/// is no discovery-specific connect path to drift from R-01.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.initial, this.discovery});

  /// Pre-fill — the saved config when one exists.
  final ServerConfig? initial;

  /// Injectable for widget tests (fake scan / forced scan failure);
  /// production uses [MdnsOwnToneDiscovery].
  final DiscoverySource? discovery;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  final _formKey = GlobalKey<FormState>();

  /// Rocker step shown in the UI (R-14). Seeded from the store; every tap
  /// persists immediately (the mirror handler reads the store at keypress
  /// time, so the *next* press already uses the new step).
  late int _step;

  // R-20 scan side panel — independent of the manual form above it.
  late final DiscoverySource _discovery;
  _ScanPhase _scanPhase = _ScanPhase.idle;
  List<DiscoveredServer> _hits = const [];
  String? _scanError;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _host = TextEditingController(text: initial?.host ?? '');
    _port = TextEditingController(
      text: initial == null ? '' : initial.port.toString(),
    );
    _step = context.read<SettingsStore>().rockerStep;
    _discovery = widget.discovery ?? MdnsOwnToneDiscovery();
  }

  void _bumpStep(int delta) {
    setState(
      () => _step = (_step + delta).clamp(
        SettingsStore.minRockerStep,
        SettingsStore.maxRockerStep,
      ),
    );
    unawaited(context.read<SettingsStore>().saveRockerStep(_step));
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  ServerConfig? _parsed() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty || port == null) return null;
    return ServerConfig(host: host, port: port);
  }

  /// Persists the config, then connects. Pops when pushed from the main
  /// screen; the RootScreen below switches to the connecting/connected view
  /// as the phase changes.
  Future<void> _saveAndConnect() async {
    final cfg = _parsed();
    if (cfg == null) {
      _formKey.currentState?.validate();
      return;
    }
    final store = context.read<SettingsStore>();
    final conn = context.read<ConnectionController>();
    final canPop = Navigator.of(context).canPop();
    unawaited(() async {
      await store.save(cfg);
      if (canPop && mounted) Navigator.of(context).pop();
      await conn.connectTo(cfg);
    }());
  }

  void _disconnect() {
    final conn = context.read<ConnectionController>();
    conn.disconnect();
    if (context.mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  /// Runs one R-20 scan into the side panel. Never touches the manual
  /// fields' state; every terminal branch (hits / empty / timeout / error)
  /// leaves the form fully usable — the whole point of the side-panel
  /// design.
  Future<void> _startScan() async {
    if (_scanPhase == _ScanPhase.scanning) return;
    setState(() {
      _scanPhase = _ScanPhase.scanning;
      _scanError = null;
      _hits = const [];
    });
    try {
      final hits = await _discovery.discover().timeout(kScanTimeout);
      if (!mounted) return;
      setState(() => _hits = hits);
    } on TimeoutException {
      if (!mounted) return;
      setState(
        () => _scanError =
            'Scan timed out — no OwnTone server answered. '
            'You can still enter the address manually.',
      );
    } on DiscoveryException catch (e) {
      if (!mounted) return;
      setState(() => _scanError = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _scanError = 'Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanPhase = _ScanPhase.done);
    }
  }

  /// One-tap hit (R-20): pre-fill the manual fields, then hand off to the
  /// *existing* R-01 connect flow — same validation, same persist, same
  /// error surface. No discovery-specific connect path.
  void _useHit(DiscoveredServer hit) {
    _host.text = hit.host;
    _port.text = hit.port.toString();
    _saveAndConnect();
  }

  Widget _scanPanel(BuildContext context) {
    if (_scanPhase == _ScanPhase.scanning) {
      return const Column(
        key: ValueKey('scan-panel'),
        children: [
          Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text('Searching the local network…'),
              ),
            ],
          ),
        ],
      );
    }
    final error = _scanError;
    if (error != null) {
      return Column(
        key: const ValueKey('scan-panel'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.wifi_off,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  error,
                  key: const ValueKey('scan-error'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('scan-retry'),
              onPressed: _startScan,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ),
        ],
      );
    }
    if (_hits.isEmpty) {
      return Column(
        key: const ValueKey('scan-panel'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'No OwnTone server found on this network. '
            'You can still enter the address manually.',
            key: ValueKey('scan-empty'),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('scan-retry'),
              onPressed: _startScan,
              icon: const Icon(Icons.refresh),
              label: const Text('Scan again'),
            ),
          ),
        ],
      );
    }
    return Column(
      key: const ValueKey('scan-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _hits.length; i++)
          ListTile(
            key: ValueKey('scan-hit-$i'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.speaker),
            title: Text(_hits[i].name),
            subtitle: Text('${_hits[i].host}:${_hits[i].port}'),
            onTap: () => _useHit(_hits[i]),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('scan-retry'),
            onPressed: _startScan,
            icon: const Icon(Icons.refresh),
            label: const Text('Scan again'),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      // R-21 (issue #44): hamburger on the standalone Settings Scaffold;
      // drawerAwareLeading keeps the BackButton on the pushed variant.
      appBar: AppBar(
        title: Text(canPop ? 'Server' : 'Connect'),
        leading: drawerAwareLeading(context),
        leadingWidth: drawerAwareLeadingWidth(context),
        actions: [
          if (canPop)
            IconButton(
              tooltip: 'Cancel',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      drawer: const AppDrawer(selected: DrawerDestination.settings),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.dns,
                    size: 48,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'OwnTone server',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'The websocket port is discovered automatically from the '
                    'server’s /api/config.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _host,
                    decoration: const InputDecoration(
                      labelText: 'Host',
                      hintText: 'e.g. 192.168.1.13',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.url,
                    autofillHints: const [AutofillHints.url],
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _port,
                    decoration: const InputDecoration(
                      labelText: 'JSON port',
                      hintText: 'e.g. 3689',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _saveAndConnect(),
                    validator: (v) {
                      final p = int.tryParse((v ?? '').trim());
                      if (p == null) return 'Enter a number';
                      if (p < ServerConfig.minPort ||
                          p > ServerConfig.maxPort) {
                        return '1–65535';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _saveAndConnect,
                    icon: const Icon(Icons.link),
                    label: const Text('Connect'),
                  ),
                  if (conn.isConnected) ...[
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _disconnect,
                      child: const Text('Disconnect'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  // R-20 scan side panel (issue #42): below the manual
                  // form, own loading/timeout/error states — the fields
                  // above are never disabled by a scan in any state.
                  OutlinedButton.icon(
                    key: const ValueKey('server-scan-button'),
                    onPressed: _scanPhase == _ScanPhase.scanning
                        ? null
                        : _startScan,
                    icon: const Icon(Icons.radar),
                    label: Text(
                      _scanPhase == _ScanPhase.scanning
                          ? 'Scanning…'
                          : 'Scan for servers',
                    ),
                  ),
                  if (_scanPhase != _ScanPhase.idle) ...[
                    const SizedBox(height: 8),
                    _scanPanel(context),
                  ],
                  const SizedBox(height: 24),
                  const Divider(),
                  // Volume-rocker step (R-14): persists on every tap — the
                  // mirror handler reads the store at keypress time, so the
                  // change applies to the next press with no restart.
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Volume rocker step',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            Text(
                              'Server volume change per press (1–10), '
                              'while the app is open.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('rocker-step-decrease'),
                        tooltip: 'Decrease rocker step',
                        onPressed: _step > SettingsStore.minRockerStep
                            ? () => _bumpStep(-1)
                            : null,
                        icon: const Icon(Icons.remove),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text(
                          '$_step',
                          key: const ValueKey('rocker-step-value'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        key: const ValueKey('rocker-step-increase'),
                        tooltip: 'Increase rocker step',
                        onPressed: _step < SettingsStore.maxRockerStep
                            ? () => _bumpStep(1)
                            : null,
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  const Divider(),
                  // Theme (R-26): three-way picker next to the rocker step.
                  // Applies on select — MaterialApp rebuilds off the
                  // ThemePreference (no restart); the choice persists so a
                  // kill/relaunch keeps it.
                  Text('Theme', style: Theme.of(context).textTheme.bodyLarge),
                  Text(
                    'Follow the system setting or force a scheme.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ThemeMode>(
                    key: const ValueKey('theme-mode-picker'),
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Light'),
                      ),
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                      ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('System'),
                      ),
                    ],
                    selected: {context.watch<ThemePreference>().mode},
                    onSelectionChanged: (selection) => unawaited(
                      context.read<ThemePreference>().setMode(selection.first),
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    key: const ValueKey('about-entry'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.info_outline),
                    title: const Text('About'),
                    subtitle: const Text('App and server versions'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const AboutScreen(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      // R-22 (issue #45): mini transport bar (own Scaffold — see
      // browse_screen_scaffold.dart for the layering contract). At first
      // launch (idle phase) there is no current item, so MiniPlayer
      // collapses to SizedBox.shrink and the screen renders unchanged.
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}
