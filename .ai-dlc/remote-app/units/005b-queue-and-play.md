---
name: 005b-queue-and-play
status: done
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
  `PlayerState.item_id`. **VERIFIED LIVE 2026-10-23:** `item_id` matches
  the queue item's **`id`** (196174 = position 0, "Skunk", whose
  `track_id` is 1195), not `track_id` — the queue item `id` is a
  per-queue-entry counter, `track_id` is the library id. clear button
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

**DONE 2026-10-26** — all three criteria PASS. Device: physical **Pixel 6
`25071FDF600953`** (per user instruction; emulators off-limits this
session). Server `192.168.1.13` is **shared with another session** — it
advanced items/paused on its own twice during the unit; every playback
below was triggered by *this* app and paused again by it.

**Criterion 1 (supervised — user present, explicit per-action consent
2026-10-26, "Yes — full window"):** track-row tap (Thundersmack
"Brass" → "Skunk") → `POST …add?uris=library:track:1195&clear=true&playback=start`
→ `/api/player` `state: play`, pos 6210; `/api/queue` = 1 item
(196556 Skunk). **User confirmed audio** ("Yes, audible", Volumio Kitchen
selected @vol 65). Paused via the **app's centre control button** →
`state: pause` (pos 169872) verified via API. Now-playing highlight:
primary-container `ffeaddff` on the current row vs `f8f1fa` baseline
(render-tree container colours). Also exercised: `AlbumRow.onPlay` →
queue = album order (House Party, Blues in the Attic, Skunk — server
expanded `library:album`), playing; `ArtistRow.onPlay` → 11 Thundersmack
tracks (`library:artist` expansion), playing. Each play paused after
verification.

**Criterion 2 (unattended, server paused/stopped throughout):** queue
screen 185 rows in server order (1 Skunk 6:01 · 2 Blues in the Attic
1:46 · 3 House Party…); highlight follows `item_id` (196175). WS `queue`
refresh net-zero: curl add "Brass Monkey" → app 186 + row rendered
(`186|Brass Monkey|Beastie Boys · Solid Gold Hits|2:38`) → curl delete →
185. Clear via the **app button** (+ confirm dialog) → server count 0 +
"The queue is empty."; restored from `GET /api/queue` snapshot →
**185/185 uri+title match**. Artist-uri expansion also verified
unattended (add without `playback` → +11 tracks; deleted after).
Airplane-mode: `conn=offline`, `ws=reconnecting`, banner "Server
unreachable — retrying. Queue disabled." rendered → off → connected/open.

**Criterion 3:** `analyze` 0 · `format` 0 changed · `flutter test
--exclude-tags live` **273/273** (incl. 20 queue tests + 5 browse
play-action tests asserting the exact add URL) · `build apk --debug` ✓.
`getQueue`/`clearQueue`/`playUris` fully covered faked (`queue_api_test`).

**Follow-ups recorded (not 005b blockers):** (1) `playback=start` issued
while the server is *paused* can leave it paused (resume path uses the
remembered position) — reliable from `stop`; retest in a private-server
window. (2) `GET /artwork/item/<id>` → 204 (no artwork) throws
`HttpException: Invalid statusCode: 204` inside flutter_cache_manager
(caught, benign — artwork slot stays empty); worth filtering. (3) Pixel 6
background-networking firewall blocks the app uid when the screen is off
(no FGS until first playback) — keep the screen awake for on-device
sessions.

**Environment at handoff:** server `stop`, queue 185 byte-identical to
pre-unit snapshot. Clean (post-DIAG-removal) debug APK installed and
foregrounded on Pixel 6 — boot log shows `connecting → connected`,
`ws: none → open` in ~1s.
