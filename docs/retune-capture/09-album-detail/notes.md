# 09 — Album detail (SongsViewActivity, title = album)

Reached by tap on album row (e.g. "Absolution"). Track list with disabled
section-header row (album name) above tracks.

## Elements
- Song row: title + right accessory (only clickable part; presumed play).
- Overflow (SongsView context, captured from artist-detail variant):
  **Play All / Shuffle / Play Next / Add to Up Next** / Settings /
  Disconnect / Help. (No "Sort By" here — that is playlist-only.)
- Mini now-playing bar persists.

## DAAP evidence
- `/databases/1/containers/1/items?query=(mediakinds + daap.songalbumid:X)`
  — tracks of album.

## JSON mapping
- `GET /api/library/albums` → album tracks (`GET /api/library/tracks?cc=album,id`).
- Play All → `POST /api/queue/items/add?uris=…&clear=true&playback=start`.
- Add to Up Next → same add without clear (`playback=add`/`paused`).
