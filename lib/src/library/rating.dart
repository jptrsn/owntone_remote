// R-12 (unit 006): the 0–100 ↔ 0–5 star mapping.
//
// Lossy **by design**: OwnTone stores a track rating as 0–100, the UI is a
// 5-star control that only ever writes the canonical values
// 0 / 20 / 40 / 60 / 80 / 100 (tap star n → `rating = n * 20`; re-tapping
// the current star clears to 0 — the one way the UI reaches 0).
//
// Display quantizes with **floor**: a rating in [20n, 20n+19] renders as n
// stars (19 → 0, 20 → 1, 21 → 1, 39 → 1, 40 → 2, 99 → 4, 100 → 5 — the
// boundary table pinned by `rating_mapping_test`). Floor was chosen over
// round-to-nearest so the 20-point steps are also the *display* thresholds:
// what the web UI shows as "2 stars" (≥ 40) reads as 2 stars here too at
// the boundaries that matter, and an in-app edit is idempotent (set 3 →
// 60 → still displays 3). A value a legacy client put outside the grid
// (e.g. 50) renders conservatively (floor → 2, never rounding up).

/// Star count (0–5) for a server rating (0–100); null (unrated) is 0.
int starsForRating(int? rating) {
  final r = (rating ?? 0).clamp(0, 100);
  return r ~/ 20;
}

/// The canonical server value for a star count (0 → 0, 1 → 20, …, 5 → 100).
int ratingForStars(int stars) => stars.clamp(0, 5) * 20;
