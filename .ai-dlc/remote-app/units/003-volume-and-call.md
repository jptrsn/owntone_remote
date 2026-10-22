---
name: 003-volume-and-call
status: done
intent: remote-app
supervised_steps: [3, 4]
---

# Unit 003 — volume rocker + call handling (pause / auto-resume)

R-IDs: R-06, R-08. The two "system integration" features.

## Goal

Hardware volume rocker → master volume (step), screen off + backgrounded.
Incoming call → pause server; call end → auto-resume **only if the app
paused for the call** (pause-origin tracking, R-08).

## Steps / notes

- Rocker: `RemoteAndroidPlaybackInfo(max: 100, current: v)` published on
  every volume change; `androidAdjustRemoteVolume` →
  `PUT /api/player/volume?step=±N` (default N=5, configurable in
  settings per R-14 — add the setting here if R-14 is in scope for the
  unit order; otherwise hardcode 5 + TODO).
- Call channel: Kotlin `TelephonyCallback` (API 31+; `TelephonyManager`),
  events → `call_state` stream. `PlayerController`:
  - `ringing|offhook` while `state == play` → `pause()`,
    `pauseOrigin = call`;
  - `idle` → if `pauseOrigin == call` → `resume()` (playback=start via
    `PUT /api/player/play` — **supervised**);
  - user pause sets `pauseOrigin = user` → never auto-resumed.
- Edge cases (unit tests): call during pause (no-op), call during
  `state == stop` (no resume), call ends before pause ack (debounce
  window), multiple ringing/idle flaps (ignore flaps <500 ms).
- Tests: pause-origin state machine (all edges above), channel event
  mapping (mock MethodChannel), rocker step math.

## Completion criteria

1. **(Rescoped by the user 2026-10-22, D20.)** Rocker up/down changes
   master volume ±5 **while the app is in the foreground** (evidence:
   `GET /api/player` volume before/after, timestamped); and with the
   app **backgrounded** the rocker must leave the server volume
   unchanged — including while the server is `play` (non-interference,
   timestamped). *(foreground + stopped-state form is safe while the
   server is stopped; the backgrounded-`play` form is supervised.)*
2. Slider and rocker stay in sync (WS volume events).
3. `supervised: true` — simulated call (emulator Extended Controls →
   Phone → dial) while playing (user-approved play) → server `pause`;
   call ends → server `play` (auto-resume).
4. `supervised: true` — user-pause case: pause manually, simulate call,
   call ends → **still paused**.
5. Edge-case unit tests pass (flaps, call-while-paused, stop state).
6. Gates pass.

## Result

**Status: DONE — all six criteria PASS.** 2026-10-13: code, tests,
gates + C2 slider half done. 2026-10-22 (supervised window, user
present): **C4 then C3 PASS** (transcripts below). C1: rescoped by the
user (D20: rocker maps to server volume only while foregrounded). The
Pixel 6 was granted; its morning app-egress block cleared when the user
re-seated the USB cable. The D20 foreground guard + unit tests were
added, then **all three C1 forms PASS on the Pixel 6 on the final
build**: foreground (server stopped), backgrounded (server stopped),
and the supervised backgrounded-`play` non-interference (evidence in
the Criterion 1 section below).

### Design — 500 ms flap filter + pause-in-flight tracking (unit edge cases)

