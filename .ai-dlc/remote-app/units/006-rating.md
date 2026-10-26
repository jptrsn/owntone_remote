---
name: 006-rating
status: done
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

**DONE 2026-10-26** — all five criteria PASS, on the physical Pixel 6
(`25071FDF600953`), debug build via `flutter run`, server 192.168.1.13.
Server returned to handoff state: `state=stop`, queue version 1739 /
185 items byte-identical to `/tmp/ot006/queue_snapshot.json` (first item
'Skunk'); all touched track ratings verified back to their originals.

### Mapping (lossy by design, as documented in `lib/src/library/rating.dart`)

| server rating | stars shown | star n tap writes |
|---|---|---|
| 0 | 0 | star1 → 20 |
| 1–19 | 0 | star2 → 40 |
| 20–39 | 1 | star3 → 60 |
| 40–59 | 2 | star4 → 80 |
| 60–79 | 3 | star5 → 100 |
| 80–99 | 4 | re-tap set star → 0 |
| 100 | 5 | |

`starsForRating = (rating ?? 0).clamp(0, 100) ~/ 20` (floor);
`ratingForStars = stars.clamp(0, 5) * 20`. Boundaries 19/21/39/41 pinned
table-driven in `test/rating_mapping_test.dart`.

### Criterion 1 — row stars match server (PASS)

Album "Run the Jewels 2" rows read via the app's own semantics tree
(VM-side walk, absolute bounds) vs `GET /api/library/tracks/{id}`:
Jeopardy(1768) 80 → "4 stars", Blockbuster Night Pt. 1(1770) 100 →
"5 stars", Crown(1764) 20 → "1 stars", Love Again(1765) 20 → "1 stars".
Screenshot `build/mcp_screenshots/c1_album_tracks_rtj2_baseline.png`.

### Criterion 2 — now playing shows + sets rating (PASS, supervised)

Server paused (user-confirmed play→pause window, master volume 0). Now
playing displayed 'Skunk' + 'Rating: 3 of 5 stars' (server 60, track 1195).
Mutation evidence (track 1195 'Skunk'):
1. record: `GET /api/library/tracks/1195` → 60
2. set (app, star 5): `GET` → 100; row updated '5 of 5 stars'
3. restore (app, star 3): `GET` → 60
4. verify restore: `GET` → 60 ✓ (also re-verified at session end)

Screenshot `build/mcp_screenshots/c2_now_playing_rating_baseline.png`.

### Criterion 3 — full supervised mutation on a browse row (PASS, supervised)

Track 1764 'Crown' (Run the Jewels 2, track 4), stars tapped in the album
row (never the row body — row tap would start playback):
1. record: `GET /api/library/tracks/1764` → **20**; row "1 stars"
2. set (app, star 3 @ phys 818,1635): `GET` → **60**; row live-updated
   "Crown, track 4, 3:45, **3 stars**" (WS `database` refresh, no tap on row)
3. restore (app, star 1 @ phys 711,1635): `GET` → **20**
4. verify restore: `GET` → 20 ✓; row back to "1 stars"; re-verified at
   session end alongside 1195=60 and 1765=20.
Screenshot `build/mcp_screenshots/c3_album_crown_restored.png`.
Web-UI check documented as API-equivalence: OwnTone's web UI is an SPA
reading the same `GET /api/library/tracks/{id}` that returned 60/20 (user
waived a separate browser observation this session).

### Criterion 4 — external change refreshes a visible row (PASS)

Row 'Love Again' visible (1 stars, server 20). External
`PUT /api/library/tracks/1765?rating=80` → row updated to "4 stars" /
'Rating: 4 of 5 stars' with zero app interaction; restored via
`PUT ?rating=20` and verified 20 via API (HTTP 200 both times).

### Criterion 5 — gates (PASS)

```
flutter analyze                       → No issues found! (ran in 3.0s)
dart format --set-exit-if-changed .   → Formatted 71 files (0 changed)
flutter test --exclude-tags live      → 00:25 +321: All tests passed!
flutter build apk --debug             → ✓ Built app-debug.apk (33.8s)
```

### Incidents / hazards hit (all audio-safe; none left audio playing)

- **Shared-session self-resume**: during the C2 window the player advanced
  ~4 s of progress while believed paused (other session). Master volume 0
  → inaudible; re-verified `pause`. Thereafter every potentially
  audio-relevant tap re-checked `GET /api/player` immediately before.
- **Doze blackout**: screen timed out once mid-session; the per-uid
  firewall blocked app networking. Fixed with `svc power stayon true`
  (left set; device is this project's).
- **Back-over-pop**: two `KEYCODE_BACK` from root exited the app (Calendar
  came forward); recovered with `am force-stop` + `am start`. `dumpsys
  window | grep mCurrentFocus` checked after every nav batch thereafter.
- **Density miscalc**: taps are physical px = logical × **2.625** (420
  dpi), not ×3.0; a mis-scaled tap hit nothing (no audio risk, row body
  taps are avoided entirely for tracks).
- **uiautomator bridge died** after the app went to background mid-session
  and never recovered (hot restart / settings toggles / relaunch did not
  help). Workaround: read the semantics tree from the VM via
  `flutter-agent-lens_evaluate_expression` (Element walk over `Semantics`
  widgets → label + absolute bounds). Text evidence in this Result comes
  from that channel.
