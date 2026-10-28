---
name: 009-ws-silent-drop-hardening
status: done
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

**Status: DONE** — unattended overnight build (opencode, 2026-10-28).
Zero supervised steps in this unit; **zero** play/transport actions taken.

### What was built

`lib/src/api/ws_client.dart`: named constant `kWsPingInterval = Duration(
seconds: 10)` passed as `pingInterval:` to `IOWebSocketChannel.connect` in
the **default** channel factory (next to the `notify` subprotocol). dart:io
sends a ping every interval (re-armed on each pong) and fails the socket
(`goingAway`) when a pong doesn't arrive within one interval —
https://api.dart.dev/stable/3.11.5/dart-io/WebSocket/pingInterval.html —
which surfaces as `onDone`/`onError` and drives the **existing** reconnect
path unchanged. `notify` subprotocol, `Backoff` (1→2→4→8→16→30 s),
re-subscribe on reconnect, and the REST-probe-decides-offline logic: all
untouched (`git diff` confirms; no new packages).

### Criterion 1 — WsClient unit tests (all green, 05811ff contract)

| Sub | Test | Result |
|---|---|---|
| 1a liveness configured | `ws_client_liveness_test.dart` ping-observed-within-13 s | RED→**GREEN** |
| 1a silent-dark detection | `ws_client_liveness_test.dart` reconnecting ≤ 25 s | RED→**GREEN** (detected at 1 ping unanswered; dart:io goingAway) |
| 1c healthy idle | `ws_client_liveness_test.dart` ≥ 2 pings in 34 s, 0 reconnects, 1 handshake | RED→**GREEN** |
| 1b close/error on open → backoff-delayed attempt | `ws_client_reconnect_test.dart` ×2 | GREEN (guard held) |
| 1d stop() cancels timers | `ws_client_reconnect_test.dart` ×2 | GREEN (guard held) |
| 1e existing suites | `ws_client_test` + `backoff_test` | GREEN |

**Kill-check performed:** with `pingInterval:` deleted from the default
factory, `flutter test test/ws_client_liveness_test.dart` → **0 passed, 3
failed** ("peer saw no ping frame within 13 s"); restored → 3/3 green.
`git diff 05811ff..HEAD -- test/` = **0 lines** (tests never touched).

### Criterion 2 — degraded-sync contract

`connection_controller_degraded_sync_test.dart` **GREEN** (WS `reconnecting`
+ REST alive → phase `connected`, no `offline/` transition, REST probe ran
>1× on reconnect attempts; REST dead → `offline`; recovery → `connected` +
exactly 1 `refetchAll` + notify re-subscribed). On-device corroboration:
every iptables-drop detection logged `ws: open → reconnecting` with **no**
`connected → offline` line while :3689 stayed reachable (banner absent in
`u10_during_reconnecting.xml` — `sync: reconnecting…` chip only).

### Criterion 3 — on-device (disposable `OwnToneNight_009_API_36`)

Created by this unit (`android-36/google_apis/arm64-v8a`, `-d pixel_6`,
`disk.dataPartition.size=8192M` replacing the duplicate 10G line — dv-002
gotcha), booted headless, serial resolved at boot: `emulator-5554` verified
`getprop ro.boot.qemu.avd_name` → `OwnToneNight_009_API_36`; `svc power
stayon true`. **Deleted at the end**; `adb devices` afterwards: none of
ours. Host/port entered on Settings (read-back verified `192.168.1.13`/
`3689`), Connect → `sync: live` (`u07_connected.xml`).

