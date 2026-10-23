---
name: 005b-queue-and-play
status: pending
intent: remote-app
supervised_steps: [1]
---

# Unit 005b — queue + play actions (split of 005)

R-IDs: R-11 + R-10's play actions. Split off `005-browse-and-play` on
2026-10-23 after `005a-browse-screens.md` was carved out; 005a goes
first. Builds on 005a's browse screens: track rows become playable and a
queue screen is added.

## Goal

Queue view (`GET /api/queue`) with the now-playing row highlighted, plus
clear; play actions from the browse screens (track / album / playlist /
artist) and from the queue — one
`POST /api/queue/items/add?uris=…&clear=true&playback=start`.

## Steps / notes

- API client surface (faked unit tests): `getQueue` (full `items[]`),
  `clearQueue`, `playUris(uris, {clear, playback})`.
- Queue screen: rows in server order; the now-playing row highlighted via
  `PlayerState.item_id` (verify live whether `item_id` matches the queue
  item's `id` or its `track_id` — API.md is ambiguous); clear button
  (`PUT /api/queue/clear` — safe while paused/stopped); WS `queue`
  refresh (R-02).
- Play actions (all **supervised**): track → its `uri`
  (`library:track:<id>`); album/playlist → their `uri`; artist →
  `library:artist:<id>` (verify the server expands it). One add call per
  action with `clear=true&playback=start`.
- Track-row tap in 005a's lists → play that track (supervised); queue-row
  tap → play that item (supervised).
- Entry point: decide the queue screen's IA here (app-bar icon vs.
  now-playing line — unit 004 constraint: a third app-bar icon overflows
  the 360-logical-px viewport).
- Widget tests: queue highlight logic, clear, WS `queue` refresh against
  fakes.

## Completion criteria

1. `supervised: true` — play one track from a list → audio (user-
   confirmed), `/api/queue` shows it at the right position, now-playing
   row highlights; then pause + verify (leave the server paused at the
   end).
2. Queue: list matches the server; clear works; WS `queue` event
   refreshes after a web-UI queue change (paused-state change, safe).
3. Gates pass; the queue/play API client is fully covered by faked unit
   tests.

## Result

*(fill)*
