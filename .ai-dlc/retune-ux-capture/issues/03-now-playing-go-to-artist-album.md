---
title: "Now Playing should offer Go to Artist / Go to Album"
labels: enhancement, area:ui, area:player
---

## Change
From Now Playing there is no navigation into the browse context of the
current track. ReTune's now-playing overflow has exactly these two
actions (`docs/retune-capture/15-now-playing/`).

## Expected
Now-playing overflow menu gains:
- **Go to Artist** → `ArtistAlbumsScreen` for the current track's artist
- **Go to Album** → `AlbumTracksScreen` for the current track's album

Both inert/hidden when no track is loaded (stopped/offline). Push via the
existing `Navigator`/`MaterialPageRoute` pattern used by browse screens.
Needs the artist/album ids on the now-playing track model (verify the
player WS payload / `GET /api/library/tracks/{id}` carries them —
`docs/API.md`).

## Where
`lib/src/ui/now_playing_screen.dart` (app bar / overflow);
`lib/src/ui/browse_screens.dart` (reuse `ArtistAlbumsScreen`,
`AlbumTracksScreen`); player model if ids need adding.

## Requirements
R-17. Diff-list D-04; evidence `docs/retune-capture/15-now-playing/`.

## Repro / verification
Widget test: with a loaded fake track, the overflow shows both entries;
tapping pushes the expected route type (find route by widget type);
with no track, entries are absent/disabled. Gates green.
