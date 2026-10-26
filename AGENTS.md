# AGENTS.md

Instructions for AI agents working in this repository.

**This file is a router, not a manual.** It carries the hard rules and what you
need *before* you know what you need. Everything else lives in `docs/` and
`.ai-dlc/` and is read when the task makes it relevant — not loaded up front.

## The project

OwnTone Remote — a Flutter + Android remote control for a self-hosted
[OwnTone](https://owntone.github.io/owntone-server/) music server.
Clean-room re-implementation of ReTune's UX in Material 3, speaking only the
OwnTone JSON API + websocket. No DACP/DAAP, no ReTune code/assets, no
iTunes-specific features.

 Status: **remote-app units 001–006 ALL DONE** (006 rating DONE 2026-10-26,
 incl. the supervised library-mutation window; follow-up commit `ef17cfc`
 removed row track/position numbers per user call — rows now render
 `title[, artist], M:SS` / `title[, now playing][, artist · album]`,
 semantics labels match). **Next: Phase 5 `device-verification` unit 001**
 (full requirements pass — see
 `.ai-dlc/device-verification/handoff.md`). Device decision (user
 2026-10-26): the unit **creates its own AVD (`OwnToneVerify_API_36`)
 and deletes it when finished** — never start or reuse an existing AVD;
 other sessions own the running emulators. The supervised play window
 needs the user. The server at 192.168.1.13 is **shared with another
 active session** — expect concurrent player/queue changes; snapshot before
 and restore after any mutation, and re-verify `state` immediately before
 anything that can start audio. Note: the Chromecast remote outputs on this
 server fail to select server-side — treat **Volumio Kitchen (AirPlay)**
 and **Server (ALSA)** as the two reliable outputs for any audio-routing
 test. UI oracle: **uiautomator's a11y bridge is dead on the Pixel 6**
 (dumps empty after the app backgrounds; no recovery found) — read the
 `Semantics` widget tree from the VM via `evaluate_expression` with
 chunked return values (128-char cap); `print()`/lens console_logs are
 unreliable after app relaunch.

## Hard rules (read before anything else)

### 1. Audio safety — no unattended playback. EVER.

The server at `192.168.1.13` plays through **real speakers** (outputs selected
2026-10-08: "Office-Airsync" AirPlay + "Server" ALSA). This project may run
unattended, overnight, while the user is away. Music must never start playing
unexpectedly.

- **Never start or resume audible playback** on the server unless the user is
  present **and** has explicitly confirmed *that specific action*.
- Before ANY work that could trigger playback (pressing play in the app or in
  ReTune, `PUT /api/player/play|toggle|next|previous` with state `play` or a
  transition into play, `POST /api/queue/items/add` with `playback=start`,
  simulated-call auto-resume tests), first pause and verify:

  ```sh
  curl -s -X PUT http://192.168.1.13:3689/api/player/pause
  curl -s http://192.168.1.13:3689/api/player   # "state" must be "pause"
  ```

- **Unattended / overnight: never trigger playback.** Unit steps marked
  `supervised: true` must be **skipped** when the user is not present and
  recorded in the unit's Result as `BLOCKED-PENDING-SUPERVISION`. Do not
  improvise a workaround that plays audio.
- **If playback is accidentally started** (stray tap, test bug): pause
  immediately via the JSON API, verify `state == pause`, and record an incident
  entry in `docs/SESSION-LOG.md` (what happened, what played, for how long).
- **Safe without confirmation** (while the server is verified paused): `GET`
  requests, `pause`, `stop`, `seek` (position moves, no audio), volume changes,
  queue edits **without** `playback=start`, enabling/disabling outputs (no
  audio flows while paused), library reads.
- "next/previous" while the server is paused keeps it paused in OwnTone, but
  treat any web-UI or app action that *might* resume audio as `supervised`.

### 2. Device isolation

- `Pixel_9_Pro_API_36` (Android 16; serial `emulator-5554` as of 2026-10-22)
  belongs to **a separate session on this host**. Never run adb against it,
  never stop or install on it, never use its AVD.
- This project's AVDs (created by the units that specify them):
  - `Retune_API_33` — Android 13, **capture only** (ReTune reference)
  - `RemoteDev_API_36` — Android 16, **dev / test / QA**
- **Always target devices by serial: `adb -s <serial> ...`** (three or more
  emulators may be attached at once). Before any adb work, run `adb devices -l`
  and confirm the serials below still match; record new serials in the table.

| Role | AVD / device | Serial |
|---|---|---|
| Other session — HANDS OFF | `Pixel_9_Pro_API_36` | `emulator-5554` (verified 2026-10-26 via `ro.boot.qemu.avd_name`; was `-5556` on 2026-10-09 — **serials shift when other emulators start; always re-verify via `adb shell getprop ro.boot.qemu.avd_name`, never trust a remembered serial**) |
| Capture | `Retune_API_33` | _record on creation_ |
| Dev / test / QA | `RemoteDev_API_36` | _not running as of 2026-10-26 — `emulator-5556` is now `OwnTone_U2_API_36` (other session, HANDS OFF). Unit 005b verified on the physical Pixel 6 instead (user instruction: emulators off-limits this session); on-device sessions on the Pixel 6 must keep the screen awake — the background-networking firewall blocks the app uid when the screen is off (see SESSION-LOG 2026-10-26, item 2)_ |
| Verification (per-unit) | `OwnToneVerify_API_36` — **created and deleted by `device-verification` unit 001 itself**; never an existing AVD (user 2026-10-26) | _resolve by serial at boot: `getprop ro.boot.qemu.avd_name`_ |
| Real device — volume-key routing tests | Pixel 6 (oriole, Android 16, **no SIM** — cannot receive calls) | `25071FDF600953` (connected 2026-10-10) |
| Release candidate | Pixel 10 (GrapheneOS) | _record when connected_ |

### 3. ReTune on the capture AVD is a read-only reference

It is the only working, paired ReTune instance against the user's server.
**Forbidden without explicit user approval:** `pm clear`, uninstall,
reinstall, changing ReTune's settings, altering its pairing. `am force-stop`
is allowed. Losing the pairing would cost the reference.

### 4. The server holds the user's real, curated library

Read freely. **Do not modify library data** except through the app's own
rating flow during supervised verification (record the original rating first,
restore it afterwards, confirm the restore against the API). No playlist
create/edit/delete (the server has `allow_modifying_stored_playlists: false`
anyway), no `PUT /api/update` or `/api/rescan` (rescans are heavy and modify
the DB).

### 5. OwnTone-only feature set

Every iTunes-specific ReTune feature is **out of scope and stays out**:
radio, movies/TV, iTunes U, podcasts, audiobooks, Genius, Apple widgets,
home sharing. The capture phase records their *existence* (one line each,
tagged `out: itunes-only`) and then does not document them further. When a
ReTune action has no OwnTone JSON equivalent, the answer is "use the simpler
JSON surface" or "drop it" — never "reverse-engineer the DAAP call".

### 6. Open-source constraint

This app is planned as open source. **Never port decompiled ReTune code or
reuse ReTune assets** (drawables, layouts, strings, iconography) into the app.
The spec describes *behaviour*; the implementation is written from the spec.
The ReTune APK in `tools/retune/` is reference material for capture only —
it must never become a build dependency and must never be redistributed with
the app.

## Read these, in this order

| File | When | Why |
|---|---|---|
| `docs/PLAN.md` | Always, first | The approved plan; every recorded decision |
| `docs/SESSION-LOG.md` (last entry) | Session start | Current state, what the previous session left behind |
| `.ai-dlc/<intent>/intent.md` | Starting an intent | Problem, domain model, success criteria, gates |
| `.ai-dlc/<intent>/units/NNN-*.md` | Working a unit | Completion criteria, procedure, result template |
| `docs/REQUIREMENTS.md` | Building any feature | R-IDs + acceptance criteria to test against |
| `docs/ARCHITECTURE.md` | Writing code | Layers, `MusicProvider` contract, state flow |
| `docs/API.md` | Touching the network layer | Endpoint reference, live examples, WS protocol |
| `docs/retune-capture/CAPTURE-PROTOCOL.md` | Capture intent only | Walk procedure, static pass, output format |

## Environment (verified 2026-10-08)

- macOS Apple Silicon. Flutter **3.41.7** stable, Dart **3.11.5** at
  `/opt/homebrew/bin/{flutter,dart}`. `adb` at `/opt/homebrew/bin/adb`.
  git 2.50.1, git identity configured globally.
- Android SDK at `~/Library/Android/sdk`. `ANDROID_HOME` is **not** set in
  shells; use absolute paths:
  - emulator: `~/Library/Android/sdk/emulator/emulator`
  - sdkmanager / avdmanager: `~/Library/Android/sdk/cmdline-tools/latest/bin/`
  - system images installed: `android-35/google_apis_playstore`,
    `android-36/google_apis`, `android-36/google_apis_playstore`.
    **`android-33` must be downloaded** for the capture AVD.
- OwnTone server: `192.168.1.13` — JSON API `:3689`, websocket `:3688`,
  version 29.3. Verified live 2026-10-08; see `docs/API.md` § "Verified live".
- MCP servers available in this stack:
  - `flutter-agent-lens` — deterministic UI inspection of a running debug app
    (widget tree, screenshots + baseline compare, console logs, hot reload).
    Deployed and verified 2026-10-06 (see "UI debug loop" below).
  - `docs-mcp` — library docs. Relevant: `owntone-server` (API reference),
    `flutter`, `audio_service`, `just_audio`, `provider`, `rxdart`, `ai-dlc`.
  - `obsidian-mcp` — the user's vault (project notes live there; vault files
    are MCP-tools-only, never filesystem tools).

