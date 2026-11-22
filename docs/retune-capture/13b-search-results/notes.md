# 13b — Search results (query "the")

Single ListView, **grouped with disabled section headers**, order:
**Albums → Artists → Songs** (verified by scrolling to end: Albums
headers, Artists header mid-list, Songs group two-line rows last).
**Playlists are NOT searched** (no playlist row/DAAP query observed).

Rows reuse the browse row templates (album rows; artist rows; song rows
title + "artist - album" two lines) + right accessory (presumed play).

## DAAP evidence (3 parallel queries, not /search)
- albums: `/databases/1/groups?group-type=albums&query=(daap.songalbum:*the* …)`
- artists: `/databases/1/groups?group-type=artists&query=(daap.songartist:*the* …)`
- songs:   `/databases/1/containers/1/items?query=(dmap.itemname:*the* …)`
(+ iTunes-only variants mediakind 8/6/4/7 for movies/podcasts — out)

## JSON mapping (new app status)
- `GET /api/search?query=…` returns groups incl. **playlists** — new app
  already superset; grouped + per-group paging exists (unit 007). Keep.
