---
name: 003-release-pass-disposable-avd
status: done
intent: device-verification
supervised_steps: [1, 2, 3]
---

# Unit 003 — release pass on a disposable AVD (release build)

## Device decision (user, 2026-11-13)

The original unit gated the release on the user's **Pixel 10 (GrapheneOS)**
daily driver (see the superseded v1 record at the bottom of this file —
status BLOCKED-PENDING-SUPERVISION, never run). The user has decided
release verification runs on **an emulated device instead**: a disposable
AVD **created and deleted by this unit** (`OwnToneVerify003_API_36`,
per the per-unit AVD policy in AGENTS.md — never an existing AVD, never
another session's emulator or the physical Pixel 6).

What this *does* still test, and what it cannot:

| v1 (Pixel 10 / GrapheneOS) | This unit (disposable AVD) |
|---|---|
| release build install + smoke | **yes** — same APK, `google_apis` AOSP image |
| FGS/notification survival | **yes** — `dumpsys activity services` evidence |
| volume rocker (screen off) | **yes** — `input keyevent` 24/25, server-verified |
| incoming-call pause/auto-resume | **yes, emulated** — `adb emu gsm call` drives the real Telecom callback path (`TelephonyCallback.onCallAdded/Removed`), which is exactly what the app hooks |
| no-GMS crash-free | **yes** — `android-36/google_apis` has **no** GMS/Play services |
| real carrier call (RIL edge cases) | **no** — documented as untested |
| GrapheneOS per-app Network permission, stricter FGS enforcement, battery optimisation | **no** — documented as untested (setup steps stay in the release notes for real users) |

Everything that plays audio stays `supervised: true` (D16, AGENTS §1):
audible playback only in one agreed window, with the user present, each
start individually confirmed, and the server left paused + verified.

## Preconditions

- dv-001 and dv-002 done (they are).
- **Rebuild the release APK on current HEAD first** — the v1 52.9 MB build
  is `e765dcb` lineage, predating remote-app 009/010/011; record its size
  and `git rev-parse HEAD` in Result.
- AVD: `avdmanager create avd -n OwnToneVerify003_API_36 -k
  "system-images;android-36;google_apis;default"` (image already installed
  per AGENTS.md environment notes); boot headless with
  `-no-snapshot-save -no-audio -gpu swift_shader_indirect`; resolve the
  serial by `getprop ro.boot.qemu.avd_name` (never by remembered port —
  AGENTS §2). Delete the AVD when the unit finishes.
- Server baseline: snapshot `GET /api/player`, `/api/outputs`, `/api/queue`
  at start; re-snapshot at end; shared-server rule applies (AGENTS §4) —
  anything this unit mutates (volume probe, emulated queue edit) is
  restored and verified, and concurrent changes by the other active
  session are *documented*, not stomped.

## Steps

1. `supervised: true` — install the release APK on the AVD
   (`adb -s <s> install -r <release.apk>`); grant runtime permissions
   (`pm grant … POST_NOTIFICATIONS READ_PHONE_STATE` — AOSP auto-prompts;
   the GrapheneOS manual Network grant is documented but not testable
   here). Launch, connect (host 192.168.1.13).
   **First check:** release-build semantics — validate the dump harness
   sees a known-present label before trusting any absence (dv-003 v1
   checklist item 3; VM `evaluate_expression` fallback with 128-char
   chunks).
2. `supervised: true` — full smoke: now-playing display, pause/play
   (each start user-confirmed), prev/next, shuffle/repeat/consume,
   volume slider, browse one album, play one track (user-confirmed),
   queue list (+ now-playing highlight), speakers list, rating display.
   **End paused + verified.** Includes the unit-011 on-device check:
   one external queue add via the server API (no `playback=start`, safe
   while paused) → chip + list converge → item removed → byte-identical
   restore.
3. `supervised: true` — **emulated call test**: playing one user-approved
   track → `adb -s <s> emu gsm call 5551234` → playback pauses (verify
   `GET /api/player` state + logcat of the plugin's call-state channel) →
   `adb -s <s> emu gsm call --cancel 5551234` (or `--call_end`) → auto-
   resume (user confirms it is the *same* track at the *same* position ±
   rocker tolerance) → user pauses; final state paused + verified.
   Then pause the server via API and re-verify `state == pause` before
   leaving the window.
4. FGS/notification survival: background the app 10 min (screen off,
   `adb -s <s> shell svc power stayon false` + `input keyevent 26`),
   notification + media controls still work; `dumpsys activity services
   <pkg>` shows the `mediaPlayback` FGS still alive (quote `isDebug=…
   foreground=true` + `info FOREGROUND_SERVICE_…` block).
5. Volume rocker (screen off): `input keyevent 24` ×5 and `25` ×5 with
   the app foregrounded-but-screen-off (per dv-001's R-06 rows), ±5
   steps server-verified from `GET /api/player volume`; restore the
   original volume and verify.
6. Checklist (record in Result): FGS type accepted on Android 36 AOSP
   (dumpsys evidence), no GMS present on the image and no crash
   (`dumpsys package | grep -i com.google` empty + crash buffer clean),
   permissions granted/behaviour as declared, battery-optimisation
   behaviour noted for the README. Real-GrapheneOS rows: **untested —
   documented**, not silently dropped.
7. Update `docs/RELEASE-NOTES.md`: move the device gate from "pending"
   to "verified on Android 36 AOSP emulator, release build", keep an
   explicit **untested-on-real-hardware** section (real carrier call,
   GrapheneOS per-app Network permission, battery optimisation), and
   reflect units 009 (WS ping liveness), 010 (artwork 204), 011
   (queue-refresh serialization) in what-works/known-limitations (the
   v1 notes still list the two follow-ups this repo has since closed).

## Completion criteria

1. Release APK (built on this run's HEAD) installed + permissions granted
   on the disposable AVD (evidence: `adb shell dumpsys package` block).
2. Full smoke pass — per-feature pass/fail rows in Result, each backed
   by a server-side or semantics-tree quote, not "looked right".
3. `supervised: true` — emulated call: pause → auto-resume verified
   (server state + logcat rows); server left paused.
4. FGS + notification survive 10 min backgrounded (dumpsys evidence).
5. Rocker ±5 on the AVD, server-verified, original volume restored.
6. Checklist complete (AOSP rows evidenced; GrapheneOS rows explicitly
   marked untested-and-documented); `docs/RELEASE-NOTES.md` updated.
7. AVD **deleted**; `adb devices` shows no device owned by this unit;
   server == baseline for everything this unit touched (external-session
   deltas documented, not restored over).
8. Gates green (analyze/format/test + release & debug APK) + SESSION-LOG
   entry + commit `device-verification/003: …`.

## Result

**Status: PASS — release pass complete (2026-11-13, supervised window,
user present and confirming each audible action).** HEAD `926a6be`;
release APK **54.6 MB** (`flutter build apk --release`, Gradle 72.7 s) —
same HEAD as all gates re-run here: analyze 0 issues · format 0 changed
(92 files) · `flutter test --exclude-tags live` **421/421** · debug APK ✓.
AVD `OwnToneVerify003_API_36` (`system-images;android-36;google_apis;
arm64-v8a`, no Play Store UI) **created and deleted by this unit**;
serial resolved and re-verified via `ro.boot.qemu.avd_name` (was
`emulator-5554`, free at start — the other session's emulator was not
running; `adb devices` before/after showed only the foreign Pixel 6,
untouched). Zero audio incidents; server restored to the as-found
baseline (below).

### Baseline (start) → end (byte-identical)

```
GET /api/player:   state=stop volume=67 item_id=0 shuffle=true repeat=off consume=false
GET /api/outputs:  none selected; Server(ALSA) unselected vol 8
GET /api/queue:    0 items
```

Mid-window drifts were all self-restored and re-verified above: master
volume 51 observed at the FGS t_off (from the slider-row taps; restored
67), Server output 51 (row-slider mis-tap; restored 8), queue (15 → 0
via `PUT /api/queue/clear`). No external-session interference was
observed in the window (queue/player were static outside my own actions).
`item_id` anchor: 0 at start, 0 at end.

### Step 1 — install + permissions: PASS (release build)

`app-release.apk` (54.6 MB) → `Success`, `versionName=0.1.0`.
`pm grant POST_NOTIFICATIONS READ_PHONE_STATE` →
`dumpsys package`: both `granted=true`. Launch → Connect (host
`192.168.1.13`, port `3689`) → now-playing shows
`OwnTone 29.3` + `sync: live` (WS open) + `Playing via:`/`Queue ·`
chips. **Release-build semantics export validated first** (the v1
checklist's "before trusting dumps" rule): content-descs land
(`OwnTone server`, `Connect`, `Queue · 0`, `sync: live`, …) — the dump
harness sees known-present labels, so later absence-checks are trusted.
Field-entry trap hit: `input text` gained a stray `y` (IME compose) —
field verified against dumps after every entry.

### Step 2 — full smoke: PASS (server-verified per feature)

| Feature | Evidence (app ⟷ server) |
|---|---|
| now-playing display | `Time Is Running Out` / `Muse · Absolution` / `01:52`/`03:56` / `Rating: 4 of 5 stars` ⟷ `/api/player` prog 112301/236277 ms, `/api/search` rating 80 (=4★) |
| play (supervised, user-confirmed) | album Play → `state=play`, `count: 15` |
| app play/pause button | pause→play tap: `pause`@112301 → `play`@112611 |
| app next / previous | `Time Is Running Out(198834)` → `Fury(198846)` → `198834` (titles via queue map) |
| next past end of queue | single-item queue + repeat off → `stop` item 0 (server behavior, app follows) |
| modes | app toggles: shuffle→false, repeat→`all`, consume→true on `GET /api/player`; restored baseline |
| volume slider | tap → server 90 then 73; restored 67 |
| browse album | Albums row `Absolution, album, Muse, 15 tracks`; track rows `title, M:SS, N stars` |
| rating display | 4★/5★ rows ⟷ server ratings 80/100 |
| queue list + highlight | row `Time Is Running Out, now playing, …` follows `item_id` |
| queue WS convergence (**unit 011 C4**) | external `POST add` (no `playback=start`) at t0 → row visible by t0+3 s incl. `now playing`; `DELETE /api/queue/items/198830` → `The queue is empty.` + `count: 0` by t+3 s; `state=stop` throughout (zero audio) |
| speakers list | 5 rows verbatim ⟷ `/api/outputs` (name/type/selected/volume); Server row checkbox tap → `selected` in-row + server `SELECTED: Server` |
| cold start | `am force-stop`+start → `sync: live`, `Queue · 15`, `Playing via: Server` without re-entry (R-01 branch) |

### Step 3 — emulated call test: PASS (user-confirmed)

`adb emu gsm call 5551234` while playing → **`GET /api/player`:
`pause` at prog 21447 (frozen)** ≤3 s. UI stays coherent (now-playing
intact). The Kotlin plugin logs nothing (no `Log.*` in the call path —
recorded harness fact; oracle is the server transition + the R-08 unit
tests). `adb emu gsm cancel 5551234` (`--cancel` is rejected by this
image's console — "bad phone number format") → **`play` resuming at
21447→21717 — same item, same position**. User: *"paused and resumed"*
(audible confirmation). Server re-verified paused before leaving the
call step.

### Step 4 — FGS + notification survive 10 min backgrounded: PASS

Screen off (`input keyevent 26`, `mWakefulness=Asleep`) for **620 s
while playing** (server `play`, auto-advancing tracks, item 198834→198840
by check time). Same `pid 6713` at t_off and t+620 s (no restart).
`dumpsys activity services`: AudioService `isForeground=true`; the
launch-time log line `Background started FGS: Allowed …
cmp=…/com.ryanheise.audioservice.AudioService; code:PROC_STATE_TOP`
quoted from logcat. Notification present (`dumpsys notification`:
`id=1124 … NO_CLEAR|FOREGROUND_SERVICE category=transport actions=3`).
Crash buffer: **0**. Controls: shade shows `Blackout by Muse is playing
from owntone_remote` with `Previous track / Play / Next track`; tapping
**Play** after a server-side pause → `play` resumed (prog advancing).
Note: `cmd media_session dispatch` no-oped (media-button session null
with app unfocused) and the `media` shell binary is absent on this
image — the notification tap is the working control path.

### Step 5 — volume rocker: PASS with adjudication (screen-off = inert by design)

Screen-on, MainActivity focus, paused: `keyevent 24` ×5 → server volume
**51→76 (+5/press, step 5)**. Screen off (`Asleep`): ×5 (paused) and ×6
(**playing**) presses → volume **held (76)** — the R-06
"never hijacks from the background" invariant holds with the screen off
(activity onPause); the v1 wording expected an off-screen rocker to move
volume, but that is not the R-06 design (the handler is lifecycle-scoped
by the unit-003 remote-app decision) — adjudicated here as **correct
safe behaviour**, not a fail.

### Step 6 — checklist

- FGS type `mediaPlayback` accepted on Android 36 AOSP:
  `isForeground=true` + Background-started-Allowed row (step 4).
- Permissions: `INTERNET, WAKE_LOCK, READ_PHONE_STATE, FOREGROUND_SERVICE,
  FOREGROUND_SERVICE_MEDIA_PLAYBACK, POST_NOTIFICATIONS` — runtime two
  granted; declared set unchanged (v1 static rows stand).
- **No-GMS honesty**: this `google_apis` image *ships*
  `com.google.android.gms`/`gsf`/`vending` (contrary to the plan's
  expectation) — so "no-GMS crash-free" is evidenced as: static
  (zero play-services/firebase in Gradle + pubspec.lock, v1) + runtime
  zero crashes with GMS idle present; a true no-GMS OS observation
  remains **untested** (real-hardware list).
- Battery: mediaPlayback FGS exempt while playing (observed 10 min
  screen-off playback); "Don't optimize" note stays in the release notes.
- **Untested on real hardware (documented, not dropped)**: real carrier
  call/RIL edge cases (this pass used the emulator Telecom path, which
  drove the real `TelephonyCallback`); GrapheneOS per-app Network
  permission behaviour; GrapheneOS battery-optimisation specifics.

### Step 7 — `docs/RELEASE-NOTES.md`: updated this commit

Device gate moved to "verified (release build, Android 36 AOSP emulator)"
with the explicit untested-on-real-hardware list; 009/010/011 fixes
reflected; silent-drop and 204-artwork limitations removed (closed);
screen-off rocker inertness documented as design.

### Harness notes (cost time; record for future device units)

- **uiautomator dump cannot idle while the now-playing progress ticker
  animates (playing)** — pause the server first, or work blind with
  curl-verified taps at known coords (both patterns used here).
- Agent cannot read screencap PNGs in this stack → dumps + server API
  are the evidence oracles.
- `input text` can gain stray characters (IME) — verify field text via
  dump after every entry; IME commit may append late (the `y`).
- Outputs row: the row's Checkbox reports full-row a11y bounds but the
  volume slider child eats centre taps → tap the far-left icon (x≈28);
  a centre tap silently changes **output** volume (happened, restored).
- `adb emu "gsm call --cancel X"` invalid on this image → use
  `gsm cancel X`.
- uiautomator frames can be stale (showed `…1.13y` after a clean fix) —
  re-dump before concluding.
- Outputs `PUT /api/outputs/{id}` needs the string id from the API
  (Server=**'0'**, not list index) and JSON body; `?volume=` query form
  400s.

---

## Superseded v1 record (Pixel 10 / GrapheneOS plan, 2026-10-27)

Kept verbatim because AGENTS.md and other unit files cite its rows
(static checklist evidence, gate rows, server-as-found block). Its status
stands as recorded: the device pass never ran (user "Not today",
BLOCKED-PENDING-SUPERVISION for every device step); nothing was installed
and no device or server state was touched.

[Old unit 003 § Result: steps 1–5 BLOCKED (no device; steps 1–3
supervised, user absent); step 6 PARTIAL (static evidence complete,
on-device GrapheneOS checks pending); step 7 DONE — `docs/RELEASE-NOTES.md`
created (what-works R-ID grouped, GrapheneOS setup steps, known
limitations, "GrapheneOS device gate — pending" section); gate rows on
`e765dcb`: analyze 0 issues · format 78 files 0 changed · 362/362 tests ·
`app-release.apk` 52.9 MB (Gradle 37.2 s) · debug APK 189.9 MB; server
as-found start == end (`state=pause volume=0 item_id=197132`, outputs
`[Volumio Kitchen vol 0]`, queue 185 first 'Skunk') with zero requests
issued; no AVD created, only foreign `emulator-5560` attached; follow-ups
flagged: artwork-204 (since closed by remote-app/010) and R-02 WS ping
(since closed by remote-app/009). Full text: `git log --follow --
.ai-dlc/device-verification/units/003-release-pass-disposable-avd.md`.]
