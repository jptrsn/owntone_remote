---
name: 004-outputs-speakers
status: done
intent: remote-app
supervised_steps: [3]
---

# Unit 004 — outputs / speakers screen

R-IDs: R-09. Real server has 10 outputs (8× Chromecast, AirPlay 1, ALSA) —
this screen gets exercised for real. (2026-10-22: the AirPlay output is
**Volumio Kitchen** — "Office-Airsync" was unplugged; baseline =
Volumio Kitchen selected only. Live `GET /api/outputs` is authoritative.)

## Goal

Outputs screen per SCREENS.md: list (name, type, selected, volume),
multi-select enable/disable via **one** `PUT /api/outputs/set` with the
full selected id list, per-output volume (`PUT /api/player/volume?
output_id=`), PIN dialog for `has_password`/`needs_auth_key` outputs.

## Steps / notes

- `OutputsController`: holds `List<Output>`; toggle = compute new set →
  single `/outputs/set` (optimistic UI, rollback on 5xx); refetch on WS
  `outputs`.
- Type rendering: display the string as-is (server sends `AirPlay 1`,
  `Chromecast`, `ALSA` — parse defensively, unknown = plain text, no
  icon).
- PIN: dialog before enabling a protected output → `PUT
  /api/outputs/{id}` with `selected: true, pin: …`; wrong PIN → server
  error surfaced, output stays disabled.
- Guardrail: changing outputs while **playing** redirects live audio to
  other rooms → `supervised`. While paused: safe.
- Tests: selection-set math (toggle on/off, multi-select, empty set
  behaviour — ask the server, record the answer in Result), PIN flow
  (fake 4xx), type-string rendering.

## Completion criteria

1. List matches `GET /api/outputs` exactly (all 10, fields correct) on
   the dev AVD.
2. Toggling one output sends exactly one `PUT /api/outputs/set` with the
   full id list (evidence: captured request or log) — not N toggles.
3. `supervised: true` — full audio verification: while playing (user-
   approved), move output A→B: audio follows; `selected` flags correct
   after; restore original output set afterwards (evidence: final
   `/api/outputs` matches the pre-test state).
4. Per-output volume slider verified via `GET /api/outputs` (paused —
   safe).
5. PIN dialog appears for protected outputs (none on this server —
   verify with a unit/widget test against a fake output with
   `has_password: true`; note the live gap).
6. Gates pass.

## Result

**Status 2026-10-23 (supervised morning): all six criteria PASS; unit
done.** C1/C2/C4/C5 from the 2026-10-22 unattended pass; C3 completed
2026-10-23 with the user present (A→B move Volumio Kitchen ↔ Server/ALSA,
playing-guard dialog verified live as the in-product confirmation,
byte-identical restore). C3 surfaced a stale-cache guard anomaly →
hardened with `PlayerController.refreshState()` + regression test; gates
re-run green on the final code.

Baseline (verified before any work): server `stop, volume=36,
item_id=196174`; live output set = 10 outputs, **Volumio Kitchen
(AirPlay 1) selected only** (user unplugged Office-Airsync that day —
treated live `GET /api/outputs` as authoritative). Dev AVD
`RemoteDev_API_36` booted headless → serial `emulator-5556` (verified via
`ro.boot.qemu.avd_name`; the other session's `Pixel_9_Pro_API_36` had
taken `emulator-5554` — hands off, re-verified before any adb).
App under `flutter run` (debug, the path whose semantics reach
uiautomator on this AVD), auto-connected, `sync: live`.

### What was built

- `OwntoneApi`: `setOutputs(ids)` (one `PUT /api/outputs/set`, JSON body
  `{"outputs": [...]}`), `setOutput(id, {selected, volume, pin})`
  (`PUT /api/outputs/{id}` — the PIN path), `setOutputVolume(id, volume)`
  (`PUT /api/player/volume?volume=N&output_id=`).
- `OutputsController`: pure `selectedIdsAfterToggle` (server order);
  `toggle` / `enableWithPin` / `setOutputVolume` with the unit-002
  contract — optimistic apply → confirming refetch → rollback + typed
  `actionError`/`actionErrorSeq` on failure; `syncError` on refetch
  failure; actions no-op while disconnected.
- `OutputsScreen` (spec added to SCREENS.md "Outputs / speakers"): row =
  checkbox · name · type string as-is (no icons/parsing; unknown types
  display-only) · lock marker if protected · numeric volume label ·
  per-output slider (commit-on-release, drag-state per spike Finding 14);
  compound semantics label per row; empty/loading/offline/sync-error
  states; snackbar on failed action.