The spike's pause-on-ringing design had two unsafe races: a short
ringing→idle flap would pause the server for nothing, and a call that
ended before the pause acked left the origin lingering as `call` (a much
later call would auto-resume a stale pause). New pure, synchronous state
machine `CallPauseTracker` (`lib/src/player/call_pause.dart`) composes the
unchanged `PauseOriginTracker` with: the flap filter (the controller owns
the real 500 ms `Timer`, `PlayerController.flapWindow`; the machine is
timer-free so it unit-tests without FakeAsync), `pauseInFlight`, and
`resumeAfterAck` (call ended before the ack → resume once the ack lands,
origin cleared to unknown). OFFHOOK (`active`) confirms a call
immediately, even without a preceding RINGING event. Wiring:
`PlayerController.onCallRinging/onCallActive/onCallEnded`, `main.dart`
`active → onCallActive()` (was ignored). Rocker mapping extracted to the
pure `rockerStepFor` (`mirror_handler.dart`): `same` stays a no-op
(Finding 10) and is now test-pinned; `rockerStep = 5` hardcoded +
TODO(R-14) per the unit (R-14 is P2, not in this unit's scope).

### Criterion 5 — edge-case unit tests: PASS

`flutter test --exclude-tags live` → **140/140** (95 pre-existing + 45
new), incl. the 4 unit-mandated edge cases:

- `test/call_pause_tracker_test.dart` (15, the pure machine): flap
  ringing→idle ignored + machine recovers; repeated ringing in-window;
  stray idle no-op; active-in-window confirms (flap-elapsed then no-op);
  active without ringing; happy path (claim → resume → consumed once);
  **call while user-paused → not claimed**; **call during stop → no call
  origin**; user-pause after the claim wins; external play after the
  claim; **call ends before the pause acks → resume on the ack** (origin
  not left lingering); pre-ack + failed pause → no resume; failed pause
  with the call still on → no resume on idle; second call while a call is
  on; double idle.
- `test/player_controller_call_test.dart` (8, controller integration vs.
  `StatefulServer`, real-time flap timer): flap under the window issues
  nothing; call while playing → exactly one pause at confirmation →
  resume on end; call while user-paused → no pause, no resume; call while
  stopped → nothing; failed call-pause never claimed (asserts the
  optimistic-rollback error too); **call ending before the 900 ms-slow
  pause acks → no play before the ack, play once it lands**
  (`DelayingPauseAdapter`); active confirms well before 500 ms; active
  without ringing.
- `test/rocker_step_test.dart` (4): raise→+step, lower→−step,
  **same→null (Finding 10 regression)**, step configurable (R-14).
- `test/rocker_foreground_test.dart` (9, the D20 guard): rocker
  type mapping; backgrounded rocker/set never issue a `PUT`; backgrounded
  session publishes `fixed`; foregrounded rocker ±5 and set land; the
  publish flips `fixed↔absolute` with the flag and backgrounding
  re-arms the no-op.
- `test/call_state_channel_test.dart` (9, mock MethodChannel):
  ringing→active→idle order; non-String/null args ignored; unrelated
  method ignored; push before `start()` dropped; permissions map
  round-trip; `PlatformException` → `{}`; `dispose()` closes the stream;
  broadcast to two listeners.

### Criterion 6 — gates: PASS (final D20-guard code, 2026-10-22)

```
flutter analyze                                  # No issues found
dart format --output=none --set-exit-if-changed .  # 43 files, 0 changed
flutter test --exclude-tags live                 # 140/140 All tests passed
flutter build apk --debug                        # ✓ Built (app-debug.apk)
```

### Criterion 2 — slider ↔ server sync via WS (AVD half): PASS; rocker
half rides on C1's device time

`RemoteDev_API_36` (emulator-5554), server `stop` throughout (safe):

| t | step | evidence |
|---|---|---|
| 05:03:46 | baseline | server `stop, volume=75`; app label `75` (uiautomator) |
| 05:04:27 | **app→server**: real slider drag `input swipe 668 1794 560 1794 600` (75→~60) | `GET /api/player` → `volume=62` (gesture quantisation), state stayed `stop` — the drag-state commit (unit 002) sent `?volume=62` |
| 05:05:47→05:05:52 | **server→app** (the rocker's sync path): `PUT /api/player/volume?volume=80` | app slider `content-desc="80%"` / label `80` in the next uiautomator dump — WS `volume` push within dump overhead (sub-second event→UI per spike criterion 3) |
| 05:06:39 | restore | `PUT volume=75` → app `75%`/`75`, server confirmed `75` |

The rocker half (physical press → server → WS → slider) is evidenced
together with criterion 1 on the real device.

### On-device call-safety no-op (safe half of R-08, server `stop`)

New-build proof that a real call does nothing while the server is stopped
(no pause issued, no resume possible — the call never owns the origin):

| t | event |
|---|---|
| 05:10:47 | `adb emu gsm call 5551234567` (OK) |
| 05:10:47.740 | app log `call state: ringing` |
| 05:10:51 | `gsm cancel 5551234567` (OK) — ~3.8 s ringing, so the call passed the 500 ms flap window and was confirmed; server was `stop`, so no pause was issued |
| 05:10:51.522 | app log `call state: idle` |

Server byte-identical before/after: `stop, volume=75, item_id=196174`.
Permissions persisted from the spike (`POST_NOTIFICATIONS`,
`READ_PHONE_STATE` granted; app reported no pending at 04:56:47).

### Criterion 1 — PASS (D20 rescoping, 2026-10-22)

Volume-key routing is testable only on a real device (spike Finding 11:
the AVD never selects the session for volume keys). 2026-10-22 the user
granted the Pixel 6; lock screen removed per the user, APK installed,
POST_NOTIFICATIONS + READ_PHONE_STATE granted, app configured for
`192.168.1.13:3689`.

**Device-network saga (morning, resolved by the user):** between ~11:00
and ~16:43 every TCP connection from inside the app to any
non-loopback destination timed out (`errno = 110`) with **no kernel
socket ever created** (watched `/proc/<pid>/net/tcp{,6}` at ~0.4 s
through the window), while shell (`nc`), GMS, and the Mac all reached
the server; a clean reinstall (fresh uid 10310) failed identically;
AppOps/VPN/proxy/SELinux all clean; the device had run the setup wizard
~09:24 (fresh reset). Unresolvable without root — **the user unplugged
and re-plugged the Pixel 6 (~16:40) and app egress worked
immediately** (the 17:02 mis-typed-port attempt got a clean `refused`,
proving reachability). Lesson recorded: this symptom class on this
device is fixed by a USB reseat.

**Mid-test rescoping (D20):** the user redefined the rocker contract —
server-volume mapping **only while the app is foregrounded**;
backgrounded, the phone's volume keys do their normal thing and the app
must never touch the server's volume (including while the server
plays). The criterion was reworded accordingly; docs updated
(REQUIREMENTS R-06, PLAN S4/D20).

**Foreground form — PASS (server `stop`, safe; all `GET /api/player`):**

| t | step | evidence |
|---|---|---|
| 17:08:33 | baseline | `stop, volume=36` |
| 17:08:50 | **backgrounded, screen off** (pre-rescope attempt) | rocker UP → `volume=36` — no server change |
| 17:14:49 | foreground, screen on, baseline | `stop, volume=36` |
| 17:14:51 | **rocker UP (foreground)** | `stop, volume=41` |
| 17:15:13 | **rocker DOWN (foreground)** | `stop, volume=36` — restored |

So: foreground (even with the server stopped) routes to the session
(36→41→36); backgrounded, the server is untouched — the two halves of
the *stopped* state.

**Foreground guard (D20) — implemented + unit-tested + PASS on the final
build.** With the server `play` the session reports `PLAYING`, so Android
*selects* it for volume keys; the pre-guard handler sent
`PUT /api/player/volume?step=` on every rocker event unconditionally and
would have driven server volume backgrounded while playing — a D20
violation. The fix, two layers:

- `mirror_handler.dart`: a `_appForeground` flag (conservative default
  `false` — a service-restarted process with no UI must not map rocker
  presses until it actually foregrounds), exposed via
  `setAppForeground(bool)` which re-publishes the playback info
  immediately so the session's volume-control type follows the app
  without waiting for the next player change. The session is published
  with the pure `volumeControlTypeFor(foreground)`:
  `AndroidVolumeControlType.absolute` foregrounded (rocker routes to the
  session), `fixed` backgrounded (the session is taken out of volume-key
  selection — the phone's keys do their normal thing). Second layer:
  `androidAdjustRemoteVolume`/`androidSetRemoteVolume` no-op while
  `!_appForeground`, closing the transition window where a key event
  could still arrive for a session the system was just deselecting.
- `main.dart`: `_AppForegroundTracker extends WidgetsBindingObserver`
  forwards `didChangeAppLifecycleState` (`resumed` ⇔ foregrounded) to
  the handler; `_initAudio` seeds the flag with the current lifecycle
  state at handler creation.

Unit tests: `test/rocker_foreground_test.dart` (9) pins the guard —
`volumeControlTypeFor` mapping; backgrounded rocker raise/lower and
`androidSetRemoteVolume` issue **no** `PUT` and leave the server volume
unchanged; backgrounded session publishes `fixed` (max 100, current
volume); foregrounded rocker raise→+5 / lower→−5 / same→no-op and
`setVolume` lands as `?volume=`; the session publish flips
`fixed→absolute→fixed` with the flag, and backgrounding again
re-arms the no-op.

**Backgrounded-`play` non-interference — PASS (supervised, user present,
final build, Pixel 6).** Procedure per the rescoped criterion: play
(user-approved) → background + screen off → rocker (server must not move)
→ foreground → rocker (server moves ±5) → pause/verify → restore `stop`,
`volume=36`. All server state read via `GET /api/player` after each step.

| t | step | evidence |
|---|---|---|
| 18:37:29 | restart app under `flutter run` (final build), auto-connect | log `auto-connecting to 192.168.1.13:3689` |
| 18:40:38 | connect lands (first attempt at 18:37:35 hit a transient timeout; Retry from the error screen) | log `connecting → connected` |
| 18:41:0x | baseline (server stopped) | `stop, volume=36, item_id=196174` |
| — | foreground session check | `dumpsys media_session`: the OwnTone session `volumeType=REMOTE, controlType=ABSOLUTE, max=100, current=36` — foreground ⇒ absolute, as the guard intends |
| 18:45:00 | **play (user-approved supervised)** via app transport button | — |
| 18:45:03 | verify | `state: play, volume=36` |
| 18:45:3x | **background the app** (`KEYCODE_HOME`) + **screen off** (`223` SLEEP) | `dumpsys power`: `mWakefulness=Dozing` |
| 18:45:35→37 | **rocker UP (backgrounded, screen off, server PLAYING)** | `state: play, volume=36` — **server volume unchanged** |
| 18:46:14→16 | **rocker DOWN (backgrounded, server PLAYING)** | `state: play, volume=36` — **still unchanged** |
| 18:46:4x | **foreground** the app (`KEYCODE_WAKEUP` + `am start`) | `mCurrentFocus=…MainActivity` |
| 18:46:44→46 | **rocker UP (foregrounded, server PLAYING)** | `state: play, volume=41` — **+5, foreground mapping works** |
| 18:46:4x | **pause immediately** (end of supervised window) | `state: pause, volume=41` |
| 18:56:2x | restore: `PUT /api/player/volume?volume=36` then `PUT /api/player/stop` | `stop, volume=36, item_id=196174` — **byte-identical to the pre-window baseline** |

This is the D20 contract, all three forms, on the final build:
foreground (server stopped) maps 36→41→36; backgrounded (server stopped)
leaves 36 alone; and the critical **backgrounded while `play`** case —
where Android *would* select the playing session for the volume keys —
leaves the server volume untouched while the foreground rocker still
moves it. Non-interference is proven on the exact path the guard exists
to close.

### Criterion 4 — PASS (2026-10-22, supervised, user present)

`RemoteDev_API_36` (emulator-5554, windowed), app under `flutter run`,
connected (`phase=connected, ws=open, ver=29.3`). Ran **before C3** in
the same window, per the unit order. All times local; server state read
via `GET /api/player` after each step.

| t | step | evidence |
|---|---|---|
| 12:53:21 | baseline verified | `stop, volume=36, item_id=196174` (pre-window) |
| 12:53:32 | `debugGlobals['player'].play()` (user-approved play) | — |
| 12:53:41 | verify | `state: play`, item 196174, progress 5540 ms |
| 12:53:53 | **user pause**: `player.pause()` | — |
| 12:54:02 | verify | `state: pause` |
| 12:54:20 | `adb -s emulator-5554 emu gsm call 5551234567` → OK | app log `call state: ringing` |
| 12:54:23 | verify while ringing | still `state: pause` (app did not claim the user pause) |
| 12:55:06 | `gsm cancel 5551234567` → OK — **46 s of ringing**, far beyond the 500 ms flap window, so the call was unambiguously confirmed | app log `call state: idle` |
| 12:55:09 | verify | **still `state: pause`** — no auto-resume of a user-caused pause |

### Criterion 3 — PASS (2026-10-22, supervised, user present)

Continued in the same window from the C4 end state (server `pause`).

| t | step | evidence |
|---|---|---|
| 12:55:57 | `player.play()` | — |
| 12:56:09 | verify | `state: play` |
| 12:56:25 | `gsm call 5551234567` → OK | app log `call state: ringing` |
| 12:56:29 | verify (~4 s after the call; the pause lands ~0.5 s after the flap-confirmed ringing + LAN latency) | **`state: pause` — auto-pause** |
| 12:56:47 | `gsm cancel 5551234567` → OK | app log `call state: idle` |
| 12:56:50 | verify | **`state: play` — auto-resume** |
| 12:57:00.9 | **immediately** `player.pause()` (per procedure) | — |
| 12:57:10 | verify | `state: pause` (total unattended-play exposure ≈ 11 s, supervised) |
| 12:57:23 | restore: `player.stop()` | — |
| 12:57:33 | verify | `stop, volume=36, item_id=196174` — **byte-identical to the pre-window baseline** |

### Incidents

1. **mdfind/Spotlight hang (3rd occurrence):** `flutter build apk
   --debug` stalled with an empty log and an
   `mdfind kMDItemCFBundleIdentifier="com.google.android.studio*"` child
   (pid 91242). Killed the child per the documented recipe; the build
   then completed (~20 s Gradle).
2. **`AndroidVolumeDirection` is not an enum (dev-time, self-inflicted):**
   audio_service 0.18.19 defines it as a class with `static final`
   instances (`AndroidVolumeDirection._(int)`), so switch
   expressions/cases over its values fail analysis
   (`constant_pattern_with_non_constant_expression`). Rewrote
   `rockerStepFor` with `==` comparisons. Cost one build cycle.
3. **Shared netsimd wedge + clogged adb server (2026-10-22):** the dev
   AVD's guest→LAN path hung completely (ping *hangs*, nc times out)
   while Mac↔server stayed perfect and guest→host-loopback worked. The
   wedge persisted across an emulator restart (fresh slirp, same shared
   `netsimd` pid 96752) — the netsimd had started at ~10:28 in the same
   second as the other session's emulator. `emu kill` then clogged the
   adb server (`adb devices` hung 120 s); `adb kill-server` +
   `start-server` recovered it, and both the Pixel 6 and the other
   session's emulator (`emulator-5556`) reattached fine. After the
   restart + adb server restart, guest→LAN worked immediately. If the
   AVD loses its LAN again, suspect the shared netsimd first.
4. **Pixel 6 app-egress block (2026-10-22, ~11:00–16:40, resolved):**
   see the Criterion 1 findings — every third-party-app TCP connection
   (any non-loopback destination) timed out with no kernel socket ever
   created, while shell/GMS/Mac were fine. The device had run the setup
   wizard ~09:24 (fresh reset). **Resolved when the user unplugged and
   re-plugged the device (~16:40)** — app egress worked immediately.
   Lesson: on this device, that symptom class is fixed by a USB reseat.
   (A one-off transient connect timeout recurred at 18:37:35 and
   cleared on Retry — noted in the C1 transcript.)

### Findings

1. `AndroidVolumeDirection` (audio_service 0.18.19) is a class with
   `static final` instances, not an enum — `==` comparisons only.
2. **adb touch to the Flutter window works again** (2026-10-13) — the
   unit-002 broken-touch symptom did not recur on a fresh boot of
   `RemoteDev_API_36`.
3. The call auto-pause lands **~500 ms after the flap-confirmed
   ringing** — C3 transcript: `gsm call` 12:56:25 → `state: pause` by
   12:56:29 (the 4 s check window includes my verify latency).
4. **On the Pixel 6, uiautomator sees only empty `View` nodes for the
   Flutter app** (no semantics text), whereas the 2026-10-13 AVD dumps
   carried labels — drive that device via `evaluate_expression` tree
   walks instead. `Element.visitChildren` visits only *one* level
   (write a recursive walk); `WidgetsBinding.instance.rootElement` is
   nullable in the synthetic scope. **Superseded for label reading on
   2026-10-22:** `main.dart` now calls
   `WidgetsFlutterBinding.ensureInitialized().ensureSemantics()`, and
   the Pixel 6 dumps carried full `content-desc` labels (the C1
   procedure used them).
5. **A bare `am start` of the debug APK exposes a VM service but no
   compilation service** — `evaluate_expression`/hot reload need the app
   under `flutter run`.
6. `adb shell input text`/taps did not deliver to the Flutter form on
   the Pixel 6 despite correct coordinates (verified via
   `localToGlobal`); setting the `EditableText` controllers' `text` and
   invoking the button's `onPressed` via `evaluate_expression` worked
   instantly.
7. **The now-playing transport `IconButton`s carry no semantics label**
   (2026-10-22): with `ensureSemantics()` on, the top-bar/settings/volume
   nodes all expose `content-desc`, but the play/pause/next/prev row is
   icon-only with no `tooltip`, so uiautomator sees only bounds — the C1
   supervised play was driven by tapping the big center button's bounds
   (`456,1833–624,2001`). Accessibility gap for a future unit (icon
   buttons need tooltips / semantic labels).

### Environment at close (2026-10-22)

Server: `stop`, `volume=36`, `item_id=196174`, shuffle/repeat/consume
off; queue untouched — byte-identical to the pre-window baseline
(12:53:21). Last playback was the supervised C1 window (18:45:00–
18:46:4x, ≈ 47 s, user present), restored at 18:56:2x.
`RemoteDev_API_36` (emulator-5554) killed at session end. Pixel 6
`25071FDF600953`: lock screen disabled, final debug build installed and
running under `flutter run` (log `/tmp/pixel6_flutter_run4.log`),
connected to `192.168.1.13:3689`, config + permissions persisted. The
other session's emulator (`Pixel_9_Pro_API_36`, emulator-5556, headless)
was running untouched. Final gates on the D20 code: analyze 0 / format
43 files 0 changed / 140/140 / build ✓.
