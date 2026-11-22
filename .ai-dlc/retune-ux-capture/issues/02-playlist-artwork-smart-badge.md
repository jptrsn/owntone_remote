---
title: "Playlist rows should show artwork and a smart-playlist badge"
labels: enhancement, area:ui
---

## Change
`PlaylistRow` leads with a static `queue_music` icon. ReTune renders
playlist artwork (including distinct artwork for smart playlists, which
it badges) — `docs/retune-capture/01-library-root/`.

## Expected
- Leading widget = playlist artwork via the existing **`ArtworkProbe`**
  verdict (one GET per URL; 204/failed → the normal no-image branch —
  unit 010 pattern; `ArtworkBox` in `ArtworkBox`/`browse_rows`).
- Fallback stays the current icon.
- Smart playlists (`smart: true` in `GET /api/library/playlists`) get a
  small "smart" chip; semantics label includes it.

## Where
`lib/src/ui/browse_rows.dart` (`PlaylistRow`, ~line 108); model
`smart`/`artwork_url` fields in `lib/src/library/library_models.dart`
(add if absent — verify against live `GET /api/library/playlists` first);
reuse `ArtworkProbe`/`ArtworkBox` from unit 010.

## Requirements
R-16. Diff-list D-05; evidence `docs/retune-capture/01-library-root/`.

## Repro / verification
Widget tests with fakes: artwork shown when probe verdict = ok; icon
shown on 204/no-artwork (assert **no** Invalid statusCode log); smart
chip present iff `smart == true`; semantics label asserts badge. Gates green.