- **Playing-guard dialog (user decision 2026-10-22):** while server
  state is `play`, any *selection* change first shows "Server is playing
  — moving outputs redirects live audio. Continue?" (paused/stopped: no
  dialog; volume changes are never guarded).
- **Entry point:** the now-playing "Playing via: …" line is tappable
  (cast icon) → Outputs screen (shows "none" when no output is selected).
  The app bar was *not* extended — it overflows the 360-logical test
  viewport with a third icon (RenderFlex +9 px, caught by the unit-001
  viewport tests).
- `Output.copyWith` for optimistic row updates.

### Criterion 1 — list matches `GET /api/outputs` exactly — PASS

On `emulator-5556`, Outputs screen (two uiautomator dumps, list scrolled
between). Programmatic comparison of the 10 semantics rows
(`<name>, <type>, selected|not selected, volume N`) against the same-
moment `GET /api/outputs` JSON:

```
server: 10 outputs; app rows: 10
server order == app order: True
OK  ('Bathroom display', 'Chromecast', False, 50)  vs  ('Bathroom display', 'Chromecast', False, 50)
OK  ('Bedroom TV', 'Chromecast', False, 67)  vs  ('Bedroom TV', 'Chromecast', False, 67)
OK  ('James clock', 'Chromecast', False, 32)  vs  ('James clock', 'Chromecast', False, 32)
OK  ('June clock', 'Chromecast', False, 71)  vs  ('June clock', 'Chromecast', False, 71)
OK  ('Kitchen display', 'Chromecast', False, 50)  vs  ('Kitchen display', 'Chromecast', False, 50)
OK  ('Living Room TV', 'Chromecast', False, 50)  vs  ('Living Room TV', 'Chromecast', False, 50)
OK  ('Office mini', 'Chromecast', False, 51)  vs  ('Office mini', 'Chromecast', False, 51)
OK  ('Volumio Kitchen', 'AirPlay 1', True, 36)  vs  ('Volumio Kitchen', 'AirPlay 1', True, 36)
OK  ('Will clock', 'Chromecast', False, 50)  vs  ('Will clock', 'Chromecast', False, 50)
OK  ('Server', 'ALSA', False, 8)  vs  ('Server', 'ALSA', False, 8)
```

All 10, all fields, server order. Server stayed `stop` throughout.

### Criterion 2 — one `PUT /api/outputs/set` with the full id list — PASS

Evidence = captured requests from a mock OwnTone on the Mac
(`192.168.1.85:3690`, pure `dart:io`, logs method+path+query+body; the
app was pointed at it via the persisted-config file — run-as edit +
relaunch, config restored to `192.168.1.13:3689` afterwards and the
reconnect verified `sync: live` + `Playing via: Volumio Kitchen`):

```
23:23:00.559975 PUT /api/outputs/set body={"outputs":["m1","m2"]}   ← one toggle of m2 on
23:23:01.044347 GET /api/outputs                                    ← confirming refetch
```

