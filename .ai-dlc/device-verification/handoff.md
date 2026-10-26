---
session_ended: "2026-10-26T16:30+02:00"
hat: "verify"
unit: "device-verification/001-dev-avd-full-pass"
bolt: 1
reason: "user_stop (handoff to fresh session)"
---

## Where We Left Off

`remote-app` is COMPLETE (units 001–006 + follow-up `ef17cfc`, all
committed on `main`, nothing pushed). Unit 001 of `device-verification`
is `pending` and NOT started — nothing has been walked yet. The last
commit was the row-numbers removal; the debug build from it is installed
on the Pixel 6 and a `flutter run` session is attached (VM
`ws://127.0.0.1:61307/MmNZTR1IIdY=/ws`, log
`/tmp/flutter_run_006c.log`) — safe to kill and start fresh.

## What's Working

- Gates green on HEAD: analyze 0 · format 0 · `test --exclude-tags live`
  321/321 · `build apk --debug` ✓ (debug APK only; `--release` never
  built — unit 001 criterion 3 needs it).
- Server 192.168.1.13 left exactly at handoff state, twice this session:
  `stop`, queue 185 items / version 1739 byte-identical to
  `/tmp/ot006/queue_snapshot.json` (first 'Skunk'), Volumio Kitchen the
  only selected output. All touched ratings at originals:
  track 1764=20, 1195=60, 1765=20 (re-verify before trusting).
- The supervised-window protocol works: master volume 0 during
  play-touching checks, `pause` + GET-verify before every
  play-capable tap, snapshot/restore for the queue.
- UI oracle that works on the Pixel 6: `flutter-agent-lens` connected to
  `flutter run`'s VM + `evaluate_expression` walking `Semantics`/`Text`
  widgets (chunked returns, 128-char cap). Screenshots save but are
  unreadable by this model — use text evidence.

## What's Not Working

- **uiautomator dump is dead** on the Pixel 6 (empty window after the
  app backgrounds; relaunch/hot-restart/settings toggles all failed —
  don't burn time reviving it; use the VM semantics walk).
- lens `hot_reload` fails after an app relaunch (needs `flutter run`'s
  compiler state — use `flutter run`'s own `r`, or restart the run
  session); lens `console_logs` buffers nothing after relaunch — use
  `evaluate_expression` returns, not `print()`.
- **Device isolation is strict:** `emulator-5554`/`emulator-5556` belong
  to other sessions (HANDS OFF) and `RemoteDev_API_36` is not running.
  **User decision 2026-10-26: unit 001 creates its own AVD
  (`OwnToneVerify_API_36`, android-36 google_apis_playstore arm64-v8a,
  pixel_6 profile) and deletes it when finished** — never boot or reuse
  an existing AVD. Resolve its serial by `getprop
  ro.boot.qemu.avd_name` at boot; serials shift when other emulators
  start. Unit file "AVD lifecycle" has the exact commands. Physical
  Pixel 6 `25071FDF600953` remains for the checks the AVD can't do
  (rocker, real output routing).
- Device gotchas: `svc power stayon true` must be on (screen-off Doze
  blocks the app uid via the firewall); taps are physical = logical ×
  2.625; two `KEYCODE_BACK` from root EXIT the app (check
  `dumpsys window | grep mCurrentFocus` after nav batches).
- Shared server: the other session advances the player mid-window —
  re-GET `state` immediately before every play-capable tap, and
  `playback=start` from *pause* sometimes no-ops (observed on this box).
- Chromecast outputs fail to select server-side; only **Volumio
  Kitchen** and **Server (ALSA)** are reliable for R-09 routing checks.

## Immediate Next Steps

1. Confirm the supervised window with the user (they must be present,
   ears on). Then create the dedicated AVD per the unit's "AVD
   lifecycle" section (never touch existing AVDs/emulators).
2. Before anything: `adb devices -l` + `getprop ro.boot.qemu.avd_name`
   to re-verify serials (AGENTS.md device table), then
   `curl $BASE/api/player` (expect `stop`; pause if not).
3. Build debug + **release** APKs first (no supervision needed), record
   output tails.
4. Walk R-IDs from `docs/REQUIREMENTS.md` in order into the Result
   table (`| R-ID | Criterion | Result | Evidence |`); non-play
   criteria any time, play-touching ones (R-04, R-06, R-08, R-09, R-11,
   R-12) only inside the supervised window, per-action confirm.
5. End: server `pause` + verified (unit's own exit state — NOT stop,
   unlike previous units' handoff), Ratings restored for any R-12
   mutation, queue snapshot/restore, AVD killed + **deleted**,
   SESSION-LOG entry, commit `device-verification/001: <why>`, rename
   this file to `handoff-2026-10-26.md`.

## Important Context

- Hard rules 1–6 in AGENTS.md are non-negotiable; unit 001's exit state
  is **paused** (its criterion 4) — that's deliberate and differs from
  the `stop` prior sessions left.
- Tests are derived from REQUIREMENTS.md and cite R-IDs — the table
  rows can cite passing widget/unit tests as *supporting* evidence but
  the criterion must be *observed on the device*.
- Known follow-ups (don't mix into 001 unless a criterion forces it):
  artwork 204→no-image filter; re-test `playback=start`-from-pause on a
  private server.
- This repo's ai-dlc flavor is lightweight: unit files' `## Result` is
  the evidence store, `docs/SESSION-LOG.md` is the narrative, commit
  per unit, never push.
