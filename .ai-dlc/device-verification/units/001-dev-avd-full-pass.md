---
name: 001-dev-avd-full-pass
status: done
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

Run 2026-10-26, 18:1x–19:5x local. Device: dedicated AVD
`OwnToneVerify_API_36` (android-36 google_apis_playstore arm64, pixel_6
profile), created + booted by this unit, serial resolved at boot by
`getprop ro.boot.qemu.avd_name` → `emulator-5558`. Server
`192.168.1.13:3689` (shared — see Incidents). Physical Pixel 6
`25071FDF600953` for the foreground-rocker check (dropped off adb later
in the window — the backgrounded check was then re-run on the AVD, see
R-06). App: `dev.educoder.owntone_remote` debug build,
POST_NOTIFICATIONS + READ_PHONE_STATE granted.
Primary oracles: uiautomator content-desc dumps (rows/labels), VM-service
`evaluate_expression` on `debugGlobals` (state), `GET /api/*` (truth).

### Gate rows

| Gate | Result | Evidence |
|---|---|---|
| `flutter analyze` | PASS | 0 issues (`/tmp/dv001_gates.log`) |
| `dart format --set-exit-if-changed` | PASS | 0 changed |
| `flutter test --exclude-tags live` | PASS | 321/321 |
| `flutter build apk --debug` | PASS | `build/app/outputs/flutter-apk/app-debug.apk` (189.9 MB) |
| `flutter build apk --release` | PASS | `build/app/outputs/flutter-apk/app-release.apk` (52.6 MB — not shipped; unit 003) |
| AVD created by unit | PASS | `avdmanager create avd -n OwnToneVerify_API_36 … -d pixel_6`; needed `disk.dataPartition.size=8192M` (host free disk). Never an existing AVD; hands-off emulators untouched |
| AVD deleted, none attached | PASS | `avdmanager delete avd -n OwnToneVerify_API_36` → "AVD 'OwnToneVerify_API_36' deleted."; `ls ~/.android/avd | grep -i verify` empty; `adb devices -l` → no devices |
| Server left paused + verified | PASS | final `GET /api/player`: `state: pause`, `item_progress_ms` frozen across +2 s, `volume: 0`; outputs `[Volumio Kitchen]` (per-output 0; Server unselected, vol 8) == session baseline; queue 185/185 content-identical to `/tmp/dv001/queue_snapshot_start.json`; ratings verified at originals (2419 Fury=20, 1195=60, 1764=20, 1765=20) |

### R-ID acceptance table

