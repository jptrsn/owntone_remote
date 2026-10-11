import 'package:flutter/material.dart';

/// App-wide banner shown while the server is unreachable (unit 001
/// criterion 6: shown on offline, hidden on connect). Hidden whenever the
/// connection is up — even with the WS merely reconnecting.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 20, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
