import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../core/server_config.dart';
import '../settings/settings_store.dart';

/// Server configuration (R-01): manual host + JSON-port entry, persisted
/// via [SettingsStore]. Manual entry only in v1 (D8: no discovery).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.initial});

  /// Pre-fill — the saved config when one exists.
  final ServerConfig? initial;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _host = TextEditingController(text: initial?.host ?? '');
    _port = TextEditingController(
      text: initial == null ? '' : initial.port.toString(),
    );
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

  @override
  Widget build(BuildContext context) {
    final conn = context.watch<ConnectionController>();
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      appBar: AppBar(
        title: Text(canPop ? 'Server' : 'Connect'),
        actions: [
          if (canPop)
            IconButton(
              tooltip: 'Cancel',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