## Quality gates — "done" means

A unit is **done** only when ALL of:

1. Every completion criterion is verified, with **evidence pasted into the
   unit file's `## Result` section** (command + output, or device observation
   with timestamp). A clean build is not evidence of behaviour.
2. Gates pass (run from repo root once `flutter create` has run; for the
   capture/spec intents the gates are the unit's own DoD checklist):

   ```sh
   flutter analyze                                  # 0 issues
   dart format --output=none --set-exit-if-changed .
   flutter test --exclude-tags live                 # unit + widget tests, no network
   ```

3. `flutter build apk --debug` succeeds (from `remote-app` intent onward).
4. The behaviour was **observed on a device** (dev AVD, or capture AVD for
   capture work). If the check that is the point of the task could not be run,
   the unit is **BLOCKED**, not done — say so plainly in `## Result`.
5. A `docs/SESSION-LOG.md` entry is appended.
6. Committed (see commit rules below).

## ai-dlc discipline

- Work **one unit at a time**. Read the intent + the unit + the specific docs
  the unit names. Do not load the whole repo into context.
- **Backpressure:** never skip a gate, never mark a unit done with failing
  criteria, never rationalize away a failure. A failing gate is data: fix and
  re-run.
- Unit lifecycle: `pending` → `in_progress` → `done` | `blocked`. Update the
  unit's frontmatter `status` as you go.
- **Commit per completed unit** — this is how handoff works in this repo.
  Message format: `<intent>/<unit>: <why, not what>`.
  Example: `spike/001: rocker works backgrounded — mediaPlayback FGS survives pause state`
- **Never push** unless explicitly asked.
- If a unit is ballooning (>10 criteria, >3 major components, you keep
  forgetting where you were), split it: write the remainder as a new unit
  file and note the split in the session log.
- **Two sessions at once → separate git worktrees**, or you will clobber each
  other: `git worktree add ../owntone-remote-<task> -b <task>`.

## UI debug loop (flutter_agent_lens)

For any UI work on a running debug build:

1. `flutter run` (debug) on the dev AVD → connect via `discover_apps`
   (auto) or the `connection` tool with the ws URI; `workspace_root` = repo.
2. Inspect: `widget.get_tree` (`projectOnly: true`, `maxDepth: 8`) — exact
   widget types, sizes, positions, `lib/*.dart:line` mapping.
3. Prove geometry facts with `evaluate_expression` — **caveats on Flutter
   3.41.7:** single-line IIFE only; string returns truncate at **128 chars**
   with no marker (print long output and read `console_logs`);
   `WidgetsBinding.instance.renderView.size` (there is no `rootRenderBox`);
   framework types don't resolve in the synthetic scope — walk via
   `(r as dynamic).visitChildren(...)`, match with
   `runtimeType.toString().contains('RenderParagraph')`.
4. Fix, `hot_reload`, re-inspect. For "did the right pixels change":
   `screenshot.capture_baseline` → edit → `screenshot.take` + `compare`
   (exact RGB match, default 0.98 threshold; the status-bar clock eats into
   that budget — compare with system UI hidden or expect small diffs).
5. `console_logs` does **not** capture framework exceptions under
   `flutter run` (they go to the `flutter run` console, tag `E/flutter`) —
   read that console for red-screen text; `print()` output IS captured.

## Tests

- Tests are derived from `docs/REQUIREMENTS.md`, not from the implementation.
  Cite the R-ID (or invariant) in each test's name/doc.
- **Network tests are tagged `live`** (`@Tags('live')`) and excluded from the
  gate: `flutter test --exclude-tags live`. They require the LAN server and,
  if they touch playback, a supervised window.
- Unit/widget tests use in-repo fakes (`test/fakes/`) for `MusicProvider` and
  the OwnTone HTTP layer — no network, no server dependency.

## Three traps that cost sessions elsewhere (verified for this stack)

- **`uiautomator dump` returns an empty window while an overlay/sheet is
  open.** For a rendering bug, attach `flutter run` and read the console
  (`E/flutter`); screencap pixel-counting tells you *that* nothing rendered,
  never *why*.
- **If a check reports a feature missing, suspect your harness first.** A
  negative result is a claim about the feature *and* the test. Confirm the
  harness sees a known-present thing before concluding absence.
- **Verify claims against the code and the live server.** Instructions you are
  given — including in this file — may be stale. `curl /api/config` before
  trusting a port; read the endpoint before trusting a parameter name.

## Server quick reference

```sh
BASE=http://192.168.1.13:3689
curl -s $BASE/api/config          # version, websocket_port, buildoptions
curl -s $BASE/api/player          # state, volume, item_id, item_progress_ms, ...
curl -s $BASE/api/outputs         # outputs[] with selected/volume/has_password
curl -s -X PUT $BASE/api/player/pause   # the pause you run before supervised work
```

Full reference: `docs/API.md`.

## Commit messages

Explain *why*, not what — the diff shows what. Where a change is non-obvious
or looks like something a future reader would "tidy up", say what breaks if
they do. Several commits in sibling repos exist mainly to carry that warning.
