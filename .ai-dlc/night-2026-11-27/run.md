# Run 2026-11-27 — configuration

## Authorization (user-confirmed — the run does not start without it)
The user authorized, on 2026-11-26, unattended: plan, build, commit, push,
review, fix, squash-merge to `develop`, branch deletion, and issue closure —
ONLY for the units listed below, within the limits of AGENTS.md (no audible
playback, no repo creation, no devices outside this run's night AVD, no
library mutations).

Extra authorizations:
- **Adopt existing PRs**: units 1–2 continue the branches
  `openhands/issue-81` (PR #88) and `openhands/issue-82` (PR #89) as-is
  (no new `fix/issue-*` branches for them). Push to those branches is
  authorized.
- OpenHands automations are **OFF** for this run: the independent reviewer is
  the run's own spawned subagent (`.ai-dlc/orchestrator/roles/reviewer.md`),
  posting its full report as a PR comment with the
  `## Agentic Review — PR #<pr> — round <r>` marker + `VERDICT:` line. Do not
  add/remove the `openhands-review` label to trigger anything; when PR #88
  closes, remove the stale `openhands-review` label from it.
- Label hygiene is authorized ONLY on issues this run closes
  (`gh issue edit --remove-label openhands,ready-for-dev,openhands-review,needs-host-tools`).

Explicitly **withheld** (violation = run blocker):
- The Pixel 6 (`25071FDF600953`) and every AVD not created by this run;
  `emulator-5554` / `Pixel_9_Pro_API_36` are another session's — hands off.
- **PR #89 must NOT be merged by this run** (its device rows need the Pixel 6
  + ESP32 AVRCP harness = host-only). Terminal state for unit 2 is
  "review-approved (or cap exhausted), ready-to-merge, merge deferred to the
  host session".
- Every server call that can become audible: `PUT /api/player/play|toggle`,
  `next|previous` (treated as play-capable THIS run — the server is shared
  with a live second session that can flip state between verify-and-act),
  `POST /api/queue/items/add` with `playback=start`, any media-button/AVRCP
  injection, any app play button. Also: no server restart, no
  `/api/update|/api/rescan`, no library/playlist mutation, no queue edits.
- Safe server set for this run: `GET` anything; `PUT pause`; `PUT stop`;
  `PUT seek` (while paused); `PUT /api/player/volume` (master or output);
  output enable/disable **only while paused**.

## Audio-safety invariants (must hold at PIPELINE COMPLETE and at every
## run-blocker exit)
1. `curl -s http://192.168.1.13:3689/api/player` reports `"state": "pause"`
   AND `item_progress_ms` is unchanged across two reads ~5 s apart. If any
   step finds `play` (and the run issued no play — it must not), pause
   immediately, verify, append a ledger INCIDENT entry, name it in the
   summary. Remember `docs/API.md` § play-start latency: a post-play read can
   falsely say `pause` ~2–4 s — so the invariant is "we never issued a
   play-class call" + "pause is stable", not a single snapshot.
2. Server baseline to leave untouched: `volume=46`, outputs **ESP-CAAC64 +
   Volumio Kitchen** selected (the Chromecast outputs fail to select
   server-side — never touch selection; the queue pointer/`item_id` belong to
   the other session — never "restore" them).
3. No AVD from this run left running at exit (each unit deletes its own,
   including on blockers).

## Units
| order | issue | slug | notes |
|---|---|---|---|
| 1 | #81 (adopt PR #88) | wake-forfeit | Branch `openhands/issue-81` — implementation DONE, host device rows filled with evidence on the PR (comment 7207241774), gates green on `7dc0ed4` (run 45922326991). Remaining work = Steps 3–4 ONLY: spawn independent reviewer, fix loop per cap if `CHANGES_REQUESTED` (fixer re-runs gates; orchestrator re-verifies), then squash-merge, delete branch, `gh issue close 81 --comment "Fixed in PR #88 (squash <sha> to develop)"`, label hygiene. No new feature code. |
| 2 | #82 (adopt PR #89 — **no merge**) | mirror-active-keys | Branch `openhands/issue-82`. (a) `git merge origin/develop` (must include unit 1's merge — gate on it). Expect conflicts in `docs/SESSION-LOG.md` (resolve append-only: keep BOTH sides verbatim), `lib/main.dart`, `lib/src/audio/mirror_handler.dart`, `test/mirror_click_log_test.dart` — resolve keeping both changes, never `git checkout --`. (b) Full gates incl. `flutter build apk --debug`; push. (c) PR body must state: all device-row criteria are `BLOCKED-PENDING-HOST-VERIFICATION` (action → expected observation → substitute sandbox proof per row) — the Pixel 6/ESP32 procedure is already scripted on PRs #88/#89. (d) Review loop per cap (reviewer may not fail the PR for the withheld host rows; they are the run config, not a defect). (e) STOP: leave PR open, do not merge; ledger `next:` = "host session runs #89 device rows per PR-body procedure, then merges". PREVIOUS_MERGED for unit 3 accepts unit 2 in this terminal state. |
| 3 | #93 | error-phase-auto-retry | New `fix/issue-93-error-phase-auto-retry` off develop-after-unit-1. Scope (`lib/src/connection/connection_controller.dart`, `lib/main.dart`): recover automatically from `ConnectionPhase.error` — probe/retry timer in the error phase and/or connectivity listener calling `retry()`; keep the `offline` probe path intact; no UI redesign. Tests fake-based (`test/fakes/`), cite the issue's AC; optional night-AVD observation (seed prefs via `adb shell run-as` on the debug build; blackhole host `192.0.2.1` → error phase → repoint to server → recovery WITHOUT a Retry tap). Merge→close #93 when every merged row has evidence. |
| 4 | #92 | volume-toaster | New `fix/issue-92-volume-toaster`. ReTune capture-22 parity (docs/retune-capture/22-volume-toaster/notes.md): transient volume toaster on server-volume steps on every screen EXCEPT NowPlaying (which keeps its slider-follow). Widget tests with fakes + semantics label assertions; night-AVD observation where injectable (foreground `input keyevent` 24/25 routes to the SYSTEM volume, not our REMOTE session — if a step cannot be injected without the Pixel 6, record substitute proof: controller-driven step + widget test + `BLOCKED-PENDING-HOST-VERIFICATION` row). Merge only with every merged row evidenced. |

