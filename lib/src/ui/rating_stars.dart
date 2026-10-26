import 'package:flutter/material.dart';

import '../library/rating.dart';

/// The 5-star rating control (R-12, unit 006) — track rows and now playing.
///
/// Displays [rating] (0–100) floor-quantized to 0–5 stars
/// (`starsForRating`); tapping star *n* writes the canonical
/// `ratingForStars(n)`, and re-tapping the currently-set star clears to 0
/// (the only UI path to 0 — it exists so all six server values are
/// reachable).
///
/// Optimistic: the new value shows immediately; when [onRate] returns an
/// error message the display rolls back to [rating] and the message goes to
/// a snackbar (the same typed-error surface the transport controls use).
/// The confirmed value arrives via the server's `database` event (list
/// reload) or the controller's confirming GET (now playing) — a changed
/// [rating] prop clears the optimistic copy.
class RatingStars extends StatefulWidget {
  const RatingStars({
    super.key,
    required this.rating,
    required this.enabled,
    required this.onRate,
    this.iconSize = 16,
  });

  /// Server value, 0–100 (null = unrated → 0 stars).
  final int? rating;

  /// False while offline — the stars render but are inert.
  final bool enabled;

  /// Commits a rating (0–100); null on success, the snackbar text on
  /// failure.
  final Future<String?> Function(int newRating) onRate;

  /// Star glyph size (rows use the default; now playing passes a larger
  /// one — the only layout difference; the control is one component so the
  /// interaction cannot drift between the two surfaces).
  final double iconSize;

  @override
  State<RatingStars> createState() => _RatingStarsState();
}

class _RatingStarsState extends State<RatingStars> {
  /// The rating shown while a PUT is in flight (null = show the server
  /// value). Cleared when a new [RatingStars.rating] arrives — the server
  /// truth has landed.
  int? _optimistic;

  @override
  void didUpdateWidget(RatingStars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rating != widget.rating) _optimistic = null;
  }

  int get _shownRating => _optimistic ?? widget.rating ?? 0;

  Future<void> _tap(int stars) async {
    final target = starsForRating(_shownRating) == stars
        ? 0
        : ratingForStars(stars);
    setState(() => _optimistic = target);
    final error = await widget.onRate(target);
    if (!mounted) return;
    if (error != null) {
      setState(() => _optimistic = null);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = starsForRating(_shownRating);
    return Semantics(
      container: true,
      label: 'Rating: $shown of 5 stars',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var s = 1; s <= 5; s++)
            InkWell(
              key: ValueKey('rate-$s'),
              onTap: widget.enabled ? () => _tap(s) : null,
              child: Padding(
                // Touch padding inside the row's own 8px vertical padding —
                // ~20×28 logical px per star keeps the compact row layout
                // while staying tappable on-device.
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                child: Icon(
                  s <= shown ? Icons.star : Icons.star_border,
                  size: widget.iconSize,
                  color: s <= shown
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