No per-output selection PUT anywhere in the capture (the only
`/api/outputs/m2` line was my deliberate curl restore of a volume).
App UI agreed after the toggle (uiautomator: "Mock Two, Chromecast,
selected, volume 60").

**5xx rollback (same capture):** mock armed to 500 the next
`/outputs/set` (`PUT /mock/fail-next-set`):

```
23:24:52.764537 PUT /mock/fail-next-set
23:24:53.191803 PUT /api/outputs/set body={"outputs":["m1","m2","m3"]}  → HTTP 500
```

→ app checkbox rolled back to "Mock Three, … not selected" (uiautomator)
**and** the snackbar read `Outputs failed — server answered HTTP 500.`
(captured by dump 1.5 s later). Then, un-armed:

```
23:25:19.723346 PUT /api/outputs/set body={"outputs":["m1","m2","m3"]}  → 204
```

→ "Mock Three, … selected" in the app and on the mock. Bonus (stray
slider tap during navigation, left in the capture):
`23:21:02.392723 PUT /api/player/volume?volume=0&output_id=m2` — the
per-output volume endpoint shape, confirmed on-device.

### Criterion 3 — move output while playing — **PASS** (supervised, 2026-10-23 morning)

User present and explicitly confirmed the specific play actions.
**Environment change vs. the plan (user-directed, 2026-10-23):** all
Chromecast-type remote outputs **fail server-side when selected** (user
observation; confirmed live — a toggle to Kitchen display produced no
`selected` change on the server). So the second output for the A→B move
was the local **`Server` (ALSA)** output, per user instruction. The A→B
move is therefore Volumio Kitchen (AirPlay) ↔ Server (ALSA) — still a
real cross-output move of live audio.

**The playing-guard dialog (user decision 2026-10-22) was verified live
as the in-product confirmation** on the A→B enable step (see transcript:
`GUARD-DEBUG: state=play isPlaying=true` → dialog → Continue). This is
the supervised confirmation the criterion asks for.

Timestamped transcript (server = `192.168.1.13:3689`; AVD = `emulator-5556`;
app under `flutter run`):

```
09:27:07  pre-play verified: state=pause (user had paused 09:04); app play tapped
09:27:10  GET /api/player → state: play  (audio now on Volumio Kitchen)
09:28:20  Outputs → tap "Server" checkbox
          GUARD-DEBUG: state=play isPlaying=true   ← guard saw play
          dialog "Server is playing / Continue" → tapped Continue (774,1107)
09:28:22  GET /api/outputs → selected: ['Volumio Kitchen','Server']
          user ears: audio now on BOTH (AirPlay + ALSA) — move A→B in progress
09:53:16  tap "Volumio Kitchen" checkbox (deselect A)
          GUARD-DEBUG: state=play isPlaying=true → dialog → Continue
09:53:18  GET /api/outputs → selected: ['Server']
          user ears: "Server output only — move worked"  ← A→B confirmed
10:07:06  re-select "Volumio Kitchen"
          GUARD-DEBUG: state=play isPlaying=true → dialog → Continue (10:13:41)
          GET /api/outputs → selected: ['Volumio Kitchen','Server']
10:14:47  deselect "Server"
          GUARD-DEBUG: state=play isPlaying=true → dialog → Continue (10:15:09)
          GET /api/outputs → selected: ['Volumio Kitchen']  ← original set restored
          user ears: "Volumio Kitchen only — original state"
10:19:45  app pause  → GET /api/player → state: pause
10:22:35  app stop   → GET /api/player → state: stop, volume: 36, item: 196174
final     GET /api/outputs → byte-identical to pre-test baseline (see below)
```

**Byte-identical restore:** after the move, the `Server` (ALSA) selection
had synced Volumio Kitchen's per-output volume `36 → 8` (an OwnTone
side-effect of selecting a different output — see Incidents). Restored
Volumio Kitchen's volume to 36 via
`PUT /api/player/volume?volume=36&output_id=207183922776680` (HTTP 204),
then:

```
python: base==cur → True   # /api/outputs byte-identical to pre-test baseline
```

(Pre-test baseline `c3_baseline.json` captured 08:47:03 with the server
`stop`; final `c3_stopcheck.json` after the restore is byte-identical.)

**Supervised-play exposure:** ~3 play→pause brackets, each seconds long,
all user-confirmed; plus one incidental resume (see Incidents). Server
left `stop`.

**Guard anomaly found and fixed during C3** (this is why C3 took three
guard taps to surface the dialog): on the long-lived instance the guard
read a **stale non-playing state** while the server was actually playing,
so the dialog was skipped on the first two A→B toggles (server state was
correct; only the app's cached player slice lagged). A fresh app instance
behaved correctly, proving the guard logic itself was sound and the
failure was a stale-cache read. Hardened per the unit's "verify claims
against the live server" rule: the guard now calls a new
`PlayerController.refreshState()` (one-shot refetch of the player slice,
falling back to the cache only if the refetch is impossible) **before**
deciding, instead of trusting the cached slice. Regression test
`test/outputs_screen_test.dart` "stale cache (server plays, app never
told): refetch forces the dialog (2026-10-23 C3 regression)" drives the
fixture to `play` without a WS event so the cache stays `pause`, and
asserts the dialog still appears — it **fails without the fix**
(verified: reverted the guard → test failed; restored → passed).

### Criterion 4 — per-output volume (paused/stopped — safe) — PASS

Server `stop` throughout. Bathroom display (id `1814023484`, baseline
volume 50), Outputs-screen slider dragged via `input swipe` on the row's
SeekBar `[53,368][1017,494]`; after each commit, `GET /api/outputs`:

```
50 → 64 (drag to ~62% — track padding) → 51 → 46 → 49 → 50 (restored)
```

Endpoint shape on the wire (from the C2 capture): `PUT
/api/player/volume?volume=0&output_id=m2`. Final `GET /api/outputs`
**byte-identical** to the pre-test baseline JSON. (Calibration note: the
M3 slider track insets make adb `input swipe` end-x → value
non-obvious; ~0.11–0.14 volume/px, `.round()` at commit — irrelevant to
the app, only to the test rig.)

### Criterion 5 — PIN dialog — PASS (live gap noted)