| Row | Evidence (device clock, `logcat -v epoch`) |
|---|---|
| Baseline start (as found) | `player: state=pause volume=42 item_id=197444 len=126516 prog=111908`; outputs selected `[Volumio Kitchen vol 42]`; queue 0 |
| Silent drop #1 (harness dry-run) | `iptables -A INPUT -s 192.168.1.13 -p tcp --sport 3688 -j DROP` + OUTPUT `--dport 3688`; REST :3689 confirmed alive (host curl 200) |
| Socket ESTAB pre-detection | `ss -tnp` → `ESTAB 10.0.2.16:59790→192.168.1.13:3688 pid=4549` (rule instant epoch 1793229513) |
| Detection ≤ 45 s | **drop instant 1793229513 → `ws: open → reconnecting` 1793229531.431 = 18.4 s**; then `FIN-WAIT-1` + `SYN-SENT` (dart:io failed the socket, reconnect loop running) |
| No false offline while REST alive | no `connected → offline` log line in the whole drop window; `u10_during_reconnecting.xml`: `sync: reconnecting…`, **no** `Server unreachable` |
| Flush → reconnect + full refetch | rules deleted → `ws: reconnecting → open` **1793229568.459** + `WS reconnected — full refetch`; `u11_after_flush.xml` == server (`01:51/02:06` = 111908/126516 ms, 42 %, `Playing via: Volumio Kitchen`, `sync: live`) |
| Healthy idle ≥ 2 min | epoch 1793229590→1793229720 (130 s): `ss` same socket `:44150` start and end (0 re-handshakes), `reconnecting|ws:` grep count in window = **0** (server pongs land) |
| Event flow while paused | re-verified `pause` via curl → `PUT /api/player/volume?volume=55` → **204** → app content-desc `55%` within **3 s** (≤ ~2 s + 1 s dump poll) → restored `volume=42` (204, server confirmed) |
| Full isolation → offline ≤ 60 s | `svc wifi disable` + `svc data disable` epoch 1793229783 → `ws: open → reconnecting` 1793229784.186 → probe `SocketException … Network is unreachable, errno = 101` → `connected → offline` **1793229784.190 (+1.2 s)**; banner `Server unreachable — retrying. Controls disabled.` (`u14_offline.xml`) |
| Restore → converge | `svc wifi/data enable` ~1793229802 → `offline → connected` + `reconnecting → open` + `WS reconnected — full refetch` **1793229815.927 (+13.9 s)**; `sync: live`, stale mirror replaced with correct values |
| Stability | pid 4549 stable whole session; `logcat -b crash` grep owntone = **0** |

### Criterion 4 — gates (verbatim tails, run on the final tree)

```
$ flutter analyze
No issues found! (ran in 2.8s)

$ dart format --output=none --set-exit-if-changed .
Formatted 82 files (0 changed) in 0.25 seconds.

$ flutter test --exclude-tags live
01:14 +370: All tests passed!

$ flutter build apk --debug
✓ Built build/app/outputs/flutter-apk/app-debug.apk
```

### Criterion 5 — server left as found; AVD deleted

`cmp` of start vs end snapshots (`build/night-009/server_{player,outputs,
queue}_{start,end}.json`): **player, outputs, queue all byte-identical**
(`pause / vol 42 / item 197444 / len 126516 / prog 111908`; selected
[Volumio Kitchen 42]; queue 0). No play/next/prev/queue-add/rescan/update
was ever issued; volume probe restored to the found value and verified.
**External-session delta (not restored over, per policy):** the other
active session on this server refilled the queue to 1514 items between the
baseline curl and the app connect, and cleared it again near the end of the
window — the app's queue chip showed `Queue · 1514` at the last dump;
server queue returned to the baseline (0) by the end snapshot, matching
baseline. Player/outputs never moved from baseline during the run.
`avdmanager delete avd -n OwnToneNight_009_API_36` ✓; final `adb devices`
= none of ours.

### Criterion 6 — log + commit

SESSION-LOG entry appended; implementation commit `e039649`
(`remote-app/009: WS liveness via dart:io pingInterval …`), pushed to
`origin/remote-app/009-ws-silent-drop-hardening`. dv-002's hardening note
is closed by this unit (orchestrator adds the cross-ref at merge).

### Harness notes (for the next verification run)

- `adb root` kills running `adb logcat` pipes — start the capture **after**
  rooting, or re-read history with `logcat -d -v epoch` (timestamps are
  monotonic device-clock seconds; deltas are trustworthy).
- iptables on the AVD needs `-s/-d 192.168.1.13/32` scoping; a system
  `tetherctrl_FORWARD -j DROP` rule exists by default — never blanket-`-F`.
- Emulator clock vs host: run `adb shell date +%s` brackets around the
  disturbing command; the device clock is authoritative for detection
  latency (host/device offset ≈ 1 s).
- Flutter export: labels land in `content-desc` (grep it); EditText fields
  expose `hint="Host"` / `hint="JSON port"` and the *label* migrates into
  content-desc after typing — locate by `hint`+`bounds`. IME re-tap trap
  confirmed again (second field tap while keyboard open re-hits the first
  field): `keyevent 111`(ESC)/4 + `mInputShown=false` verify between
  fields (dv-008 lesson re-earned).
- A **silent** drop (iptables DROP) produces zero kernel events; dart:io
  ping detection fires at 1× interval + ≤ 1× pong-timeout (observed 18.4 s
  worst case, budget 45 s) — exactly the dv-002 blind spot now closed.
