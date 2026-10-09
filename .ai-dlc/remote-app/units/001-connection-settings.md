---
name: 001-connection-settings
status: pending
intent: remote-app
supervised_steps: []
---

# Unit 001 — connection + settings + websocket lifecycle

R-IDs: R-01, R-02. No playback involved — fully unattended-safe.

## Goal

Settings screen (host, JSON port; WS port auto from `/api/config`),
persistence, auto-connect on launch, connection state surface (banner),
and the websocket lifecycle (subscribe, invalidation refetch, backoff
reconnect, full refetch on reconnect). This replaces the spike's
hardcoded config.

## Steps / notes

- `SettingsStore` (shared_preferences): host, port, (later) rocker step.
- `ConnectionController` states: `idle | connecting | connected |
  offline | error(message)`; typed errors (DNS / refused / timeout / 401
  / WS-disabled `websocket_port: 0`).
- `OwnToneSocket`: subscribe `[player, volume, outputs, queue, options,
  database, update]` on connect and after every reconnect; backoff
  1→2→4…30 s cap (core/backoff.dart); on reconnect complete → `RefetchAll`.
- App-wide banner widget when not `connected`; controls disabled while
  offline (no offline queue in v1).
- Tests: state machine transitions, backoff sequence (fake clock),
  event→invalidation mapping (fake socket), WS-disabled handling.
- `live` tests: real connect; wrong host → error; server restart →
  auto-reconnect + correct state (coordinate the restart with the user —
  it's their server; or simulate with `curl` unavailability if granted).

## Completion criteria

1. Settings screen: host + port entry, save, connect; persisted across
   app relaunch (evidence: relaunch, auto-connected).
2. Valid host connects; `GET /api/config` read; WS port derived (not
   hardcoded).
3. Wrong host / wrong port → specific, readable error (three cases:
   DNS, refused, HTTP 401 or other).
4. Server-side change (web UI, **paused-state action** e.g. volume)
   reflected in-app within ~2 s via WS.
5. Kill WS (server restart, coordinated) → backoff reconnect observed in
   logs; after reconnect, player + outputs + current queue item correct.
6. Banner shows on offline; hidden on connect; controls disabled offline.
7. Gates pass; `live` tests exist for criteria 3–5.

## Result

*(fill: evidence per criterion, gate output, live-test list, incidents)*
