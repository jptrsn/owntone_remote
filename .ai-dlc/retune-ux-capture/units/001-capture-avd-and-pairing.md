---
name: 001-capture-avd-and-pairing
status: pending
intent: retune-ux-capture
supervised_steps: [3]
---

# Unit 001 — capture AVD + ReTune install + user pairing

## Goal

A booted `Retune_API_33` AVD with ReTune installed and **paired by the
user** to 192.168.1.13, library screens showing real data, server paused.

## Steps

1. Device isolation: `adb devices -l` — never touch `emulator-5554`.
2. Download the image (one-time, ~1.5 GB):
   ```sh
   ~/Library/Android/sdk/cmdline-tools/latest/bin/sdkmanager \
     "system-images;android-33;google_apis;arm64-v8a"
   ```
3. Create + boot the AVD:
   ```sh
   ~/Library/Android/sdk/cmdline-tools/latest/bin/avdmanager create avd \
     -n Retune_API_33 -k "system-images;android-33;google_apis;arm64-v8a" -d pixel
   ~/Library/Android/sdk/emulator/emulator -avd Retune_API_33 &
   adb wait-for-device
   ```
   Record the serial in AGENTS.md's device table.
4. Record the device facts:
   `adb -s <s> shell getprop ro.build.version.release` (expect 13).
5. Install ReTune:
   ```sh
   adb -s <s> install tools/retune/Retune_3.5.23_APKPure.apk
   adb -s <s> shell pm list packages | grep -i retune   # record package name
   ```
6. Launch ReTune, verify it opens (screencap) — **do not touch playback
   controls**.
7. **`supervised: true` — user pairing pause point.** Hand to the user:
   they add the server (192.168.1.13) in ReTune's connect/pairing flow and
   complete the PIN exchange. The agent may guide screen-by-screen
   (screencap + tell the user what to tap) but the user performs the
   pairing. Agent must not tap ReTune's play controls at any point.
8. Verify pairing: ReTune's library screens show real data (screencap +
   `uiautomator dump` of the main screen into
   `docs/retune-capture/00-paired-verification/`).
9. Verify server paused:
   ```sh
   curl -s -X PUT http://192.168.1.13:3689/api/player/pause
   curl -s http://192.168.1.13:3689/api/player   # state == pause
   ```
10. Save a snapshot so the paired state survives reboots:
    `adb -s <s> emu snapshot_save paired`

## Completion criteria

1. AVD created, booted, serial recorded in AGENTS.md; Android version
   recorded.
2. ReTune installed; package name recorded in `## Result`.
3. `supervised: true` — user confirms pairing complete; library data
   visible (evidence: 00-paired-verification captures).
4. Server verified paused (evidence: curl output).
5. Snapshot `paired` saved (evidence: `adb -s <s> emu snapshot_list`).

## Result

*(fill: serial, Android version, package name, pairing evidence, snapshot
name, incidents if any)*