| R-ID | Criterion | Result | Evidence (local time) |
|---|---|---|---|
| R-01 | valid host connects; specific errors (DNS vs refused vs 401) | PASS | `Host "does-not-exist.invalid" could not be resolved (DNS).` / `Connection to 192.168.1.13:3690 was refused — is the server running there?` verbatim on the connection screen; valid host → connect + state load (`OwnTone 29.3`, `sync: live`) |
| R-01 | server state loads after connect | PASS | header + now-playing populated from `/api/player`/`/api/outputs` without interaction |
| R-01 | relaunch reconnects without re-entry | PASS | force-stop + launcher relaunch → `sync: live` again, host/port prefilled (`192.168.1.13`/`3689` read back from EditableText probe). **401 branch N/A** — server has no auth (`config.needs_auth_key: false`); accepted limitation (harness) |
| R-02 | external change → app UI + notification ≤ ~2 s | PASS | external volume change → slider followed +1.55 s; external `PUT /api/player/next` from paused → nowPlaying title 'House Party'→'Cowboys' in +1.74 s (VM-polled) |
| R-02 | WS disconnect → backoff reconnect | PASS | offline phase `connected → offline`, `ws: open → reconnecting`, retry banner 'Server unreachable — retrying.' |
| R-02 | reconnect → full refetch | PASS | `WS reconnected — full refetch` log line + stale slice 12→44 items refreshed |
| R-02 | WS failure never blocks REST | PARTIAL (harness) | no root on the Play image to kill the socket while REST lives; state machine keeps REST enabled in `offline` + covered by unit tests (connection_controller) — accepted with user sign-off per §harness |
| R-03 | all fields render; relative artwork + maxwidth; placeholder | PASS | nowPlaying `House Party/Thundersmack/Brass`; artwork `Image` URL `http://192.168.1.13:3689/artwork/item/1193?maxwidth=600` (webroot-resolved, maxwidth applied); `204`-artwork track renders placeholder (cache-manager logs the 204 as an exception — cosmetic, follow-up candidate) |
| R-03 | progress tracks server | PASS | elapsed text + slider advanced with `item_progress_ms` while playing |
| R-03 | seek ±1 s | PASS | drag → `PUT /api/player/seek`; target 105 600 ms → server 105 576 ms (**Δ24 ms**) from paused |
| R-03 | no viewport overflow | PASS | 0 overflow lines in the flutter-run log at 1080×2400 + viewport widget tests |
| R-04 | app controls hit right endpoints | PASS | play button → `play` + audible 'Skunk' (user-confirmed 19:08); pause → `pause`, progress frozen (34560×2); next/prev from paused moved item 196760↔196761/2 staying `pause` |
| R-04 | notification controls | PASS | action taps on the shade: Play → `play` +1 s; Next → entry advances ×2 staying `pause` (silent); dumpsys: `actions=3`, `android.title=String (Skunk)`, `android.text/subText` = artist/album |
| R-04 | lock screen / MediaSession | PASS | `dumpsys media_session`: session active, `PlaybackState {state=PLAYING(3)}`, `volumeType=REMOTE ABSOLUTE 35`, metadata `Skunk, Thundersmack, Brass`; media-key events (126/127 — the lock-screen/headset path) flipped server `pause→play→pause` |
| R-04 | controls work backgrounded | PASS | with focus on launcher: notification Play/Next taps + media keys all reached the server (call-window controls at 19:49 are the strongest case: pause-from-shade during a call, app backgrounded) |
| R-04 | notification reflects WS changes | PASS | title flipped with skips ('Blues in the Attic' while playing, verified via `--noredact` dump); no stale duplicates (count stayed 1) |
| R-05 | mode state + PUTs + server-confirmed UI + WS options events | PASS | shuffle/repeat(off→all→single→off)/consume toggled from the mode row; each verified via `GET /api/player` fields + `debugGlobals['player']` cache re-synced after WS `options` (no manual refresh) |
| R-06 | slider verified via API | PASS | drag → server `volume: 72` == app 72 |
| R-06 | foreground rocker ±5 | PASS | Pixel 6 foreground (earlier in session): 30→35→40→35 via `input keyevent` 24/25, server-verified exact ±5 |
| R-06 | backgrounded rocker must NOT move server volume — incl. while playing | PASS | AVD, app backgrounded (focus=launcher) while server `play`: 5× rocker presses → volume held 35, playback uninterrupted (19:47). Pixel 6 backgrounded-while-stopped earlier: held. (Pixel 6 dropped off adb mid-window — backgrounded-while-playing re-run on the AVD) |
| R-06 | volume WS → slider/notification sync | PASS | external `PUT /api/player/volume` (35→0 etc.) followed by slider + notification volume in <2 s; MediaSession `current=35` tracked server |
| R-07 | track + working controls in notification | PASS | see R-04 notification rows (title/text/actions + taps) |
| R-07 | process death while paused → recovery on relaunch | PASS | `run-as … kill -9` (debuggable) while paused → process gone, notification+service+session gone; launcher relaunch → notification re-posted (id 1124, NO_CLEAR\|FOREGROUND, actions=3), `AudioService` FGS running, MediaSession `PAUSED(2)`, UI `sync: live` + `Queue · 185` — the "recover on relaunch" branch. Note (documented here): `AudioService.onStartCommand` = `START_NOT_STICKY` (audio_service 0.18.18) → no *spontaneous* revival; the app-icon/auto-reconnect path is the recovery route |
| R-07 | no duplicate notifications after WS reconnect | PASS | `NotificationRecord … owntone_remote` count == 1 across offline→reconnect and after process-death relaunch |
| R-08 | simulated call → pause | PASS | `adb emu "gsm call 5551234"` (mCallState=1) while playing → server `pause` 30216 frozen; user confirmed audible stop at the ring |
| R-08 | call ends → auto-resume | PASS | `gsm cancel 5551234` → `play`, progress advancing (30726→32766); user confirmed audible resume |
| R-08 | user pause (not call-pause) is not resumed | PASS | call #2: user Play from the shade during the call, user Pause from the shade (200376) → call cancelled → **stayed `pause`** (+6 s re-verify) — the same `wasPlayingBeforeCall` suppression as a user-pause-before-call |
| R-09 | list matches server exactly | PASS | 10 rows w/ name/type/selected/volume == `GET /api/outputs` at same second |
| R-09 | toggle = one full-set PUT | PASS | checkbox toggle flipped selection via `/api/outputs/set` (single call — `outputs_controller_test.dart:193` asserts request shape); server selected [Kitchen]→[Kitchen,Server]→[Kitchen] observed |
| R-09 | per-output volume verified | PASS | slider 8→27→8 (earlier) + this window `output_id=0 volume=20`/`8` reflected in `GET /api/outputs`; note: per-output volume is `PUT /api/player/volume?output_id=` (NOT `/api/outputs/{id}?volume=` — the latter silently no-ops) |
| R-09 | PIN for protected outputs | N/A (harness) | no `has_password`/`needs_auth_key` outputs on this server; pin body param + dialog covered by tests — accepted limitation (user sign-off) |
| R-09 | output move while playing (guard, supervised — R-N7) | PASS | playing @vol 20: Server checkbox → guard dialog 'Server is playing / Moving outputs redirects live audio…' (Cancel/Continue); Continue → selected=[Kitchen,Server]; un-check Kitchen (guard again) → selected=[Server]; user confirmed audio moved Kitchen→server box speakers; restored [Kitchen] via guarded flow (19:53) |
| R-10 | documented endpoints per screen | PASS | library home → Playlists (13 smart, == server), Artists (217 total), Albums, Genres; Brass tracks total 33 == server; playlists/albums/genres render verified |
| R-10 | pagination past page 1, no duplication | PASS | Artists: 136 unique entries loaded (> 50, page-size), all ∈ server's 217, no dupes (set-diff) |
| R-10 | empty state | PASS | 'Recently Added' → 'This playlist is empty.' (not a blank list) |
| R-10 | offline state + recovery | PASS | server-unreachable → 'Server unreachable — retrying. Browsing disabled.'; on reconnect → connected/open |
| R-11 | list matches server; now-playing identifiable | PASS | row order == `GET /api/queue`; exactly one row `Skunk, now playing, Thundersmack · Brass` |
| R-11 | tap plays item (supervised) | PASS | queue row tap → `POST /api/queue/items/add?…&playback=start` → audible 'Blues in the Attic' (user-confirmed, ~19:05) |
| R-11 | clear + WS refresh | PASS | app 'Clear queue' → confirm dialog 'Clear the queue?' → server count 0 + screen 'The queue is empty.' (no manual refresh); restore re-rendered 13 visible rows incl. now-playing marker |
| R-12 | star == server value (floor(rating/20)) | PASS | all 13 Absolution album rows matched `GET` ratings (Hysteria 100→'5 stars' etc.); row `'<title>, <M:SS>, <N> stars'` + semantics 'Rating: N of 5 stars' |
| R-12 | setting persists (server truth) | PASS | Fury (2419): UI tap star-3 (InkWell hit-test at (818,2265)) → `GET /api/library/tracks/2419` → `rating: 60`; row → '3 stars'/'Rating: 3 of 5 stars' via WS |
| R-12 | mutation protocol | PASS | recorded 20 → set 60 → verified → restored via star-1 tap → `rating: 20` verified (19:27–19:31); originals re-verified at session end (1195/1764/1765 unchanged) |
| R-13 | grouped results with correct pagination | **PASS** (re-run by fix unit remote-app/007, 2026-10-26 ~21:1x — originally FAIL, no search UI existed) | own unit AVD `OwnToneVerify_API_36` (created + deleted by 007): query `the` → headers `Tracks · 466` / `Artists · 32` / `Albums · 111` == `/api/search` totals; *Load more (tracks)* appends server page 2 — built rows map to server page-index window 13→27 **strictly increasing (no dupes, no gaps)**, artists 17→29; per-group wire shape `GET /api/search?type=<t>&query=…&offset=25&limit=25` (tests assert); rows = shared `BrowseRow` labels `title, artist, M:SS, N stars`, `track N` audit 0 hits. Evidence: `.ai-dlc/remote-app/units/007-search.md` § Result + `/tmp/u007_g*.xml`/`.png` |
| R-13 | empty query / no-results states handled | **PASS** (re-run by fix unit remote-app/007) | empty query → `Type to search the library.` with **zero** `/api/search` requests on the wire; `zzzqqq` → `No results for "zzzqqq".` (distinct node + text — never the idle hint); all-groups-fail → `Could not load search results.` + Retry (never reads as no-results; tests); offline-search → `Waiting for the server…`. Evidence: `/tmp/u007_e2_idle.png`, `/tmp/u007_h2_noresults.png`, unit 007 Result |
| R-14 | settings persist / apply — server + rocker step | **PASS** (re-run by fix unit remote-app/008, 2026-10-27 — originally partial: step const + no About) | own unit AVD `OwnToneVerify_API_36` (created + deleted by 008): host/port persist + prefilled + auto-reconnect (original R-01 evidence); **step configurable & applies to the next keypress, no restart** — Settings −/+ row (`content-desc "Volume rocker step"`/`"1"`/`"10"`, dumps `/tmp/u008_09_step1.xml`,`_10_step10.xml`), live server **volume-only** (`pause` re-verified before every press, never any playback): vol 30 → keyevent 24×3 = +1/press (31/32/33), step=10 same session → 32→42→32 (+10); **persisted across `am force-stop`+relaunch** (step 3 dump `_14_afterrestart.xml`; restored 5 dump `_19_final_step.xml`); restored to default 5 + vol 0 (API-verified, server left byte-identical). R-06 guard re-checked: backgrounded at step 3, keyevents inert (vol 0). Evidence: `.ai-dlc/remote-app/units/008-settings-extras.md` § Result |
| R-14 | About screen with server version | **PASS** (re-run by fix unit remote-app/008) | Settings → About row (`content-desc "About␊App and server versions"`): renders `OwnTone Remote` + `0.1.0+1` (compile-time const, `package_info_plus` deliberately absent — pubspec-drift-guard test) + `Server version␊OwnTone 29.3` + `Build options␊ffmpeg, Spotify, librespot-c, LastFM, Chromecast, MPD, Websockets, ALSA, Webinterface, Regex` from live `/api/config` (dump `/tmp/u008_15_about.xml`, screenshot `/tmp/u008_about.png`); row tap re-fetches (widget-test request-count assert — LAN re-fetch settles sub-frame, dump can't catch the spinner: harness limit); offline → `Could not reach the server.` + Retry, never stale (widget-tested) |

### Incidents (shared-server interference — not app behaviour)

- ×3 unattended player manipulations by the **other active session**
  (~19:10 resume-after-my-pause, ~19:12–14 resume + skips mid-test,
  ~19:35 stop). Each: re-paused via API within seconds and verified;
  audible moments were brief (~5–30 s of 'Skunk'/'House Party' on
  Kitchen at vol ≤35) with the user present in the supervised window.
  No app action caused them.
- Pixel 6 `25071FDF600953` disappeared from `adb devices` mid-window
  (19:46); backgrounded-rocker-while-playing re-run on the AVD instead
  (criterion still met). Pixel 6 was NOT needed for teardown.
- Queue baseline (`queue_snapshot_start.json`) survived two full
  clear→restore cycles (server versions 1929, 2115); content compared
  field-by-field to the snapshot both times.

### Harness notes (for the next verification run)

- `uiautomator` bridge dies often; `pkill -f uiautomator` + retry loop
  (≤3) before each dump; a dump taken while an overlay/shade is open
  silently returns the *previous* file — collapse overlays first
  (`cmd statusbar collapse`).
- Outputs rows are whole-row `CheckBox` nodes whose lower half is the
  slider — tap the checkbox in the title strip (~row top +45 px), not
  the row middle.
- Queue restore: `POST /api/queue/items/add?uris=…&clear=1` must be a
  real POST (urllib `data=b''`, `method='POST'`) with unencoded commas;
  GET/body-form variants 400. ~185-item adds take >20 s server-side
  (client timeout is expected — poll `GET /api/queue`).
- Emulator call drop: `adb emu "gsm cancel <number>"` (not `gsm call -h`).
- `debugGlobals` (lib/main.dart) + `PlayerController.nowPlaying` were the
  reliable state oracle; transport buttons have no content-desc — use the
  known coords (330/540/750 @1917) after `popUntil(root)` (offscreen
  routes also measure their widgets — don't trust un-popped walks).
