---
name: 008-settings-extras
status: done
intent: remote-app
supervised_steps: []
---

# Unit 008 — rocker-step setting + About screen (R-14)

R-IDs: R-14 (the two pieces that were never built; host/port persistence
already verified). Opened by device-verification unit 001, which
recorded the R-14 partial as FAIL → this unit; the table rows are
re-run afterwards.

## Goal

1. **Volume-rocker step size** becomes a real setting: today
   `lib/src/audio/mirror_handler.dart:90` has
   `static const rockerStep = 5` with `TODO(R-14)`. Persist an int
   (1–10, default 5) like the host/port prefs, read it in the mirror
   handler, expose it in Settings with immediate effect (no restart).
2. **About screen with server version** (name/version, server version
   + buildoptions from `GET /api/config`, app version from
   `package_info_plus` or pubspec constant — prefer no new dependency
   if the config + a compile-time const suffice).

## Steps / notes

- Step change applies to the *next* keypress while foregrounded;
  backgrounded behavior is untouched (R-06 invariants — never mirror
  while backgrounded).
- About is read-only; tapping server version re-fetches `/api/config`
  (shows the offline error state if unreachable).
- Tests: step persistence + applied value in handler mapping (1→±1,
  10→±10, clamping); About renders config fields + offline state; use
  `test/fakes/`.

## Completion criteria

