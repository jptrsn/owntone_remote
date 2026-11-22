# 18 — Playlist detail (PlaylistSongsViewActivity)

Playlist tap → song list, **two-line rows** (title / "artist - album") +
right accessory (presumed play).

## Overflow (playlist context) — richer than other views
**Play All · Shuffle · Play Next · Add to Up Next · Sort By: <mode>** ·
Settings · Disconnect · Help.
- `Sort By: Physical` cycles client-side sort modes in place (tap applies
  immediately, label in overflow; re-tap cycles). Reverted to Physical
  after probing (client-side only — no server mutation).
- Shuffle = play-all-shuffled (separate action, not the shuffle mode).

## JSON mapping
- Songs: `GET /api/library/playlists/{id}/tracks` (or queue add by playlist uri).
- Play All → `POST /api/queue/items/add?uris=playlist:…&clear=true&playback=start`
- Shuffle → web-UI equivalent: smart-shuffle via `?random=true`/shuffle-first
  (verify during spec-authoring)
- Add to Up Next → add without clear.
