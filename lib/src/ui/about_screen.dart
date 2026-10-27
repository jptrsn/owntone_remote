import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connection/connection_controller.dart';
import '../core/app_info.dart';

/// Read-only About screen (R-14, unit 008), reached from Settings:
/// app name + version (compile-time const — deliberately no
/// `package_info_plus`, see `core/app_info.dart`) and the server's
/// `version` + `buildoptions` from `GET /api/config`. Tapping the server
/// version row re-fetches the config; when the server is unreachable the
/// section shows an error state with Retry instead (never stale data
/// presented as current).
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  static const _unreachable = 'Could not reach the server.';

  Map<String, dynamic>? _config;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetch());
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    // `api` is null before the first successful connect; while offline it
    // stays alive but its calls throw — both land in the error state.
    final api = context.read<ConnectionController>().api;
    Map<String, dynamic>? config;
    try {
      config = await api?.getConfig();
    } catch (_) {
      config = null;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (config == null) {
        _error = _unreachable;
      } else {
        _config = config;
      }
    });
  }

  String _buildOptions() {
    final options = _config?['buildoptions'];
    if (options is! List || options.isEmpty) return 'none reported';
    return options.map((e) => e.toString()).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final serverVersion = _config?['version']?.toString();
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: Icon(
              Icons.music_note,
              size: 56,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 8),
          Center(child: Text(kAppName, style: theme.textTheme.titleLarge)),
          Center(
            child: Text(
              kAppVersion,
              key: const ValueKey('app-version'),
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: 24),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Column(
              key: const ValueKey('about-error'),
              children: [
                Icon(Icons.wifi_off, size: 40, color: theme.colorScheme.error),
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _fetch,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            )
          else
            Column(
              children: [
                ListTile(
                  key: const ValueKey('about-server-version'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Server version'),
                  subtitle: Text(
                    'OwnTone ${serverVersion ?? 'unknown'}',
                    key: const ValueKey('server-version-value'),
                  ),
                  trailing: const Icon(Icons.refresh),
                  onTap: _fetch,
                ),
                ListTile(
                  key: const ValueKey('about-build-options'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Build options'),
                  subtitle: Text(
                    _buildOptions(),
                    key: const ValueKey('build-options-value'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