1. R-14 acceptance rows verified on-device (own per-unit AVD or free
   `RemoteDev_API_36`; never another session's emulator): step=1 →
   rocker ±1 and step=10 → ±10 on the live server **while foregrounded,
   server stopped or paused** (volume-only — no playback), restored to
   default 5 afterwards.
2. Gates green + debug build.
3. device-verification/001 table R-14 rows updated with the new
   evidence.
4. SESSION-LOG entry + commit `remote-app/008: ...`.

## Result

**DONE 2026-10-27** (opencode). Both pieces shipped; R-14 table rows
re-run PASS in `device-verification/units/001-dev-avd-full-pass.md`.

### What was built

1. **Rocker step setting (R-14).** `SettingsStore`: `rocker.step` pref
   (1–10, default 5, clamped on read *and* write). `MirrorAudioHandler`
   no longer holds a `static const` — it takes the store in the
   constructor and reads `rockerStep` **at keypress time**
   (`androidAdjustRemoteVolume`), so a Settings change applies to the
   next press with no restart. `SettingsScreen` gained the row
   `Volume rocker step` with −/+ buttons (tooltips `Decrease/Increase
   rocker step`, disabled at the bounds) persisting on every tap.
   R-06/D20 untouched: the foreground flag (`_appForeground`, fed from
   `main.dart`) still gates both volume overrides; backgrounded stays
   inert (regression-tested at a custom step).
2. **About screen (R-14).** `lib/src/ui/about_screen.dart`, reached from
   the Settings `About` row. Read-only: app name + version from
   `lib/src/core/app_info.dart` compile-time consts (`package_info_plus`
   **not** added — a test asserts `kAppVersion` mirrors pubspec.yaml, so
   the no-plugin decision can't silently rot), server `version` +
   `buildoptions` from `GET /api/config`, tap the server-version row to
   re-fetch, offline/unreachable → `Could not reach the server.` + Retry
   (never stale values presented as current).

### Criterion 1 — on-device (own per-unit AVD)

Disposable `OwnToneVerify_API_36` (android-36 playstore arm64, pixel_6,
`disk.dataPartition.size=8192M`), created + **deleted** by this unit;
serial resolved via `getprop ro.boot.qemu.avd_name` → `emulator-5554`
(never a remembered serial — the other session's `ZipCaptions_QA_API_36`
was attached at `emulator-5560` the whole time and never touched).
Volume-only throughout: server `pause` at every step (state re-verified
via `GET /api/player` before **every** keypress); zero
play/transport/track-row taps; no library/queue/outputs mutation.
`adb devices` after cleanup shows only `emulator-5560` (foreign).

| Check | Evidence |
|---|---|
| Server found-state baseline | `pause, volume 0, item_id 196947, item_progress_ms 183192` (curl, start and end — byte-identical, frozen) |
| Settings step control renders | dump `/tmp/u008_03b_connect.xml`: `Volume rocker step`, `Decrease rocker step`, `5`, `Increase rocker step`, `About␊App and server versions` (Flutter labels export as **content-desc**, not text — grep content-desc on AVDs) |
| step=1 → ±1 | vol set 30 via API; foregrounded (`mCurrentFocus=…owntone_remote…`); keyevent 24 ×3 → `volume=31, 32, 33`; 25 → `volume=32` (`/tmp/u008_09_step1.xml` value `1`) |
| step=10 → ±10 **same session** (immediate effect) | taps to `10` (`/tmp/u008_10_step10.xml`); 32 → keyevent 24 → `volume=42`; 25 → `32` |
| step=5 restored + default active | taps back to `5` (`/tmp/u008_18_step5.xml`); one keyevent 24 → `volume=5` from 0; then `PUT volume?volume=0` → 204, `volume 0` verified |
| persistence across restart | step=3 → `am force-stop` + relaunch → auto-reconnect → Settings dump `content-desc="3"` (`/tmp/u008_14_afterrestart.png/.xml`); restored 5 persists over a second force-stop+relaunch (`/tmp/u008_19_final_step.xml`) |
| R-06 regression guard at custom step | backgrounded (`mCurrentFocus=NexusLauncherActivity`) at step=3: keyevent 24+25 → server `volume: 0` unchanged, `state: pause`, progress 183192 unchanged |
| About renders config fields | dump `/tmp/u008_15_about.xml`: `OwnTone Remote`, `0.1.0+1`, `Server version␊OwnTone 29.3`, `Build options␊ffmpeg, Spotify, librespot-c, LastFM, Chromecast, MPD, Websockets, ALSA, Webinterface, Regex`; screenshot `/tmp/u008_about.png` |
| About server-version tap | row re-fetches; settled dump identical / never the error state (`/tmp/u008_16b_settled.xml`); the re-issued `GET /api/config` itself is proven by the widget test (request-count assert) — a LAN re-fetch settles within one frame, the on-device dump can't catch it (harness limit, like dv-001's WS probe row) |
| About offline state | widget-tested (never-connected → `Could not reach the server.` + Retry; server-dies-after-connect → error replaces values, Retry recovers) |

### Criterion 2 — gates

`flutter analyze` **0 issues** · `dart format --set-exit-if-changed`
**0 changed** · `flutter test --exclude-tags live` **362/362** (341 + 21
new: 5 store-clamp/persist, 4 handler custom-step incl. the R-06
inert-at-custom-step guard, 6 settings-screen, 6 about, 1 pubspec
drift-guard) · `flutter build apk --debug` ✓ (fresh `app-debug.apk`
installed on the AVD for the pass).

### Harness notes (new, cost time)

- Flutter semantic labels land in **`content-desc`**, `text=` stays
  empty on Flutter nodes (native dialogs use `text=`) — unit dumps must
  grep content-desc.
- The open-IME trap bit again exactly as unit 007 warned: the second
  field tap while Gboard was open re-hit the *host* field (both inputs
  concatenated). Recovery: focus field → `MOVE_END` → 30× DEL → type →
  `keyevent 4` + verify `mInputShown=false` **before** the next
  coordinate tap.
- Widget test: the About row sits below the 640-px test fold — a raw
  `tap()` silently misses (`warnIfMissed`); `ensureVisible` first.
- `pumpWidget` reuses a screen's `State` (initState won't re-read the
  store on a second pump in one test) — pump fresh State via a distinct
  widget `ValueKey` per pump.
- `ChangeNotifier.dispose` asserts on double-dispose — a test-level
  `late ConnectionController` shared across tests must be nullable +
  nulled in `tearDown`.

### Server exit state (unchanged from found)

`GET /api/player` → `{ "state": "pause", "volume": 0, "item_id":
196947, "item_progress_ms": 183192 }` (identical bytes at start and end);
outputs selected `[Volumio Kitchen]` (0); queue 185, first `Skunk`.
No incident: no playback was ever started (every keypress landed as
`PUT /api/player/volume?step=` while `state == pause`).