Widget + controller tests against a fake with `has_password: true`
(`test/outputs_screen_test.dart`, `test/outputs_controller_test.dart`):
enabling a protected output opens "PIN for \<name\>" with the Unlock
button enabled only once text is entered (regression: the button's
enabled-state must rebuild on `onChanged` — found and fixed on-device-
equivalent in the widget test); unlock sends `PUT /api/outputs/{id}`
with `{"selected": true, "pin": "1234"}` and **never** `/outputs/set`;
cancel sends nothing; a 4xx (wrong PIN) leaves the output disabled and
surfaces `Unlock failed — server answered HTTP 400.`
**Live gap:** none of the 10 real outputs has `has_password` or
`needs_auth_key` (verified in the Criterion 1 capture), so the live PIN
flow cannot be exercised on this server.

### Empty-set behaviour (unit step note: "ask the server")

`PUT /api/outputs/set` with `{"outputs": []}` → **HTTP 204; the server
accepts it and deselects every output** (verified with the server
`stop`: `selected: []` afterwards; the app reflected it live via the WS
`outputs` event — all rows "not selected", now-playing line "none").
Restored with `{"outputs": ["207183922776680"]}` → 204 →
**byte-identical** to baseline. The app therefore permits the empty
selection (SCREENS.md states it as legal).

### Criterion 6 — gates — PASS (on final code, re-run after C3 + guard hardening)

```
flutter analyze                                  → No issues found!
dart format --output=none --set-exit-if-changed . → 48 files, 0 changed
flutter test --exclude-tags live                  → +175: All tests passed!
flutter build apk --debug                         → ✓ Built build/app/outputs/flutter-apk/app-debug.apk
```

Test count 140 → 175 (+35): `outputs_selection_test` (6, set math),
`outputs_controller_test` (13, one-PUT/rollback/PIN/volume/WS),
`outputs_api_test` (6, wire format), `outputs_screen_test` (9,
rendering/PIN/guard/offline/empty — incl. the new stale-cache guard
regression from C3).

**All six criteria PASS. Unit done (2026-10-23).**

### Incidents

2026-10-22 (unattended night pass):
- None audio-related; server never played. One self-inflicted: a tap
  aimed at a mock checkbox hit the row's volume slider instead
  (`PUT /api/player/volume?volume=0&output_id=m2` on the mock) — the
  app's commit-on-release behaved as specified; the stray value was
  restored on the mock before the toggle tests. The app-bar cast-icon
  entry point overflowed the now-playing app bar by 9 px in the 360-
  logical viewport tests → entry point moved to the tappable "Playing
  via" line (unit-001/002 app-bar contract preserved).

2026-10-23 (supervised C3 pass) — all resolved, server left `stop`:
- **Incidental playback (~40 s).** While restoring the output set I
  tapped the now-playing transport expecting it to stay paused, but the
  app had already returned to a `pause`-state play arrow, so the tap
  resumed `play` on Volumio Kitchen for ~40 s before I noticed and
  paused via the API (`PUT /api/player/pause`, verified `state: pause`).
  No harm (user present, approved playback context); recorded per the
  "if playback is accidentally started" rule.
- **OwnTone volume-sync side-effect.** Deselecting Volumio Kitchen (so
  only the `Server`/ALSA output was selected) caused the server to
  rewrite Volumio Kitchen's stored per-output volume `36 → 8` — the ALSA
  output's own value. This is server behaviour, not an app bug (the app
  sent only `/outputs/set`; no per-output volume PUT in the C3 window —
  the app's own volume commits are all in the Criterion 4 capture).
  Restored Volumio Kitchen to 36 via a direct
  `PUT /api/player/volume?volume=36&output_id=…` so the final
  `/api/outputs` is byte-identical to baseline.
- **Guard stale-cache skip.** First two A→B guard taps on the
  long-lived instance skipped the dialog (stale cached player state,
  server actually playing). Not an audio incident — the toggles were the
  user-confirmed A→B steps — but it exposed a real guard weakness, now
  fixed (see Criterion 3).

### Environment at handoff (2026-10-23, ~10:25)

Server `stop, volume=36, item_id=196174`; `/api/outputs` byte-identical
to the session baseline (Volumio Kitchen selected only). Dev AVD
`RemoteDev_API_36` = `emulator-5556`, still running (headless) with the
app under `flutter run` (debug), connected, `sync: live`. Mock server
long killed. Other session's emulator (`emulator-5554`) untouched.
Pixel 6 untouched. **Committed** (`remote-app/004` — unit done).

Note for later units: the Chromecast remote outputs on this server fail
to select server-side (user-observed; consistent with the C3 attempts)
— treat Volumio Kitchen (AirPlay) and Server (ALSA) as the two
reliable outputs for any future audio-routing test.
