---
workflow: default
git:
  change_strategy: unit
  auto_merge: false
  auto_squash: false
announcements: []
passes: []
active_pass: ""
iterates_on: ""
created: 2026-10-08
status: planned
epic: ""
quality_gates:
  - { name: analyze, command: "flutter analyze" }
  - { name: format, command: "dart format --output=none --set-exit-if-changed ." }
  - { name: test, command: "flutter test --exclude-tags live" }
  - { name: build_debug, command: "flutter build apk --debug" }
---

# Intent: remote-app (Phase 4 — the build)

## Problem

Build the v1 app (PLAN §3) from the final spec, unit by unit, each
independently testable on the dev AVD, with the OwnTone backend fully
abstracted behind `MusicProvider` (D10).

## Solution

Build on the spike codebase (it becomes the skeleton — keep what it
proved: provider/client/handler/call-channel; delete the
hardcoding/ugliness). Units in dependency order:

| # | Unit | R-IDs |
|---|---|---|
| 001 | connection-settings | R-01, R-02 |
| 002 | now-playing (screen + notification hardening) | R-03, R-04, R-05, R-07 |
| 003 | volume-rocker + call-handling | R-06, R-08 |
| 004 | outputs / speakers | R-09 |
| 005a | browse screens (split of 005) | R-10 |
| 005b | queue + play actions (split of 005) | R-10, R-11 |
| 006 | rating | R-12 |
| — | search (R-13) — unit 007 if spec keeps it P1; else P2 backlog | R-13 |

## Domain Model

Entities: `ServerConfig` (host, port, wsPort, persisted),
`PlayerState` (state/repeat/consume/shuffle/volume/item/length/progress/
artwork), `Track` (incl. `rating` 0–100), `Album`, `Artist`, `Playlist`
(id, name, folder/smart flags, uri), `QueueItem` (position, track fields,
uri), `Output` (id, name, type, selected, volume, has_password,
needs_auth_key), `Genre` (name), `SearchResults`, `Paging<T>`
(items, total, offset, limit), `ProviderCapabilities`.

Relationships: Artist 1–n Album 1–n Track; Playlist 1–n Track (via
tracks endpoint, not membership); QueueItem → Track (track_id);
PlayerState.item_id → QueueItem.id; Output independent set.

Data sources: OwnTone JSON API (`:3689`) + websocket (`:3688`);
local: shared_preferences (ServerConfig, rocker step).

Data gaps: no composer browse endpoint (search-type only); no playlist
writes (server setting); artwork may 404 (placeholder); `limit: -1`
semantics.

## Success Criteria (intent-level)

- [ ] Units 001–006 (±007) done in order, each with gates passing
- [ ] Full app navigable: settings → connect → browse → play (supervised)
    → now playing → speakers → rate (supervised)
- [ ] `MusicProvider` contract final: no endpoint string or OwnTone type
      leaks outside `data/providers/owntone/` (review criterion)
- [ ] `live`-tagged test suite exists for every R-ID's server behaviour

## Context

- Dev AVD: `RemoteDev_API_36` (spike unit 001 created it; serial in
  AGENTS.md). UI work via the `flutter_agent_lens` loop.
- Audio safety (D16) per unit: play-touching criteria are
  `supervised: true`; unattended sessions skip them.
- Conventions: `owntone_sync`-style clean arch; dio; provider +
  ChangeNotifier; fakes in `test/fakes/`; tests cite R-IDs.
- Do not gold-plate: ugly-but-correct beats polished-but-unverified;
  SCREENS.md is the finish line for each screen.
