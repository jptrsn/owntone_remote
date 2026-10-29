---
name: 002-reconnect-robustness
status: done
intent: device-verification
supervised_steps: [2]
---

# Unit 002 — reconnect robustness

R-IDs: R-01, R-02. The app must survive the real world: Wi-Fi drops,
server restarts, long disconnects.

## Scenarios (each: before → disturb → observe → recover → assert)

1. **Wi-Fi off/on on the AVD** (unattended-safe, server stays paused):
   `adb -s <s> shell svc wifi disable` → app shows offline within ~15 s;
   `svc wifi enable` → auto-reconnect, player/outputs/queue correct, no
   crash, no duplicate notification.
2. `supervised: true` — **server restart** (user restarts OwnTone while
   the app is running, paused state): same assertions as 1 + after
   reconnect the app shows the server's fresh state (volume/state
   unchanged from before).
3. **Long disconnect** (≥10 min, unattended-safe): AVD wifi off 10 min,
   on → backoff sequence in logs (1→2→4→…→30 s cap), state converges,
   memory sane (no unbounded retry queue growth — check log volume).
4. **Rapid flapping** (unattended-safe): 5× quick wifi disable/enable in
   a row → no crash, no duplicate notifications, state consistent.

## Assertions after every scenario

- `GET /api/player` state == app-displayed state
- outputs set matches
- notification shows the current track, single instance
- `flutter` console: no unhandled exceptions (read the `flutter run`
  console — agent-lens `console_logs` misses framework errors, AGENTS.md
  UI loop §5)

## Completion criteria

1. All four scenarios pass with the assertion block green (evidence per
   scenario in `## Result`).
2. Backoff sequence visible in logs for scenarios 3.
3. No crash logs in any scenario.
4. Server left paused (evidence).

## Result

**Status: DONE** — 4/4 scenarios (2 run supervised, user present 2026-10-27).
Zero crashes across the unit; app pid 8340 stable from first launch through
all scenarios (`pidof`, `logcat -b crash` = 0, `E/flutter` = 0 at every
assertion point). Gates on clean HEAD (`6642bb4`, `git status` 0 files):
analyze **0 issues** · format **0 changed** · `flutter test --exclude-tags
live` **362/362** · `flutter build apk --debug` ✓.

### Setup (disposable-AVD policy)

- AVD `OwnToneVerify_API_36` created by this unit (`android-36/google_apis_playstore/arm64-v8a`,
  `-d pixel_6`, `disk.dataPartition.size=8192M` in `config.ini`), booted
  headless; serial **resolved at boot**: `emulator-5554` verified via
  `getprop ro.boot.qemu.avd_name` → `OwnToneVerify_API_36` (foreign
  `ZipCaptions_QA_API_36` = `emulator-5560` throughout — never touched).
  **Deleted at the end**; final `adb devices` = only foreign `emulator-5560`;
  `avdmanager list avd` back to the pre-unit set.
- Runtime: debug app via `flutter run`, then `flutter attach --debug-ui`
  after the force-stop for settings entry detached the run (attach supports
  SIGUSR1 hot reload — how the temporary scenario-3 log line was injected
  and removed without ever dirtying the tree or the APK source).
- UI oracle: uiautomator dumps with the dv-001/007/008 rules (fresh serial,
  `cmd statusbar collapse`, `pkill -9 -f uiautomator`, marker + md5 gate);
  Flutter semantics land in `content-desc`. All field taps used dump
  `bounds=`; IME verified `mInputShown=false` before any further input.
- First launch: POST_NOTIFICATIONS + READ_PHONE_STATE system dialogs granted
  (taps from dump bounds); Host/JSON-port entered on the SettingsScreen
  (`192.168.1.13` / `3689`, verified by dump text read-back), Connect →
  `sync: live`, server-version chip `OwnTone 29.3`.

### Server baseline (as found 2026-10-27 09:1x, == the standing baseline)

