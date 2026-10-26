---
name: 001-dev-avd-full-pass
status: pending
intent: device-verification
supervised_steps: [1]
---

# Unit 001 — full requirements pass on the dev AVD

## Goal

Run **every** v1 R-ID acceptance criterion (REQUIREMENTS.md, final) on
a **dedicated AVD created by this unit** and record a pass/fail table.
This is the gate before any release build.

## AVD lifecycle (user instruction 2026-10-26)

Other sessions run emulators on this host (`emulator-5554`,
`emulator-5556` — HANDS OFF), so this unit does **not** reuse
`RemoteDev_API_36` (not running) and never starts an existing AVD. It
creates its own and destroys it afterwards:

```sh
SDK=~/Library/Android/sdk
$SDK/cmdline-tools/latest/bin/avdmanager create avd -n OwnToneVerify_API_36 \
  -k "system-images;android-36;google_apis_playstore;arm64-v8a" -d pixel_6
# run it; resolve its OWN serial (serials shift with other emulators):
$SDK/emulator/emulator -avd OwnToneVerify_API_36 >/tmp/owntone_verify_emu.log 2>&1 &
adb wait-for-device shell getprop ro.boot.qemu.avd_name  # must print OwnToneVerify_API_36
# ... all `adb`/flutter work uses -s <that serial>, never a remembered one ...
adb -s <serial> emu kill    # THEN: avdmanager delete avd -n OwnToneVerify_API_36
```

The unit is not done until the AVD is deleted and `adb devices -l`
shows no `OwnToneVerify` entry. (Physical Pixel 6 `25071FDF600953` stays
available for the checks an AVD can't do — real output routing, rocker —
per REQUIREMENTS; it is not a substitute for the AVD pass.)

## Steps

0. Create + boot the dedicated AVD (above); `flutter build apk --debug`.
1. `supervised: true` (one window): walk every R-ID in order on the
   AVD; play-touching criteria (R-04 play path, R-06 rocker-while-
   playing, R-08, R-09 audio, R-11 play, R-12 mutation) happen inside
   this window with per-action confirmation; the window **ends with the
   server paused + verified**. Criteria that need the physical device
   (rocker, output routing) run on the Pixel 6 in the same window.
2. Record a table in `## Result`:

   | R-ID | Criterion | Result | Evidence (ref/timestamp) |
   |---|---|---|---|

3. Failures → new work: open a fix unit in `remote-app` (or a new
   `bugfix-*` intent if it's cross-cutting), re-run the failed criterion
   only, update the table. Do not move on with known failures.
4. `flutter build apk --debug` + `--release` both succeed; record the
   release APK path (do not ship it to the Pixel 10 yet — unit 003).

## Completion criteria

1. Table complete: every v1 R-ID × every acceptance criterion has a
   pass/fail row with evidence.
2. Zero unexplained failures (each fail → linked fix unit or accepted
   limitation with user sign-off).
3. Debug + release APKs built (evidence: build output tails).
4. Server left paused (evidence: final `/api/player` state).
5. Dedicated AVD **deleted** and no `OwnToneVerify` device left attached
   (evidence: `avdmanager list avd | grep -c OwnToneVerify` → 0 and
   `adb devices -l` tail).

## Result

*(fill: the table, build outputs, accepted limitations, incidents)*
