---
name: 003-release-pass-disposable-avd
status: in_progress
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

_(pending — run in progress)_

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
