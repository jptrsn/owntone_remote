---
name: 005-browse-and-play
status: pending
intent: remote-app
supervised_steps: [4]
---

# Unit 005 — library browse + queue + play

R-IDs: R-10, R-11. The biggest unit; **split it if it balloons**
(ai-dlc: >10 criteria / >3 components → new unit file). Suggested split
point: 005a browse screens, 005b queue + play actions.

## Goal

Browse per SCREENS.md (final depth from the pruned inventory): Playlists,
Artists, Albums, Genres (+ composers only if the spec kept it — search-
driven); artist→albums→tracks, album→tracks, playlist→tracks; pagination;
loading/empty/error/offline states; queue view + play + clear.

## Steps / notes

- API client surface (unit-tested against fakes): `playlists`,
  `playlistTracks`, `artists`, `artistAlbums`, `albums`, `albumTracks`,
  `genres`, genre→albums via `search?type=albums&expression=genre is
  "…"` (encoding: `Rock/Pop` → `Rock%2FPop`, `Drum & Bass` →
  `Drum%20%26%20Bass` — table-driven tests).
- Pagination: offset/limit, load-more without duplication, `total`
  respected; stable list keys.
- States per list: loading (skeleton), empty (icon + text), error (retry
  button), offline (banner + stale data or empty, per spec).
- Queue: `GET /api/queue`, now-playing row highlighted via
  `PlayerState.item_id`; tap row → play that item (**supervised**);
  clear button (`PUT /api/queue/clear` — safe); WS `queue` refresh.
- Play actions: "play" on a track = `POST /api/queue/items/add?uris=
  library:track:<id>&clear=true&playback=start` (**supervised**); play
  album/playlist = its `uri` with the same params.
- Widget tests: list + pagination + all four states against fakes;
  queue highlight logic.

## Completion criteria

1. Every in-scope browse screen renders live data with correct fields
   (evidence: screenshots or agent-lens trees for each screen).
2. Pagination: a list with >50 items loads page 2 on scroll without
   duplicates (real library has plenty).
3. All four states (loading/empty/error/offline) demonstrated per list
   (error via a live-test with a bad host or a fake; offline via unit
   001's banner path).
4. `supervised: true` — play one track from a list → audio (user-
   confirmed), `/api/queue` shows it at the right position, now-playing
   row highlights; then pause + verify (leave the server paused at the
   end).
5. Queue: list matches server; clear works; WS `queue` event refreshes
   after a web-UI queue change (paused-state change, safe).
6. Gates pass; API client fully covered by faked unit tests.

## Result

*(fill: per-screen evidence, pagination proof, supervised play transcript,
queue evidence, gate output, incidents — end with the server paused)*