Branch per NEW unit: `fix/issue-<n>-<slug>` off `develop`. Serial, in this order.

## Config
| Key | Value |
|---|---|
| repo | `jptrsn/owntone_remote`, remote `origin`, base **`develop`**, merge **squash** (`gh pr merge <n> --squash --delete-branch`) |
| gates | `flutter analyze` (0 issues) · `dart format --output=none --set-exit-if-changed .` · `flutter test --exclude-tags live` · `flutter build apk --debug`. Expect `analysis_options.yaml` churn from analyze — commit it. Host Flutter is the CI pin 3.47.9 (`/opt/homebrew/bin/flutter`) — do not "tidy" versions. |
| external deps | OwnTone server `192.168.1.13` (REST :3689, ws :3688, v29.3) — **shared with another live session**; GET freely; safe set per § Authorization; NEVER any playback-capable call or tap (see withheld list — stricter than AGENTS §1: `next`/`previous` are forbidden this run). Baseline to leave untouched: pause, volume 46, ESP-CAAC64 + Volumio Kitchen selected. No library mutations, no `/api/update|/api/rescan`. |
| device policy | Per-unit disposable AVD **`OwnToneNight27_API_36`** (`android-36 google_apis`, arm64), created AND deleted by the unit (incl. on blockers); serial via `getprop ro.boot.qemu.avd_name`; `adb -s <serial>` always; never touch another AVD / `emulator-5554` / Pixel 6. Harness: MCP-first (flutter_agent_lens), uiautomator+screencap fallback. Hard interaction rules: fresh widget dump immediately before every `input tap`/`swipe` + `topResumedActivity` is the app; red-screen grep per step; no held press within ~150 px of the nav-bar edge. |
| review grounding | `agentic-code-review` skill + docs-mcp: `owntone-server`, `flutter`, `audio_service`, `just_audio`, `provider`, `code-review-guide`. Contract: AGENTS.md hard rules + docs/ARCHITECTURE.md + PROCEDURE § Evidence rules. Reviewers are fresh independent subagents (never the orchestrator or a build-side actor); each posts its FULL report to the PR itself (marker + exactly one `VERDICT:` line). Deliberately-open (do not re-report): the other session's owntone_sync server/queue churn (never "fix" it, never trust server state to be stable between two GETs), and the Pixel 6 rows withheld by THIS run config. |
| review cap | 3 rounds |
| unit exceptions | Unit 1 skips plan/build (code exists; review→merge only). Unit 2 must not merge; its device rows are pre-declared `BLOCKED-PENDING-HOST-VERIFICATION` with the scripted procedure on the PR — reviewers/judges treat that as the config, not a defect. Units 3–4: any criterion that would need `play`/`toggle`/`next`/`previous` or the Pixel 6 → pre-declare `BLOCKED-PENDING-SUPERVISION` / `-HOST-VERIFICATION` with substitute proof; never work around it. |
| scratch | `/tmp/owntone-night/` + repo working tree only |
| ledger | `docs/overnight-ledger.md` (gitignored, never committed) |

## Known environment facts (verified 2026-11-26, host session)
- `input tap` is inert on the Pixel 6 (keyevents work) — irrelevant here
  (no Pixel 6), but uiautomator on the night AVD is fine; if a check reports
  a feature missing, suspect the harness first.
- Debug builds launched via `am start` have no VM-service compile service
  (expression eval needs a `flutter run` attach); the debug APK is installable
  with `adb install -r`; app prefs can be seeded via `run-as` (debuggable).
- The app restores the NowPlaying route at launch (a BACK at startup exits
  the app) — dump the tree before any scripted tap.
- The server's AirPlay outputs take ~2–4 s to commit `play` after a PUT
  (docs/API.md) — the run never issues play, but never trust a single
  post-action snapshot for state claims.
- CI: `gates` workflow; red with a network/runner signature (Gradle/Maven
  flake) → `gh run rerun <id> --failed` ONCE; still red = unit blocker.
