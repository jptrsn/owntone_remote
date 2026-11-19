# 12 — Songs tab (LibraryViewActivity)

Flat all-songs ListView (whole library): row = **two lines** — title, then
"artist - album"; right accessory (presumed play). Duplicate titles appear
(different albums). Sort by name (DAAP `sort=name`).

## DAAP evidence
- `/databases/1/containers/1/items?meta=…&sort=name&include-sort-headers=1&query=(mediakinds)`
  (no per-item filter).

## JSON mapping — **gap candidate**
- `GET /api/library/tracks?query=&cc=…` paginated. The new app has **no
  all-songs view** (diff-list D-row).