```
GET /api/player:  state=pause volume=0 item_id=196947 item_length_ms=211200 item_progress_ms=183192
GET /api/outputs: selected=[Volumio Kitchen (AirPlay, vol 0)] ; Server ALSA unselected vol 8
GET /api/queue:   185 items, first 'Skunk' (Thundersmack), all items carry uri
```
App mirror at connect (`u05_connected.xml`): `03:03`/`03:31` (=183192/211200 ms),
`Playing via: Volumio Kitchen`, `Queue · 185`, `sync: live`. Single
`NotificationRecord ... pkg=dev.educoder.owntone_remote id=1124` baseline.

### Scenario 1 — AVD wifi off/on → offline banner → auto-reconnect: **PASS**

Harness fact that shaped this (and 3/4): on the emulator the default network
is **MOBILE via `eth0`** — `svc wifi disable` alone did **not** isolate the
app (the WS flapped once and re-established over `eth0` within 10 s, banner
never appeared: `u06` FAIL attempts 09:21–09:24). Scenario fidelity =
`svc wifi disable` **with mobile data kept disabled** (`svc data disable`),
which was the state for all scenarios (verified `Active default network:
none`, `ping: Network is unreachable` during windows).
- T0 09:26:51 `svc wifi disable` → `ws: open → reconnecting` **09:26:52.400
  (T0+1.4 s)**, `server probe failed (SocketException … Network is
  unreachable, errno = 101 …) — offline` + `connection: connected → offline`
  **T0+1.4 s**. UI (`u08_offline.xml`): `Server unreachable — retrying.
  Controls disabled.` + `sync: reconnecting…`, stale mirror retained
  (`03:03/03:31`, `Playing via: Volumio Kitchen`) — spec behaviour. Well
  inside ~15 s (measured 1.4 s).
- T_on 09:27:38 `svc wifi enable` → `ws: reconnecting → open` **09:27:54.373
  (+16.4 s)**, `connection: offline → connected`, `WS reconnected — full
  refetch`. UI (`u09_reconnected.xml`): banner gone, `sync: live`,
  `03:03/03:31`, `Queue · 185`.
- Assertions: `GET /api/player` `pause/vol 0/196947/183192` == app labels;
  outputs selected == [Volumio Kitchen]; **1** notification record; pid
  stable; crash/E-flutter 0.
- **R-02 hardening observation (not a criterion FAIL, out-of-scenario
  variant):** the 09:22 data-only drop was *silent* — kernel kept the WS
  socket `ESTAB` (`ss -tnp` shows `10.0.2.15:50302→192.168.1.13:3688` with
  `eth0 state DOWN`), Dart saw nothing, no banner (`sync: live` while
  `Active default network: none`). `WsClient` has no `pingInterval` and the
  app has no ConnectivityManager listener, so offline detection depends on a
  TCP error arriving (netd socket-kill on interface loss, RST). A silent
  middlebox drop would keep the app falsely "live". Candidate for a small
  follow-up (WS app-level ping or periodic REST probe while "connected").
  A wifi-down→data-off *sequence* also left the zombie-ESTAB state until
  re-enable.
  **CLOSED 2026-10-28 by remote-app/009** (main `5fd2823`):
  `WsClient`'s default factory now sets `pingInterval` (10 s) — an
  unponged dart:io socket fails into the unchanged Backoff reconnect;
  silent-drop detection evidenced on-device at 18.4 s via iptables-DROP
  (healthy-idle 130 s with zero spurious reconnects proves OwnTone pongs).
  Evidence: `.ai-dlc/remote-app/units/009-ws-silent-drop-hardening.md` § Result.

### Scenario 2 — server restart (`supervised: true`): **PASS (user present, ran it)**

