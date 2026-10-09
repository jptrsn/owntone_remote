---
name: 006-rating
status: pending
intent: remote-app
supervised_steps: [3]
---

# Unit 006 — rating display + edit

R-IDs: R-12. Mutates real library data — the supervised-mutation protocol
(AGENTS.md §4) applies: **record original → set → verify → restore →
verify restore**.

## Goal

Rating stars (0–100 ↔ 0–5, mapping 0/20/40/60/80/100) on track rows and
now playing; tap to set (`PUT /api/library/tracks/{id}?rating=`); WS
`database` event refreshes visible rows.

## Steps / notes

- Mapping is lossy by design (server is 0–100, UI is 5 stars) — document
  the exact mapping in code comments + Result.
- Optimistic star update, rollback on error.
- Now-playing rating: `GET /api/queue?id=now_playing` → track_id →
  `GET /api/library/tracks/{id}` (rating lives on the track, not the
  queue item).
- Tests: mapping table (all 6 values + boundaries 19/21/39/41),
  optimistic-rollback, `database` event → refetch wiring.

## Completion criteria

1. Track rows show stars matching the server (spot-check 3 tracks vs
   `GET /api/library/tracks/{id}`).
2. Now-playing rating shown + settable.
3. `supervised: true` — full mutation cycle on one real track: record
   original rating → set new (app) → verify via API + server web UI →
   **restore original** → verify restore via API. (All four evidence
   lines in Result.)
4. WS `database` event updates a visible list row after a rating change
   made in the web UI (paused state, safe).
5. Gates pass; mapping tests table-driven.

## Result

*(fill: the four-line mutation evidence, mapping table, gate output,
incidents — a forgotten restore is an incident against the user's
curated library)*
