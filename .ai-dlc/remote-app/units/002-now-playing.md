---
name: 002-now-playing
status: pending
intent: remote-app
supervised_steps: [3, 5]
---

# Unit 002 — now playing screen + notification hardening

R-IDs: R-03, R-04, R-05, R-07. Builds on the spike's screen + handler.

## Goal

Finish the now-playing screen to SCREENS.md spec and harden the
persistent notification (metadata, artwork, controls, no duplicate on
reconnect). All state flows through `PlayerController` (single source).

## Steps / notes

- Screen: artwork (`?maxwidth=600`, placeholder on 404), title/artist/
  album (ellipsize + tap-to-fullscreen text? per SCREENS.md), progress
  bar (seek → `position_ms`), elapsed/total, play/pause, prev/next,
  shuffle, repeat cycle, consume, volume slider (→ `?volume=`).
- Progress while playing: local ticker + WS/`player` event refetch
  (no 1 Hz REST polling; verify drift stays <2 s over 10 min).
- `PlayerController`: optimistic update on control press → confirm on
  response/WS; on 5xx → rollback + snackbar (typed error).
- Notification: media style, artwork, play/pause/prev/next; update on
  every `PlayerState` emission; exactly one notification after WS
  reconnect (spike risk #4).
- Tests: PlayerState JSON mapping (fixtures from API.md), repeat-cycle
  order, optimistic-rollback, notification metadata mapping.
- Widget tests: all three states (playing/paused/empty-item) against
  fakes.

## Completion criteria

1. Screen renders all fields from live `/api/player` (paused item,
   real artwork); placeholder shown for a 404 artwork (force with a
   crafted fake, or a track whose artwork is missing).
2. Seek from the bar lands within ±1 s (verify `item_progress_ms` after).
3. `supervised: true` — play/pause/next/previous from **all three
   surfaces** (screen, notification, lockscreen) work; audio confirmed
   by user for the play path; paused-state next stays paused (spike
   question — record the answer).
4. Shuffle/repeat/consume toggles: correct state shown, correct `PUT`
   sent, WS `options` event updates UI without manual refresh.
5. `supervised: true` — notification: artwork + metadata + all controls
   work while app backgrounded; no duplicate notification after a WS
   reconnect (criterion 5 of unit 001, re-verified end-to-end).
6. Progress drift <2 s over 10 min while playing (supervised window;
   user starts/stops around it).
7. Gates pass; widget + unit tests cover criteria 1, 2, 4.

## Result

*(fill: evidence, gate output, drift measurement, incidents)*
