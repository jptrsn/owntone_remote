import 'package:flutter/material.dart';

/// Shared list states (unit 005a/005b): skeleton rows while the first
/// fetch is in flight, the empty message, and the full error state with
/// retry. The offline banner lives one level up (BrowseScreenScaffold).

/// Skeleton rows while a list is loading for the first time.
class ListSkeletonRows extends StatelessWidget {
  const ListSkeletonRows({super.key, this.rows = 8});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: rows,
      itemBuilder: (_, _) => const _SkeletonRow(),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow() : super(key: const ValueKey('skeleton-row'));

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}

/// Icon + one-liner for an empty server slice.
class ListEmptyState extends StatelessWidget {
  const ListEmptyState({super.key, required this.message, required this.icon});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          message,
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// The full error state (first fetch failed): icon + message + retry.
class ListErrorState extends StatelessWidget {
  const ListErrorState({
    super.key,
    required this.what,
    required this.message,
    required this.enabled,
    required this.onRetry,
  });

  final String what;
  final String message;
  final bool enabled;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 56, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          Text(
            'Could not load $what.',
            style: theme.textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: enabled ? onRetry : null,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
