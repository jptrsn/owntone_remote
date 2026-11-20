---
title: "Playlist/album detail needs Play All / Shuffle / Play Next / Add to Up Next"
labels: enhancement, area:queue
---

## Change
Detail screens (playlist, album, artist-albums) offer only the per-row
replace-and-play accessory. ReTune's detail overflow carries four
context actions (`docs/retune-capture/09-album-detail/`,
`18b-overflow-playlist/`) — these are the remote-control actions users
actually reach for.

## Expected
App-bar overflow on `PlaylistTracksScreen`, `AlbumTracksScreen` (and
`ArtistAlbumsScreen`): **Play All · Shuffle · Play Next · Add to Up Next**.

Controller work (`QueueController`, today only `clear`/`playUris`/
`skipToQueueItem` — `queue_controller.dart:150-180`):
- `addUris(uris, {ahead})` — `POST /api/queue/items/add` **without**
  `clear`, `playback=add` (no playback change); `ahead: true` inserts at
  `position=0` for Play Next. **Verify the exact param names/positions
  live against `docs/API.md` § queue before implementing.**
- Shuffle-play: play the set shuffled **without** mutating the server
  global shuffle mode (web UI uses a shuffle flag on add — verify
  `?random`/`shuffle` param live; if none, client-side pre-shuffle).
All through the unit-011 single-flight + trailing-refresh pattern; every
action must keep WS `queue` events refreshing the UI.

## Where
`lib/src/queue/queue_controller.dart`; the three detail screens in
`lib/src/ui/browse_screens.dart`; `lib/src/api/` queue-add endpoint.

## Requirements
R-19. Diff-list D-06; evidence `docs/retune-capture/18b-overflow-playlist/`.

## Repro / verification
Widget/unit tests on the fake API: each action hits the expected
endpoint+params (captured request objects); no `clear` on Play Next /
Add; shuffle-play leaves global shuffle unchanged. **Live/supervised:**
manual pass on the dev device (user-present) confirming queue order and
that Shuffle does not flip the server shuffle flag. Gates green.
