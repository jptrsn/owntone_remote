---
name: 001-dev-avd-full-pass
status: pending
intent: device-verification
supervised_steps: [1]
---

# Unit 001 — full requirements pass on the dev AVD

## Goal

Run **every** v1 R-ID acceptance criterion (REQUIREMENTS.md, final) on
`RemoteDev_API_36` and record a pass/fail table. This is the gate before
any release build.

## Steps

1. `supervised: true` (one window): walk every R-ID in order on the dev
   AVD; play-touching criteria (R-04 play path, R-06 rocker-while-
   playing, R-08, R-09 audio, R-11 play, R-12 mutation) happen inside
   this window with per-action confirmation; the window **ends with the
   server paused + verified**.
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

## Result

*(fill: the table, build outputs, accepted limitations, incidents)*
