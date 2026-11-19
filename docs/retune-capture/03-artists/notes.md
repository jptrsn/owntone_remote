# 03 — Artists tab (LibraryViewActivity)

Alphabetical ListView; row = artist name only (list mode); right-side
accessory box [909,·][1014,·] on every row (clickable; presumed play
control — NOT tapped, would start audio; semantics deferred).

- Long-press on a row = same as tap (drills in; no context menu —
  verified on "Audioslave" row).
- Single tap → SongsViewActivity (see 04).
- Sort: alphabetical, no section headers visible in list mode.

## JSON mapping
- List: `GET /api/library/artists?query=&cc=artist` (paginated).
