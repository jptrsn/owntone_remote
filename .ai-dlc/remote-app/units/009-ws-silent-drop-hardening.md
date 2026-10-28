---
name: 009-ws-silent-drop-hardening
status: pending
intent: remote-app
supervised_steps: []
---

# Unit 009 — WS silent-drop hardening (R-02 blind spot)

R-IDs: R-02 (closes the hardening observation recorded by
device-verification unit 002, SESSION-LOG 2026-10-27: "a *silent*
interface-down leaves the WS socket `ESTAB` in the kernel with zero Dart
events — no `pingInterval` and no ConnectivityManager listener means a
silent middlebox drop would keep the app falsely `sync: live`").

## Goal

1. **Liveness detection on the open WS.** While the socket reports
   `open`, the client must detect a peer that has gone silently dark
   (no FIN/RST, no frames — middlebox drop / interface death without
   socket error) and transition to the reconnect path, so the app never
   presents `sync: live` over a dead connection. The minimal shape is
   the existing seam: `IOWebSocketChannel.connect` gains a
   `pingInterval` (dart:io fails the socket when pings go unponged;
   `WsClient` already drives reconnect from `onDone`/`onError`,
   `lib/src/api/ws_client.dart:86-92`). **No new plugin
   dependencies** (no `connectivity_plus`) — app-level ping is the
   contract.
2. **Degraded-sync semantics preserved.** WS death while REST is still
   reachable = `WsPhase.reconnecting` with `ConnectionPhase.connected`
   (controls keep working, R-02 "WS failure never blocks REST control").
   The offline banner stays exactly as unit 001 defined it: driven by
   the REST probe while the WS is down (`lib/src/connection/connection_controller.dart:237-251`).
   This unit changes only *how fast WS-down is discovered*, not who
   decides `offline`.

## Steps / notes

- Ping cadence bounded and configurable in code: detect a silent death
  in **≤ 30 s** (e.g. 10 s pingInterval; dart:io fails the socket on
  the next unanswered ping). Reconnect uses the existing `Backoff`
  — the 1→2→4→8→16→30 s sequence is an R-02 invariant, unchanged.
- After reconnect: re-subscribe `notify` + full refetch (existing D2
  behaviour — regression-guard, don't redesign).
- OwnTone's libwebsockets server pongs automatically (RFC 6455) — the
  healthy-idle criterion below is the live proof; if it does **not**
  pong, the ping is a self-inflicted disconnect loop and the criterion
  fails the unit.
- Harness (dv-002 lessons, SESSION-LOG 2026-10-27): emulator rides
  **eth0** — `svc wifi disable` alone never disconnects; full network
  isolation = `svc wifi disable` + `svc data disable`. A *silent* drop
  (no interface event) must be simulated by **dropping the packets**,
  not by disabling the interface: e.g. `adb root` +
  `adb shell iptables -A INPUT -p tcp --sport 3688 -j DROP` (+ the
  matching OUTPUT rule) on the disposable AVD — kernel stays `ESTAB`,
  zero Dart events unless liveness detection exists. Flush the rules to
  recover.
- Server: shared (192.168.1.13) — snapshot baseline before, restore
  byte-identical after; `GET /api/player` re-verified immediately
  before anything that could touch state; **zero** play/transport
  actions (volume change via server web UI while paused is allowed and
  is the event-flow probe).

## Completion criteria

1. **WsClient unit tests** (test-author authored, via the
   `channelFactory` seam / default factory):
   a. the default factory produces a channel with liveness detection
      configured (`pingInterval` set, value ≤ 10 s) — a kill-check on
      this assertion must be possible;
   b. error/close on an `open` channel → `reconnecting` + a reconnect
      attempt at the next backoff delay (regression);
   c. healthy idle (pings answered) → **no** reconnect within 3×
      pingInterval;
   d. `stop()` cancels every timer — no reconnect after stop;
   e. the pre-existing `ws_client_test` + `backoff_test` suites stay
      green.
2. **Controller contract test:** WS transitions to `reconnecting` while
   REST stays reachable → phase remains `connected`, controls enabled,
   no banner; REST also dead → `offline` + banner (existing behaviour
   regression).
3. **On-device (own disposable AVD, per-unit create+delete policy):**
   - silent drop (`iptables` DROP on :3688 traffic, socket `ESTAB`
     confirmed via `adb shell ss -tp` before detection): app leaves
     false-live and reports WS reconnecting within ≤ 45 s — **quoted
     from logcat** with the drop instant and detection instant;
   - rules flushed → reconnect + full refetch (app UI == server for
     player state/outputs/queue head);
   - healthy idle ≥ 2 min while connected: **0** spurious `reconnecting`
     transitions in logcat (proves server pongs land);
   - server-web-UI volume change (while paused) reflects in-app ≤ ~2 s
     after the fix (R-02 acceptance row, proves events still flow);
   - full isolation (`svc wifi disable` + `svc data disable`) → offline
     banner within ≤ 60 s (ping detection + REST probe path); restore →
     converge.
4. **Gates green + debug APK** (AGENTS.md quality gates verbatim).
5. **Server left byte-identical to baseline** (player state/outputs/
   queue snapshot in `## Result`, start == end); AVD deleted;
   `adb devices` afterwards shows only foreign devices.
6. **SESSION-LOG entry + commit** `remote-app/009: …`; the dv-002
   hardening note closed by pointer (orchestrator adds the cross-ref at
   merge time).

## Result

(pending)
