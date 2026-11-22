# 04 — Artist detail (SongsViewActivity, title = artist)

Reached by tap/long-press on an artist row. Shows the artist's SONGS
(not albums) with disabled section-header rows (e.g. "Alternative").

## Elements
- App bar: title = artist name; Search; Speakers; More.
- Header row (disabled LinearLayout): genre label, e.g. "Alternative".
- Song row: title + right accessory (accessory is the only clickable
  part — presumed play; not exercised).

## DAAP evidence (logcat)
- `/databases/1/groups?group-type=albums&query=(daap.songartistid:X + mediakind + 'daap.songalbum!:')`
  — album grouping for artwork (53×53 `extra_data/artwork?group-type=artist`).
- `/databases/1/containers/1/items?query=(daap.songartistid:X + mediakinds)`
  — the flat song list.

## JSON mapping
- `GET /api/library/tracks?cc=artist,id` (tracks of artist, paginated).
- Artwork per artist: `/artwork/…` (new app already renders row artwork —
  ReTune list mode shows none; grid mode does, see 07).
