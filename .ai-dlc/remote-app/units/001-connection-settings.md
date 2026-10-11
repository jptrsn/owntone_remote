---
name: 001-connection-settings
status: done
intent: remote-app
supervised_steps: [criterion 5 — OwnTone disable/re-enable, user performed and witnessed]
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
8. (added mid-unit 2026-10-11, user requirement) Now-playing screen fits
   the visible viewport without scrolling: artwork shrinks, 1:1 aspect
   ratio preserved, all controls visible.

## Result

**done (2026-10-11, opencode).** All criteria verified. Timestamps are host
local time unless marked `dev:` (emulator clock runs ahead).

### Evidence per criterion

1. **Relaunch → auto-connect.** 03:40:48 `am force-stop` + `am start`;
   logcat: `connection: idle → connecting → connected` (03:40:53),
   `ws: none → open`. UI returned straight to now-playing (a11y dump:
   'sync: live', track, outputs) — no host re-entry.
2. **Valid host, WS port derived.** Every connect reads
   `GET /api/config`; app bar shows `OwnTone 29.3` (version from the
   same call); WS opens on 3688 (from config, never hardcoded —
   `connection_controller.dart:172-174`). Repeatedly observed
   `ws: none → open` after each connect in this session.
3. **Typed errors, verbatim on device** (via prefs-surgery relaunch,
   `FlutterSharedPreferences.xml` edited while app stopped):
   - wrong host `no-such-host.invalid` → error screen shows
     `Host "no-such-host.invalid" could not be resolved (DNS).`
     (a11y dump; note: uiautomator single-quotes the attribute when
     the value contains `"`).
   - wrong port `192.168.1.13:3999` →
     `Connection to 192.168.1.13:3999 was refused — is the server running there?`
   - 401 path exists and is unit-tested (`connection_error_test.dart`)
     but not exercised on-device (the user's server has no auth).
   - Config restored to 192.168.1.13:3689 and re-verified connected.
4. **WS propagation < 2 s.** Server volume 75→80 at 02:28 (paused
   state); the app's volume label + slider showed `80`/`80%` in the
   dump taken 2.3 s after the PUT (dump itself costs ~2 s, so
   propagation was well under 2 s). Reverse 80→75 same (2.96 s
   dump). WS event probe (earlier): server→WS event latency ~0.54 s.
   Final state restored: pause/75 (later stop/75 after the
   supervised restart — see 5).
5. **Server restart → backoff → reconnect → correct state.**
   Supervised: user disabled + re-enabled OwnTone (dev: 10:29:41).
   App log: `ws: open → reconnecting` (10:29:41.107) → probe failed
   `Connection refused (errno = 111)` → `connected → offline`
   (10:29:41.607) → server down ~17.5 s → `ws: reconnecting → open`
   (10:29:58.608) → `offline → connected` → `WS reconnected — full
   refetch`. Post-reconnect app state (a11y: 'Stopped', 00:00, 75%,
   'Playing via: Office-Airsync') matched the server (curl:
   `state=stop, volume=75, item_id=0`, selected outputs
   `[Office-Airsync]`). No playback occurred (server returned to
   stop; volume stayed 75).
6. **Offline banner + disabled controls.** On-device: the 10:29
   offline window — **user witnessed the banner appear and
   disappear** (supervised criterion 5 doubles as this).
   Deterministic coverage: `test/now_playing_screen_test.dart`
   (offline phase → banner shown, all transport `IconButton`s
   `onPressed == null`, volume slider disabled; server back → banner
   gone, controls re-enabled).
7. **Gates + live tests.** See below.
8. **No-overflow now-playing (added mid-unit, user requirement).**
   `NowPlayingBody` is now a non-scrolling `Column`; the artwork sits
   in `Expanded(Center(ArtworkBox))` and the inner `AspectRatio(1)`
   takes `min(availW, availH)` — always square, shrinks first.
   Widget tests at 360×960 (artwork 312 = full width), 360×640
   (artwork shrinks below width, volume row visible), 360×560
   (shrinks further, no overflow). On-device a11y bounds: volume
   SeekBar y=1731–1857 (< 1920), no nodes below it; artwork region
   ~529 px tall vs 1032 px content width (shrunk).

### Gate output

```
flutter analyze                        → No issues found!
dart format --output=none --set-exit-if-changed .
                                       → Formatted 33 files (0 changed)
flutter test --exclude-tags live       → 00:02 +60: All tests passed!
flutter test --tags live               → 00:00 +4: All tests passed!
flutter build apk --debug              → ✓ Built app-debug.apk
```

Live tests (`test/live/connection_live_test.dart`): real connect +
WS event→refetch; wrong host (DNS) and wrong port (refused) typed
errors; reconnect refetch. All 4 pass.

### Findings (carry forward)

- **No WS keepalive → silent partitions undetected.** A network
  partition that does not tear down the idle WS socket (no interface
  down event, no RST) leaves the app showing `sync: live`
  indefinitely; probes only run on WS-reconnect attempts. Observed
  live during this session (route removed, app stayed connected).
  Needs a client keepalive (ping/no-activity timeout → force
  reconnect) — candidate for unit 002 hardening or a dedicated
  unit. (Socket-teardown drops — radio down, server restart — *are*
  detected and were the basis of criteria 5/6 evidence.)
- **Dart 3.11.5 SDK quirks:** `SocketException.toString` reports the
  *local* ephemeral port, not the destination (probe to :3999 prints
  `port = 59813`) — never parse ports out of exception text;
  `InternetAddress` has no `.port`; `AddressException` is gone (DNS
  failure = `SocketException "Failed host lookup"`, errno 8).
  `connectionErrorFromDio` matches on keywords only — unaffected.
- **uiautomator wraps `content-desc` in single quotes when the value
  contains `"`** — grep for `content-desc="…"` silently misses such
  nodes (nearly cost the DNS-message evidence).
- **`flutter run` auto-restarts the app on force-stop** — kills clean
  prefs-surgery sequences; kill the runner first.
- **Emulator hazards (environmental, not app bugs):** Play Services
  `MinuteMaidActivity` can steal foreground (breaks a11y + input;
  close with BACK); `adb input text`/key events are dropped while the
  IME is shown (hide first — but BACK may pop the route: verify
  `mInputShown` and the screen); `svc wifi/data disable` is flaky on
  the emulated radios; the Flutter a11y bridge can silently die
  (empty 1.5 KB dump) — restart the `flutter run` session.
- **OwnTone disable/re-enable** returns the server to `state=stop`
  with the queue cleared (server behaviour, not app-caused). The
  app's `Stopped` + no-item rendering handled it correctly.

### Incidents

- No playback at any point (server pause→stop, volume 75 throughout;
  the only user-initiated state change was the supervised restart).
- An earlier live-test failure left the server volume at 90;
  restored to 75 and verified the same session.