User restarted OwnTone on 192.168.1.13 on request. `GET /api/config` DOWN at
12:24:17, UP 12:24:24 (7 s outage).
- App: `ws: open → reconnecting` **12:24:15.293**, probe failed
  (`Connection refused, errno 111`) + `connected → offline` **12:24:15.785
  (+0.5 s)**; `offline → connected` **12:24:24.786** (+0.8 s of server up);
  `ws: reconnecting → open` + **`WS reconnected — full refetch`**
  12:24:31.823. UI after (`u10/u11`): app showed the *fresh* server state
  exactly (`Queue · 0` when the server came back empty, then full mirror
  after restore).
- **Incident (server-side, user-caused restart, audio-safe):** the restart
  did **not** persist the player session — server returned `state=stop,
  volume=15, item_id=0, queue 0`. Restored to as-found-equivalent with the
  user present and explicitly approving the *specific* silent sequence:
  queue re-added from `queue_start.json` (185, `clear=true`, **no**
  playback param) → `PUT /api/player/volume?volume=0` (master + Kitchen back
  to 0) → play(queue head)→next→next→`seek?position_ms=183192`→`pause` with
  only the volume-0 Kitchen output selected = inaudible (~1 s silent
  stream). Final player: `pause, vol 0, item 197132, len 211200,
  progress 183144`. Deltas vs found: `item_id` regenerated (196947→197132 —
  queue ids are per-queue-instance; content-identical queue re-add
  regenerates them) and progress Δ48 ms (seek granularity). No audible
  audio at any point; second `next` was already paused (next-while-paused
  keeps pause). API facts learned: `PUT /api/player/pause` from `stop` →
  500; there is **no** `/api/player/items/play/<id>` endpoint (400; not in
  the server's json-api docs) — playing a queue item = `play` + `next×n`.
- Assertions: 1 notification, pid stable, crash 0; app `Queue · 185`,
  `House Party` + `Thundersmack · Brass`, `03:03/03:31`, `sync: live`.

### Scenario 3 — long disconnect ≥10 min: **PASS** (backoff quoted)

Fresh window T_off2 **12:38:51** (backoff reset by a verified reconnect at
12:36:41; `sync: live` + full mirror confirmed before the window). Offline
again at **T_off2+0.9 s**. Log (logcat tag `flutter`, temp `print()` added to
`WsClient._scheduleReconnect` via hot reload — see harness notes; removed
after, tree verified clean `git diff` empty before gates):

```
12:38:51.906 dv002b ws reconnect attempt scheduled in 1000 ms
12:38:52.910 dv002b ws reconnect attempt scheduled in 2000 ms
12:38:54.915 dv002b ws reconnect attempt scheduled in 4000 ms
12:38:58.918 dv002b ws reconnect attempt scheduled in 8000 ms
12:39:06.924 dv002b ws reconnect attempt scheduled in 16000 ms
12:39:22.929 dv002b ws reconnect attempt scheduled in 30000 ms
12:39:52.933 dv002b ws reconnect attempt scheduled in 30000 ms
12:40:22.940 dv002b ws reconnect attempt scheduled in 30000 ms   … (capped)
```
1→2→4→8→16→30 cap ✓ (and the scheduled attempt *timestamps* match each
printed delay, so the delays were actually used). **27** attempts over
**11 min 02 s** offline (12:38:51→12:49:53), total flutter log lines across
the whole window **37** — bounded, no retry-queue/log flood; `dumpsys
meminfo` TOTAL PSS 269 MB (typical debug-build floor), no growth signal.
Re-enable 12:50:04 → `ws: reconnecting → open` + `offline → connected` +
`WS reconnected — full refetch` at **12:50:23.77 (+19.7 s**, ≤30 s cap ✓).
Assertions: `u13_s3_final.xml` `sync: live`, `House Party 03:03/03:31`,
`Queue · 185`; server `pause/vol 0/197132/183144`; 1 notification; crash 0.

### Scenario 4 — rapid flapping (5× wifi off 2 s / on 2 s): **PASS**

T_flap 12:51:59–12:52:19. App logged a **single** `connected → offline`
(12:51:59.996) — the flapping did **not** thrash the phase machine (dedupe
by `_setPhase`), then one clean converge: `ws: reconnecting → open` +
`offline → connected` + full refetch at 12:52:31.67 (+12 s after last flap).
Assertions: UI `sync: live` + full correct mirror (`u14_s4_final.xml`);
server `pause/vol 0/197132/183144` unchanged; **exactly 1** notification
record (`id=1124` — no duplicate channel/notification despite 10 radio
transitions); pid 8340 unchanged (no crash/restart); crash buffer 0;
`E/flutter` 0; flap-window log volume 25 lines (bounded).

### Post-scenario assertion block (after EVERY scenario, run each time)

`GET /api/player` == app-displayed state (state/progress/length/outputs
labels matched in dumps u05/u09/u11/u13/u14); outputs set == [Volumio
Kitchen]; notification = 1 record, `android.title=House Party`,
`android.text=Thundersmack` (current track ✓); zero crash logs (`logcat -b
crash` grep owntone = 0 at every check), zero `E/flutter`; `flutter attach`
console clean (agent-lens `console_logs` not relied on for exceptions, per
AGENTS.md).

### Server left as found

```
final GET /api/player: state=pause volume=0 item_id=197132 item_length_ms=211200 item_progress_ms=183144
final GET /api/queue:  185 items, field-by-field content-identical to queue_start.json
final GET /api/outputs: selected [Volumio Kitchen] vol 0; Server unselected vol 8
```
Only deltas vs found: `item_id` regenerated (queue-instance-local ids —
unavoidable once the queue is re-added; contents exact) and Δ48 ms progress
— both consequences of the *user's* supervised restart, not app behaviour.
No library/rating/playlist/output-selection mutations (outputs never touched
via API this unit; ratings untouched). No app-caused playback; the only
stream window was the approved, volume-0, inaudible restore (user present).
No external-session interference observed this unit (unlike dv-001).

### dv-001 cross-reference

R-01 (relaunch auto-reconnect: re-proven this unit by the force-stop/relaunch
during setup — prefilled prefs, `sync: live` without re-entry) and R-02
(backoff now *quoted* live for the first time, full-refetch on reconnect
confirmed 4×) — **nothing shifted**, dv-001 rows stand as PASS.

### Harness notes (for the next verification run)

- **Emulator isolation needs BOTH radios off:** default network is
  MOBILE/`eth0`; `svc wifi disable` alone leaves the app fully online (WS
  briefly resets, then re-establishes — a good R-02 robustness data point on
  its own). Use `svc wifi disable` + `svc data disable`; verify `Active
  default network: none`.
- Silent interface-down → socket stays `ESTAB` in kernel, no Dart event (see
  scenario-1 observation): the *abrupt*-interface (wifi) path is the one that
  produces a fast offline detection.
- `disk.dataPartition.size=8192M`: `avdmanager create` already writes a
  10G line — append the required one and **delete the 10G line** (duplicates
  are confusing).
- `flutter run` dies when the app is force-stopped (lost connection) →
  reattach with `adb forward tcp:P tcp:P` + `flutter attach --debug-ui`
  (the VM-service URI is in `logcat | grep "Dart VM service"`). SIGUSR1
  hot-reloads it; a reload reports `Reloaded 0 libraries` when the file
  changed *before* the attach sync — the delta must be made after attaching.
- Temporary instrumentation via hot reload keeps the installed build + the
  committed tree pure HEAD (unit 007 precedent, reused here for the backoff
  quotes).
- `dump.sh` md5 gate false-rejects when the screen legitimately returned to
  a previously-dumped state (identical XML) — accept the raw dump after
  verifying the marker by hand.
- Screen sleeps during long windows: `input keyevent WAKEUP` +
  `wm dismiss-keyguard` before the convergence dump.
- `PUT /api/player/pause` from `stop` → 500; queue-add without `playback`
  still sets `item_id` to the queue head (`state` stays `stop`).
