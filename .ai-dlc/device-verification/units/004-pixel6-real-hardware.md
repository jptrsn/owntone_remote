---
name: 004-pixel6-real-hardware
status: done
intent: device-verification
supervised_steps: [2, 5]
---

# Unit 004 — real-hardware pass on the Pixel 6 (release build)

Closes what dv-003 could only approximate on an emulator: the
real-hardware list in `docs/RELEASE-NOTES.md` § "Device gate". Device is
the **Pixel 6 (`25071FDF600953`, oriole)** — THE test device (user
decision 2026-11-14). No AVDs are created or touched by this unit.

## Scope decisions (user, 2026-11-16, asked at session start)

| dv-003 untested item | Decision this unit |
|---|---|
| 1. Real carrier call (R-08) | **No real call available** — device carries a Videotron SIM (`gsm.sim.state=LOADED`) but voice is OUT_OF_SERVICE (CS DENIED, no IMS/VoWiFi registered). User: *"accept AVD test results for this test, we do not need to verify on a real device with a real phonecall if emulated test passes."* → R-08 stays covered by the dv-001/dv-003 emulated-Telecom passes (the real `TelephonyCallback` path); a real carrier call stays on the untested list. Re-run the emulated call row on real hardware is **not possible** (no emulator-Telecom layer on a physical device; real RIL unreachable) — recorded as an approximation note, not re-run. |
| 2. GrapheneOS per-app Network permission | **Declined** — flashing wipes THE test device; user: *"We do not need GrapheneOS specific tests."* Stays on the untested list. |
| 3. GrapheneOS battery-optimisation specifics | **Declined** (same decision). No-GMS crash-free bonus rides on the same flash → stays untested too. |
| 4. What stock-Android real hardware (device at Android 17 — see build record) CAN close | FGS + notification survival backgrounded with screen off under the **real** battery manager/firewall; cold-start auto-reconnect; **volume rocker on real hardware** (R-06 — key injection on a device with a real volume-stack); media-key control while backgrounded. All with evidence rows. |

## Oracles (AGENTS caveats re-confirmed this session)

- uiautomator a11y bridge dead on the Pixel 6 (re-verified: dump → 0 text
  nodes while the app is foreground).
- Release builds have no VM service → on-screen **text** oracles run in a
  **debug build via `flutter run` + `evaluate_expression`** (unit-012
  procedure) on the same device, same code; the release build is then
  reinstalled (`install -r`, debug-signed both) and every check below is
  evidenced by **server API truth + `dumpsys` + `ss`** (no UI-text claim
  is made from the release binary without such a quote).
- Audio safety (AGENTS §1): baselines in `/tmp/dv004/`
  (`player_start.json`, `outputs_start.json`, `queue_before.json`);
  `GET /api/player` re-verified `state==pause` immediately before any
  start; each audible start individually confirmed with the user in the
  session; outputs used: **Volumio Kitchen (AirPlay)** only (Chromecast
  un-selectable server-side). End: outputs + queue byte-identical to
  start (diff), master volume restored, `state==pause` verified.
- Screen-awake policy: `svc power stayon true` at unit start (as-found
  `stay_on_while_plugged_in=0` — restored at the end). The screen-off
  survival step explicitly turns the screen off (`keyevent 26`) — with
  the FGS active the per-uid firewall (SESSION-LOG 2026-10-26 item 2,
  observed without an FGS) must not starve the WS; `ss` proves it.

## Device / build record

