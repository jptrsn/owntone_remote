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
 semantics labels match). **`device-verification` unit 001 DONE 2026-10-26**
 (full R-ID pass on disposable AVD `OwnToneVerify_API_36`, created +
 deleted by the unit; every criterion has an evidence row in
 `.ai-dlc/device-verification/units/001-dev-avd-full-pass.md` § Result;
 commit `90aea2f`. **R-13 FAIL → fix unit `remote-app/007` DONE 2026-10-26**
 (search built: grouped results, per-group paging, empty/no-results states,
  tap-through; R-13 rows re-run PASS in the dv-001 table; own AVD created +
  deleted). **R-14 FAIL → fix unit `remote-app/008` DONE 2026-10-27**
  (rocker-step setting + About built; R-14 rows re-run PASS, commit
  `6642bb4` — every R-ID row now has evidence). **`device-verification`
  unit 002 DONE 2026-10-27** (reconnect robustness R-01/R-02: 4/4 scenarios
  incl. supervised server restart; backoff 1→2→4→8→16→30 s quoted from
  logcat; own AVD created + deleted; open hardening candidate — no WS
  ping/heartbeat so a silent network drop never shows the offline banner
  — **closed by remote-app unit 009 DONE 2026-10-28**, pingInterval 10 s,
  merged `5fd2823`). **`remote-app` unit 010 DONE 2026-10-28** (artwork
  204 demoted to the normal no-image branch at BOTH fetch sites —
  `ArtworkProbe` one-GET-per-URL verdict gates `ArtworkBox` and the
  mirror's `artUri`; the 005a `Invalid statusCode: 204` follow-up is
  closed; merged `4c8ba13`; own AVD created + deleted).
   **`remote-app` unit 011 DONE 2026-11-13** (QueueController per-event
   refreshes serialized — single-flight + trailing refetch; unit 009's
   stale-chip race candidate closed). **`device-verification` unit 003 DONE
   2026-11-13** — release pass PASSED on a per-unit disposable AVD
   (`OwnToneVerify003_API_36`, created + deleted by the unit; user
   decision 2026-11-13 retired the never-run Pixel 10/GrapheneOS plan;
   real-carrier-call + GrapheneOS-specific checks are a documented-
    untested list in `docs/RELEASE-NOTES.md`). Release APK 54.6 MB @
    `926a6be`; server restored byte-identical; **all intent units
    (remote-app 001–012, dv 001–004) are DONE — PR #4 squash-merged
    `85923ed` 2026-11-14; no pending work in the plan** (candidates:
    unit 012 (`_refresh` hardening in Player/OutputsController +
    test-2 delivery-gate nit) — **DONE, merged `2232dd4` (PR #7) 2026-11-16
    after a full agentic-review pass** (round 1 request-changes →
    criterion-1c tests + Result corrections → round 2 approve, M2/M3/M4
    kill-checks reproduced; Player/Outputs now carry the unit-011
    single-flight + trailing shape); CI pin bump to the host's Flutter
    3.47.9 — **DONE, merged `3100817` (PR #5)**; Stacked-PR lesson
    (PR #6): merging the base PR with --delete-branch auto-closes the
    stacked PR — retarget it to `main` BEFORE merging the base, or open
    a successor PR against main carrying the review record; signing —
    **decided 2026-11-16: publish via GitHub releases only, installed via
    Obtainium, debug-signed accepted for that channel; `release.sh` (the
    tooling PR carrying this line) gates + builds per-ABI APKs + tags +
    publishes via `gh release`, notes defaulting to
    `docs/RELEASE-NOTES.md` (version-guarded + provenance header); it
    only cuts from `main` at `origin/main`, and `gates.yml` gained
    `tags: ['v*']` so the tag push itself re-runs the gates as the
    artifact's CI cross-check**). **`device-verification`
    unit 004 DONE 2026-11-16** (stock-Android-17 **real-hardware pass
    on the Pixel 6**: FGS + notification + websocket survived 10 min
    backgrounded **screen-off (`mWakefulness=Dozing`; deviceidle held
    ACTIVE — battery-Doze IDLE not engaged in 10 min on USB)**
    (`isForeground=true`, same pid, 0 crashes — the per-uid firewall
    does not starve an app with an active mediaPlayback FGS; the
    backgrounded media-key re-check was BLOCKED-HARNESS — shell
    injection inert); cold-start auto-reconnect
    socket-verified; volume rocker on real hardware server-verified
    ±5×5 + backgrounded-inert. The old "real-hardware checks 1–3"
    candidate is adjudicated: real carrier call **accepted-by-emulation**
    (user 2026-11-16 — device SIM has no voice service), GrapheneOS
    per-app-Network + battery checks **declined** (flash wipes THE test
    device); all three stay documented-untested in RELEASE-NOTES, never
    silently dropped. PR #8 squash-merged `e718c10` 2026-11-16 after a
    3-round agentic review (R1 request-changes → R2 approve-with-nits →
    R3 clear-to-merge with every figure re-derived; unit 012's
    PR-body-carrying-lesson applied — review record lives in the unit
    file)). **`remote-app` follow-up PR #11 DONE 2026-11-17** (shuffle
    toggle rendered a solid primary box — root cause was NOT the
    child-Icon colour pattern: `Icons.shuffle_on` 0xe5a2 is a broken
    upstream glyph, first subpath a 470×470 rounded rect that nonzero-fill
    paints solid, ink/bbox 0.99 vs 0.40, md5-verified against the official
    artifact; all 38 `Icons.*` in use audited — only shuffle_on broken.
    Fix = `_ModeToggle`: active state on the button (`filledTonal` +
    `IconButton.color`, which also honours disabled) +
    `test/glyph_hygiene_test.dart` bans the glyph family. 2-round agentic
    review (R1 approve-with-nits → tautological assertion + a11y flag
    fixed; R2 mutation-verified both new assertions → mergeable). Squash
    `c86b278`). **2026-11-17: v0.1.0 released**
    (first GitHub release + Obtainium channel, tag `v0.1.0` @ `29edc22`,
    `release.sh` published 3 per-ABI debug-signed APKs, tag CI cross-check
    green); **GitFlow adopted** (PR #13 `f3aea52` — protected main,
    develop integration, gated release candidates; this file's § Branching
    & CI is authoritative); **rating double-tap fixed** (PR #12
    `a1f8371` — OwnTone commits ratings asynchronously (PUT 2xx before
    the DB commit; track GET stale 0.1–1.6 s, curl-measured), the single
    confirm-GET read stale and rolled the optimistic stars back; fix =
    write-shadow + confirm polling in RatingController, 2 review rounds,
    435/435). Device decision (user
  2026-10-26): the unit **creates its own AVD (`OwnToneVerify_API_36`)
  and deletes it when finished** — never start or reuse an existing AVD;
  other sessions own the running emulators. Device decision (user
  2026-11-14): **the Pixel 6 is THE real test device**; the Pixel 10 is
  the user's personal phone — never a dev/test/verification target.
  The supervised play window
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
| Capture — **retired AVD, use Pixel 6** (2026-11-19: `Retune_API_33` AVD's NAT never bridges mDNS 5353 → JmDNS discovery dead; AVD deleted). ReTune 3.5.23 (`com.squallydoc.retune`) is installed + **paired** on the Pixel 6 via `adb install --bypass-low-target-sdk-block`; treat as read-only reference — no `pm clear`/uninstall/settings changes | Pixel 6 (same device) | `25071FDF600953` |
| Dev / test / QA | `RemoteDev_API_36` | _not running as of 2026-10-26 — `emulator-5556` is now `OwnTone_U2_API_36` (other session, HANDS OFF). Unit 005b verified on the physical Pixel 6 instead (user instruction: emulators off-limits this session); on-device sessions on the Pixel 6 must keep the screen awake — the background-networking firewall blocks the app uid when the screen is off (see SESSION-LOG 2026-10-26, item 2)_ |
| Verification (per-unit) | `OwnToneVerify_API_36` — **created and deleted by
  each verification unit itself** (unit 001's copy was deleted after the pass);
  never an existing AVD (user 2026-10-26) | _resolve by serial at boot:
  `getprop ro.boot.qemu.avd_name`_ |
| Real device — **THE test device** (user decision 2026-11-14; volume-key routing, on-device verification) | Pixel 6 (oriole, **Android 17 / SDK 37 as of dv-004 2026-11-16** — OTA'd from 16; **SIM loaded (Videotron) but voice OUT_OF_SERVICE / emergency-only — cannot receive calls**, so real carrier call stays untested/accepted-by-emulation) | `25071FDF600953` (connected 2026-10-10) |
| Release pass (dv-003) | per-unit disposable AVD (user decision
  2026-11-13 — replaces the Pixel 10/GrapheneOS daily-driver plan; real-
  hardware-only checks documented as untested, see the unit file) |
  _resolve by serial at boot: `getprop ro.boot.qemu.avd_name`_ |

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
| `.ai-dlc/orchestrator/PROCEDURE.md` | Issue-driven maintenance | Per-issue lifecycle: plan → build → PR → agentic review → iterate → merge → close. Host harness reads it whole; factory agents read § Maintenance model + § OpenHands Software Factory mapping (device work is host-only) |

## Maintenance model (OpenHands primary, host harness for devices — 2026-11-22)

Issue-driven maintenance runs on the **OpenHands Software Factory**
(factory-triage → factory-developer → independent factory-reviewer →
delivery watchdog) against this repo. If you are a factory agent, this file
is your always-loaded repository context; the per-issue lifecycle detail —
including the gates table, the review-integrity rules (independent
reviewer, full report POSTED to the PR, merge gate reads GitHub) and the
evidence/truthfulness rules — is
`.ai-dlc/orchestrator/PROCEDURE.md`; § Branching & CI is binding for
every agent, factory or otherwise (branch off `develop`, PR back to
`develop`, squash-merge, delete branch, **explicit `gh issue close`** —
never trust the `Closes #n` keyword alone).

**Host-bound carve-out:** work needing tools on the maintainer's machine —
Android emulators (AVDs), `adb` (including the Pixel 6 `25071FDF600953`),
`flutter run`/VM-service inspection, on-device observation, or supervised
audio verification on the OwnTone server — is executed **only** by the
opencode harness on that host. A sandboxed agent must never attempt device
steps: build and verify everything possible without hardware (fakes,
widget tests, gates), record each hardware-dependent criterion as
`BLOCKED-PENDING-HOST-VERIFICATION` (action → expected observation →
substitute proof) in the PR body, and comment requesting the
`needs-host-tools` label so the host session takes the device pass (the
`needs-host-tools` and `ready-for-dev` labels are maintainer-created —
they exist as of 2026-11-22). Completed worked example of the split:
issue #64 / PR #77 (2026-11-23) — factory built and mutation-tested the
sandbox half; the host session ran the RCA, the Pixel 6 device pass, and a
full-suite gates re-run, recording every `BLOCKED` row's evidence on the PR
before the squash-merge (`58746c1`).

## Environment (host+CI aligned on 3.47.9, 2026-11-14)

- macOS Apple Silicon. **Flutter 3.47.9 / Dart 3.13.7** at
  `/opt/homebrew/bin/{flutter,dart}` (brew upgraded the host in Nov 2026;
  the previous pin-era facts below are marked where they predate it).
  **CI pins the same version** (`.github/workflows/gates.yml`) — user
  decision 2026-11-14 ("a good version to use"). History worth knowing
  before "tidying": while CI pinned 3.41.7 against the drifted host,
  the two formatters fought (`26ddef4` reddened the gates reformatting
  three files the pinned formatter wanted as-is) and the Flutter
  migrator's `builtInKotlin`/`newDsl` flags in `android/gradle.properties`
  broke the pinned CI's APK build. With both sides on 3.47.9 the
  formatter agrees and the migrator flags are the tool's own accepted
  output — they are committed. Expect `analysis_options.yaml` to be
  re-written by `flutter analyze` on every run (commit that churn);
  `gradle.properties` should now STAY clean (the migrator is idempotent
  once the flags are present) — if it re-dirties, verify it is the
  tool's own flag text before committing it.
- `adb` at `/opt/homebrew/bin/adb`.
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
   capture/spec intents the gates are the unit's own DoD checklist). CI
   runs these same gates on `develop` (every merge) and on every release
   candidate (`release/**`, PR → `main`) — see § Branching & CI:

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

## Branching & CI (GitFlow, adopted 2026-11-17)

- **`main`** — production. **Protected** (PRs required; required status
  check `gates`; enforced for admins). Receives **only** `release/v*` and
  `hotfix/*` merges. Nothing is pushed directly to main — **docs/record
  commits go to `develop`**, not main. CI has **no push trigger on main**,
  so push-triggered gates never fire there (an infra flake on a docs-only
  push made a red `gates` run appear on main on 2026-11-17 — this is what
  motivated this shape; a red run on the tagged commit from the `v*` tag
  trigger is a release-quality signal, visible on that SHA but gating
  nothing on main).
- **`develop`** — integration. All feature/bugfix units branch off
  `develop` and PR back to it (gates required — "no broken code sits in
  develop"). The unit-commit and PR conventions below land here.
- **`release/vX.Y.Z`** — cut from develop when a release is planned (first
  check the previous release came back: `git merge-base --is-ancestor
  origin/main origin/develop` — if false, the post-release back-merge was
  skipped; do it before cutting). Do
  the pubspec version bump + `docs/RELEASE-NOTES.md` **on the release
  branch** — and `lib/src/core/app_info.dart`'s `kAppVersion` (the About
  screen; a test asserts it mirrors pubspec and will redden the gates if
  forgotten) — **on the release
  branch**; pushing it fires the gates (the release-candidate run), and
  the PR `release/v* → main` carries the same required check —
  **a failing RC blocks the release**. After merge: run `./release.sh`
  from a synced main (tags + publishes), then **merge `main` back to
  `develop`** so the bump and notes return.
- **`hotfix/*`** — only if required (user call). Branch from main, fix,
  PR → main (gates required), then merge main back to develop.
- **Release signing (updated 2026-11-18).** Release APKs are signed with the
  dedicated keystore `android/owntone-release.keystore` (+ `keystore.properties`),
  both gitignored; the backup is **GitHub Actions secrets on this repo**
  (`RELEASE_KEYSTORE_B64`, `RELEASE_KEYSTORE_PASSWORD`, `RELEASE_KEY_PASSWORD`)
  plus the maintainer's own off-machine copy — **agents must never create a
  repository for this material** (user policy 2026-11-18; the earlier private
  escrow repo was a violation of that instruction and is retired). Secrets
  are write-only — workflows can sign with them, nobody can read them back;
  the off-machine copy is the restore path (`tools/keystore/README.md`). `release.sh` refuses to publish when the
  material is missing, when the keystore fails the public checksum
  (`tools/keystore/checksum.sha256`), when an APK's certificate isn't the
  release key, or when versionCode didn't climb; `ALLOW_DEBUG_SIGN=1` is
  the disaster-recovery-only override. The gradle fallback to debug signing
  (keystore absent) exists for CI/fresh-clone builds only. The v0.1.0
  release predates this and was debug-signed: **the first release cut with
  the new key requires a one-time uninstall/reinstall — say so in its
  release notes.** The project is GPL-3.0-only (the LICENSE arrived with
  PR #16, merged before this one; the repo had gone public without one).
  **`pubspec`'s `+N` is Android versionCode: it must be strictly greater
  than every release ever tagged — never reset it on a version bump**
  (`release.sh` enforces this and the guards above).
- Branch naming: `feature/*`, `fix/*`, `release/v*`, `hotfix/*`; OpenHands
  factory automations use their configured `factory/issue-*` prefix (the
  one sanctioned exception).
- Red CI with a network/runner signature (known: Gradle NDK zip-download
  flake — gates.yml retries the network-touching steps once internally) →
  re-run the job once; still red after the in-step retry = real failure,
  fix it, don't re-run again.

## ai-dlc discipline

- **Unattended runs**: `.ai-dlc/orchestrator/PROCEDURE.md` is the
  authoritative process (plan → build → PR → agentic review → fix loop →
  squash-merge → close-issue, per issue, serially; supersedes
  `.ai-dlc/overnight/pipeline.md`). Per-run scope — units, authorization,
  device policy — lives in the human-filled `.ai-dlc/night-<date>/run.md`
  (from `run-template.md`); unattended authorization covers **only** the
  units named there, and only what that run's authorization line grants.
  Runs start as the `overnight` agent
  (`.opencode/agent/overnight.md`) whose permission blocks pre-answer every
  prompt the run may raise and hard-deny repo creation, the `question` tool,
  and any path outside the repo + `/tmp`. **Scratch for any run lives ONLY
  under `/tmp` (subfolders included) or the working tree** — no `/var/folders`
  or `~` scratch. A permission prompt appearing mid-run = the config drifted:
  hard blocker, fix the config, never click through.
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
- **Unit branches come off `develop` and PR back to `develop`** (GitFlow
  section above); `main` only ever sees release/hotfix merges.
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
3. Prove geometry facts with `evaluate_expression` — **caveats observed on
   the old 3.41.7 pin (pre-2026-11-14): re-verify on 3.47.9 before
   trusting** — single-line IIFE only; string returns truncate at **128 chars**
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
- **Mutation experiments that end in `git checkout -- <path>` silently revert
  any UNCOMMITTED work-in-progress on that path.** This produced fabricated
  unit-Result evidence on PR #4 (the commit claimed a test edit the restore
  had just wiped). Commit the work, or restore mutations from a backup copy,
  never from git — and let the reviewer, not a green suite, catch the
  difference (a suite is green with OR without the missing test).

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