- `adb devices -l` → `25071FDF600953 … product:oriole model:Pixel_6`
  (verified via `getprop`: model `Pixel 6`, release `17` (SDK 37),
  device `oriole`, serial `25071FDF600953` — matches AGENTS table;
  AGENTS says Android 16, device has since OTA'd to 17 — recorded).
- No emulator attached this session (`adb devices` shows only the
  Pixel 6); emulator-5554 untouched.
- Toolchain: Flutter 3.47.9 / Dart 3.13.7 (host == CI pin).
- Release APK: `flutter build apk --release` on HEAD `de1a627` →
  `app-release.apk` 54.6 MB (Gradle 31.1 s). **Debug-signed** (accepted
  status, `buildTypes.release` debug signing config).

## Steps

1. Install the release APK (`install -r`), record `dumpsys package`
   version + runtime-permission rows.
2. `supervised: true` — debug-build UI-oracle pass (same device): VM
   semantics walk proves the harness reads known-present on-screen text;
   tap Connect → `sync: live` / `Playing via:` chips; one user-confirmed
   play via the app's own Play button → server `state==play` → pause via
   the app button → `pause`. Records the proven Play/Connect coordinates
   the release phase reuses. Ends the `flutter run`.
3. Release-build cold-start auto-reconnect (R-01): `am force-stop` →
   start → established sockets to `:3688` (WS) + `:3689` (HTTP) owned by
   the app uid; media notification present; no process restart thrash.
4. Volume rocker on real hardware (R-06): app foregrounded (`mCurrentFocus`
   checked) → `input keyevent 24` ×5 and `25` ×5, server volume
   step-verified per press-batch (step = 5, R-14 default), original
   volume restored + verified. Backgrounded-inert row: HOME, ×5 presses →
   server volume unchanged.
5. `supervised: true` — FGS + notification survival on real hardware
   under the real battery manager: (offer lower volume) user-confirmed
   Play tap → background (HOME) → screen off (`keyevent 26`,
   `mWakefulness=Asleep`) → **10 min** → t+10 m: same pid,
   `dumpsys activity services` `isForeground=true`, notification present
   with actions, `ss` WS still established (firewall check), server
   still `play` advancing; media-key (`keyevent 126`) pause/resume while
   backgrounded (server-verified); crash buffer clean. Then wake, app
   pause control (or media key) → `pause`, restore volume (and player
   item if the queue still anchors it), re-verify `state==pause`.
6. `supervised: true` — emulated-call approximation note (no re-run on
   real hardware, per scope decision): cite dv-001 + dv-003 evidence +
   the R-08 unit tests; record the device's telephony state verbatim as
   the reason a real call is BLOCKED. *(Executed read-only — the on-
   device re-run was found impossible and no audio step occurred, so
   nothing here ran under supervision; frontmatter lists only steps 2
   and 5.)*
7. Update `docs/RELEASE-NOTES.md` device gate: record the dv-004
   stock-Android real-hardware pass + the 2026-11-16 user decisions on
   items 1–3 (call-path emulated-accepted; GrapheneOS checks declined);
   keep the three items explicitly on the untested list.

## Completion criteria

1. Release APK (this run's HEAD, debug-signed — noted) installed;
   permissions dumpsys-quoted.
2. On-screen text oracles from the VM pass (harness proven on
   known-present labels first); user-confirmed app-initiated play →
   server transition quoted; server left paused after.
3. Cold-start auto-reconnect: `ss` rows show app-uid WS to `192.168.1.13:3688`
   after force-stop+start, no user action.
4. Rocker on real hardware: ±5×5 server-verified, volume restored to
   as-found; backgrounded presses inert (server unchanged).
5. FGS survival: 10-min backgrounded **screen-off** on real hardware —
   same pid, `isForeground=true`, notification + actions present, WS
   established (firewall withstood), media-key control works, 0 crashes;
   server restored (volume, outputs byte-identical, queue
   byte-identical, `state==pause`; any external-session delta
   documented, not stomped).
6. Checks 1–3 recorded with the user's exact decisions; untested list in
   `docs/RELEASE-NOTES.md` updated accordingly.
7. `svc power stayon false` restored; no AVDs created; `flutter run`
   ended; gates green (analyze/format/test + `flutter build apk`) +
   SESSION-LOG entry + commit `device-verification/004: …` + PR +
   agentic review to a full pass.

## Result

**Status: DONE — real-hardware pass complete (2026-11-16, supervised
window, user present; every audible start individually confirmed).**
Three of the four closable items on scope-table row 4 **PASS** on the
Pixel 6 with the release build — FGS + notification + WS survival
screen-off, cold-start auto-reconnect, volume rocker (incl.
backgrounded-inert) — while its fourth sub-item, **media-key control
while backgrounded, is BLOCKED-HARNESS** (shell media-button injection
is dead on this device — `input keyevent 126/87` inert, `cmd
media_session` no-op; the app side is evidenced correctly registered
via `dumpsys media_session`, and backgrounded notification-control
coverage stands on dv-003's AVD shade tap; see step 5). Checks 1–3 are
**BLOCKED** by user scope decisions taken at session start (below),
each with the exact reason and no substitution.
Zero app-attributed audio incidents; server restored to the as-found
baseline (external-session deltas documented, not stomped). No AVDs
created; `adb devices` before/after showed only `25071FDF600953`
(the other session's emulator-5554 was not on the bus and was untouched).

**HEAD `de1a627`**; Flutter 3.47.9 / Dart 3.13.7 (host == CI). Release
APK `flutter build apk --release` → **54,626,682 B (54.6 MB)**, Gradle
31.1 s. **Debug-signed** — `buildTypes.release` still uses the debug
signing config (accepted status, per release-notes limitation; also what
made `install -r` over the debug phase possible). Gates on this run:
analyze **0 issues** · format **0 changed** (93 files) ·
`flutter test --exclude-tags live` **427/427** · release APK ✓ (above) ·
debug APK ✓ (via `flutter run`).

**Device identity (re-verified, AGENTS §2):** `getprop` →
model `Pixel 6`, device `oriole`, serial `25071FDF600953`,
`ro.build.version.release=17` / `sdk=37` — **AGENTS table says Android
16; the device has since OTA'd to 17** (recorded here; the pass ran on
17). `dumpsys package`: `versionName=0.1.0`,
`lastUpdateTime=2026-11-16 10:10:40`; runtime permissions
`POST_NOTIFICATIONS / ACCESS_LOCAL_NETWORK / READ_PHONE_STATE` all
`granted=true`.

### Baseline (start)

```
GET /api/player:  state=pause volume=73 item_id=200387 item_progress_ms=85378
                  shuffle=true repeat=off consume=false
GET /api/outputs: Volumio Kitchen (AirPlay 1) selected vol 73;
                  Server (ALSA) unselected vol 8; all Chromecasts unselected
GET /api/queue:   1665 items (first: 'Don’t Let the Green Grass Fool You',
                  'Old Man', 'Exploding/Reloading', 'Carmen', 'To the Top')
```

Snapshots `/tmp/dv004/{player,outputs,queue}_start.json`.
`svc power stayon true` set (as-found `stay_on_while_plugged_in=0` —
restored at the end, verified `0`).

### Step 2 — debug-build UI-oracle pass (supervised): PASS

Harness first (AGENTS "suspect your harness"): `uiautomator dump` on the
foregrounded app → **0 text nodes** (a11y bridge dead, re-confirmed this
session); screenshots are unreadable in this stack (no model image
input) → oracles = **VM `evaluate_expression`** (debug `flutter run`,
pid 15394) + server API. The VM walk **proved the harness on
known-present labels** before any absence was trusted: on-screen text
`Playing via: Volumio Kitchen | Queue · 1665 | Library | Modern Times |
The Black Keys · Magic Potion | 01:25 | 04:21 | 73 | OwnTone Remote |
OwnTone 29.3 | sync: live` — cross-matching `/api/player` (prog
85378 = 1:25, length 261874 = 4:21, vol 73), outputs (Volumio Kitchen)
and queue count (1665).

Procedure deviation, recorded: the planned **Connect tap was not
exercised** — the launch auto-connected (logcat `ws: none → open` at
boot) from persisted settings and the connect screen was not reachable
(the full-screen text oracle above shows home-screen content — chips,
now-playing, `OwnTone 29.3`, `sync: live` — not the connect form), so
only Play coordinates were captured (the release phase reuses exactly
those). The connect-screen tap path itself is
unit-tested (`connection-settings` suites) and evidenced on-device by
dv-001/dv-003.

Supervised play #1 (user confirmed "Play 'Modern Times' at volume 15"):
volume→15 (paused) → pre-tap GET `pause vol 15 item 200387 prog 85378`,
`mCurrentFocus=MainActivity` → **tap (541,1916)** → server `play prog
85788` (correct item resumed) → same tap → `pause prog 93319`. Volume
restored 73. `flutter run` ended; app force-stopped; release APK
reinstalled.

Harness facts (for future device units — all cost time here):
- **Do not cap widget-tree depth in `evaluate_expression` walks** —
  Flutter trees exceed depth 110; a `d>110` guard produced a phantom
  "0 interactive widgets" tree. Uncapped walk: 977 elements, 133
  interactive hits.
- `s.substring(0,40)` **throws on shorter strings** — swallowed by
  try/catch it silently empties text oracles (looked like "app renders
  no text"); use `s.length>n?s.substring(0,n):s`.
- Transport row (logical px ×2.625 = physical): prev 126 / **play 206**
  / next 286 @ y 730 → Play tap = physical **(541,1916)** (used by both
  phases). Chips row @ y 141; rating stars @ y 561; volume slider @
  (206,646).
- Engine-side `rootSemanticsNode` yields nothing without an a11y tap;
  the **widget-side** `Semantics`/`RenderParagraph` walks are the text
  oracle. `input keyevent` coords are physical px; tap scale ×2.625
  confirmed.

### Step 3 — cold-start auto-reconnect (release build, R-01): PASS

`am force-stop` → `ss -tn | grep 192.168.1.13` → **no sockets** →
`monkey … LAUNCHER 1` (no user interaction) → **+8 s**:

```
ESTAB 192.168.1.148:56726 → 192.168.1.13:3689   (×3, initial refetch)
ESTAB 192.168.1.148:48942 → 192.168.1.13:3688   (websocket)
pidof → 16164
```

(ss process column unavailable to non-root; the app is the only actor
for that IP — socket set was empty at force-stop.) Auto-reconnect from
persisted settings, no re-entry: PASS. Procedure sub-checks not quoted
above, honestly noted: "media notification present" was **not captured
at this cold start** (the player was `pause`; the notification record
is quoted at step-5 t0 — `id=1124` — once the service had served
playback, per `audio_service`'s design); "no process restart thrash" is
carried by the single stable pid **16164** across steps 3 → 5 including
the whole 10-min survival window (no respawn between launch and
t+10 min).

### Step 4 — volume rocker on real hardware (R-06/R-14): PASS

Foreground (`mCurrentFocus=…MainActivity`), paused: `input keyevent 24`
×5 → server volume **73→98 (+25 = 5 presses × step 5, R-14 default)**
on real volume-stack key events; `keyevent 25` ×5 → **98→73** (exact
restore). Backgrounded-inert row (R-06 invariant): HOME
(focus=`NexusLauncherActivity`) → 24 ×5 → volume **held 73** — never
hijacks server volume from the background, now on a real device.

### Step 5 — FGS + notification survive 10 min backgrounded, screen off, real hardware (supervised): PASS; media-key-control sub-row BLOCKED-HARNESS

Pre-play: `repeat=single` (pins the item against auto-advance during the
window — restored after), volume 15, pre-tap GET `pause vol 15 item
200387 prog 93319`, crash buffer cleared. User confirmed "play 10 min
at volume 15". Tap (541,1916) → `play prog 93899` → HOME → `svc power
stayon false` + `keyevent 26` → **`mWakefulness=Dozing`** (the real
power manager's screen-off sleep state — what the AVD check could only
approximate). **Honest scope:** `dumpsys deviceidle` held
`mState=ACTIVE mLightState=ACTIVE` (quoted in the battery note below),
so battery-Doze (deviceidle IDLE) never engaged — 10 min on USB is far
short of its timers. The survival claim covers screen-off + per-uid
firewall + the real battery stack, **not** deviceidle IDLE.

| Check | t0 = 11:05:24 | t+10 min = 11:15:47 (+623 s) |
|---|---|---|
| screen | `mWakefulness=Dozing` (`dumpsys power`) | `mWakefulness=Dozing` (still off) |
| process | pid **16164** | pid **16164** (no restart) |
| FGS | `isForeground=true foregroundId=1124 types=0x00000002` (mediaPlayback), `infoAllowStartForeground … uidState: TOP; code:PROC_STATE_TOP; startForegroundCount:1` | `isForeground=true … types=0x00000002` |
| notification | `id=1124 flags=NO_CLEAR\|FOREGROUND_SERVICE category=transport actions=3 MediaStyle importance=2` (`dumpsys notification`) | re-dumped: `dumpsys activity services` still carries the foreground record — `foregroundId=1124 foregroundNoti=Notification(… flags=NO_CLEAR\|FOREGROUND_SERVICE … actions=3 MediaStyle)` — and `dumpsys notification --noredact \| grep -c 'pkg=dev.educoder'` → **2** |
| websocket | `ESTAB …:42110 → 192.168.1.13:3688` **with `mWakefulness=Dozing`** | `ESTAB …:42110` (same socket — per-uid background firewall NOT tripped; SESSION-LOG 2026-10-26 item 2 starvation did not occur with an FGS. t+10 `procState` not captured; the app was backgrounded with the screen off throughout, and audio kept advancing server-side, so the socket was genuinely live) |
| server | `play prog 116479` | `play item 200387 prog 215550` (audio kept playing; repeat-single held the item) |
| crash buffer | cleared | `logcat -b crash \| grep -c educoder` → **0** |

Media-key control while backgrounded — **harness finding, app exonerated**:
`input keyevent 126`×2 and `87` with screen off did **not** reach the
session (server kept advancing), and `cmd media_session dispatch
pause|play` no-oped (dv-003 parity). `dumpsys media_session` proves the
app side is correctly registered: `ownerPid=16164, active=true, flags=7,
actions=3669759, mediaButtonReceiver=…/MediaButtonReceiver,
state=PLAYING, metadata="Modern Times, The Black Keys, Magic Potion",
volumeType=REMOTE current=15`. Shell media-button injection is the dead
path on this device (and `input tap` on the shade/lockscreen was
unverifiable — no image oracle), so **backgrounded control on THIS
device is BLOCKED-HARNESS**; the app side is exonerated (registration
quoted above) and the control-path coverage stands on: dv-003's release
notification-shade tap (**AVD**) + **this device's release-build in-app
transport taps (app foregrounded — not backgrounded control)**, both
directions: Play tap → `play prog 93899`, pause tap (after wake:
`keyevent 26`, keyguard dismissed via `keyevent 82`, no PIN) → `pause
item 200387 prog 127452`; the restore GETs (~15–30 s later) confirmed
`pause` held (85355 after the restore seek).

Restore after window: `repeat=off`; `seek?position_ms=85378` → server
holds **85355** (stable 23 ms quantization across two attempts — well
inside R-03's ±1 s acceptance and inside the release notes' ≤50 ms
seek-accuracy prose; note the two bars differ — REQUIREMENTS.md R-03
says ±1 s, the RELEASE-NOTES "what works" row says ≤50 ms; a docs
reconciliation nit, not this unit's call); volume → 73. **Player start↔end diff: only
`item_progress_ms 85378→85355`.** `outputs` and `queue` (1665 items):
**byte-identical** (diff clean).

External-session interference (shared server, documented not stomped —
AGENTS §4): after the verified restore, `GET /api/player` twice showed
`play` — `play vol 73 item 200387 prog 110195` (the post-restore
cleanup check, ~11:18 — clock inferred from the t+10 stamp) and
`play prog 89185` (5 s after the restore re-seek) — the **other active
session** re-resuming the same item in ~25 s / ~4 s audible bursts at
vol 73 while **my app was force-stopped** (`ss` → 0 sockets to the
server), i.e. not app-attributed (2026-10-26 shared-server precedent).
Re-paused each time per AGENTS §1 — quoted: `re-paused: pause vol 73
item 200387 prog 125920` (`still: pause prog 125920` on a 3 s hold) and
`final check: pause vol 73 item 200387 prog 117073` — and left position
further untouched (my anchor restore had completed at window end; the
residual progress drift is the other session's). Handoff: `pause vol 73
item 200387 prog 117073` @ 11:21:24; the re-pause was the last player
write from this unit — post-handoff state belongs to the other session.

### Step 6 — checks 1–3 (untested-list closure attempts): BLOCKED per scope decisions

- **Check 1 — real carrier call (R-08): BLOCKED-NO-SIM-SERVICE.** The
  device does carry a SIM (AGENTS "no SIM" is stale): `gsm.sim.state=
  LOADED`, `gsm.operator.alpha=Videotron` — but voice cannot register:
  `dumpsys telephony.registry` → `mVoiceRegState=1(OUT_OF_SERVICE)`,
  CS `registrationState=DENIED availableServices=[EMERGENCY]` (LTE +
  UMTS cells, Videotron/PRTNR), IWLAN **data-only**, `mIsEmergencyOnly=
  true`, `mCallState=0` → no inbound call can reach the device. SIM or
  working line was not supplied at session start. **User decision
  (2026-11-16): accept the emulated coverage** — *"we do not need to
  verify on a real device with a real phonecall if emulated test
  passes"*. R-08 evidence stands as dv-001 + dv-003 emulated-Telecom
  passes (real `TelephonyCallback` path, user-confirmed audible) +
  R-08 unit tests. Real carrier call **stays on the untested list**.
  Re-run via the emulator-Telecom equivalence is **not possible on a
  physical device** (no `emu gsm call` console on hardware; real RIL
  unreachable) — recorded as an approximation note, not re-run.
- **Check 2 — GrapheneOS per-app Network permission:
  BLOCKED-DECLINED.** Flashing GrapheneOS wipes THE test device; user
  decision 2026-11-16: *"We do not need GrapheneOS specific tests."*
  Item stays on the untested list; the RELEASE-NOTES setup steps remain
  documentation, not GrapheneOS-verified procedure.
- **Check 3 — GrapheneOS battery-optimisation specifics:
  BLOCKED-DECLINED** (same decision). The no-GMS crash-free bonus rides
  on the same flash → **stays untested** (stock Pixel 6 ships GMS; no
  GMS-less-OS observation possible without flashing).
- **Check 4 — closable stock-hardware rows: PASS** (steps 3–4, and
  step 5 with its media-key-control sub-row **BLOCKED-HARNESS**).

Battery note (stock, feeds the release-notes README line):
`dumpsys deviceidle` `mState=ACTIVE mLightState=ACTIVE` during the
window — battery-Doze IDLE never engaged (10 min, on USB); the
`mediaPlayback` (types=0x2) FGS carried audio + websocket through the
10-min **screen-off (`mWakefulness=Dozing`)** window on the real
battery manager with no battery-optimisation whitelist required.

### Environment at handoff

Release 0.1.0 installed + force-stopped (notification state after
force-stop not dumped — process death is terminal for the session);
`svc power stayon` restored (settings value `0`, as found); screen awake
(as found); `/sdcard` temp files removed; no AVDs created or touched;
`flutter run` ended; server `pause vol 73 item 200387`, outputs + queue
byte-identical vs start (player: 23 ms seek-quantization delta +
documented external re-resumes).

### Agentic review (criterion 7)

Round 1 (two parallel reviewers: process/ai-dlc compliance + evidence
integrity): both **request-changes**. Findings taken: "all four PASS"
overclaimed the media-key sub-row (→ BLOCKED-HARNESS); "real Doze"
contradicted the unit's own `deviceidle ACTIVE` quote (→ reworded to
`mWakefulness=Dozing`, IDLE never engaged — propagated to
RELEASE-NOTES/AGENTS/SESSION-LOG); RELEASE-NOTES RC header still named
the `926a6be` build (→ updated to this `de1a627` build); t+10
notification cell + step-3 sub-checks now carry quotes/honest gaps;
R-03 ±1 s vs release-notes ≤50 ms prose flagged; re-pause quotes added.
Not taken (evidenced rationale in-file): post-hoc rewording of the
pre-declared completion criteria 3/5 (goalpost-moving avoided — the
Result carries the honest labels). Round 2: re-review of the fixed
bytes by the same reviewers — result recorded at merge time by the
merging session.
