# Overnight pipeline — unattended serial build → PR → review → merge

Authoritative process definition for an **unattended overnight run** of serial
units: build → PR → review → (fix → re-review)* → merge → next unit. Executed
by a **fresh session** with no other context. Generalized from
`kestra/overnight-pipeline-generic.md` (Obsidian), instantiated for this repo
2026-11-18 for GitHub issues #19–#26 (run complete) and re-instantiated
2026-11-19 for GitHub issues #38–#48 (the eleven open issues; this Run
configuration reflects that instantiation — the 2026-11-18 values are
superseded below and preserved only in git history).

**Run authorization:** the user authorized unattended build, commit, push,
review, fix and squash-merge to `develop` for the `<cfg:units>` list on
2026-11-19 (same scope and limits as the consumed 2026-11-18 authorization:
no repo creation, no audible playback, no devices outside the per-unit night
AVD — never the Pixel 6, never emulator-5554, no library mutations). That
authorization is LIMITED to these units and the commits/pushes/merges this
document names.
It does not authorize: creating repositories (hard-banned,
`~/.config/opencode/AGENTS.md` + opencode permissions), starting audible
playback (AGENTS hard rule 1), touching devices outside `<cfg:device policy>`,
or library mutations on the server.

## Assumptions

- opencode with fresh-context subagents (Task tool, `general` type) beside a
  long-lived orchestrator session started as the **`overnight` agent**
  (`.opencode/agent/overnight.md` — permission-tight, no prompts).
- git + GitHub via `gh`; CI (`gates.yml`) on PRs; `AGENTS.md` as the standing
  instructions file.
- Behaviour is observed on a **per-unit disposable AVD** driven by
  `flutter run` + the dart/flutter MCP tools (flutter-agent-lens,
  dart_widget_inspector, dart_flutter_driver_command, dart_hot_reload).
- If an assumption does not hold, adapt **before** kickoff and record it in
  the ledger. Do not adapt mid-run.

## Run configuration

| Key | Value |
|---|---|
| `repo` | `jptrsn/owntone_remote`, remote `origin` (ssh), base **`develop`**, merge style **squash** (`gh pr merge <n> --squash --delete-branch`) |
| `units` | serial order: **#43 → #40 → #39 → #48 → #38 → #44 → #45 → #41 → #46 → #47 → #42** (isolated UI first, shared-scaffold navigation next, queue/server-semantics after, mDNS discovery last). Branch `fix/issue-<n>-<slug>`. Spec: `.ai-dlc/night-2026-11-19/issues/<n>.md` (frozen copies of the issues; canonical = the GitHub issue). Subject = the issue title. |
| `prior state` | no branches/PRs exist for any of these units (verified Step 0); every unit starts at build. PR bodies MUST contain `Closes #<n>`. |
| `standing file` | `AGENTS.md` (repo root). "Done means" = its § Quality gates; audio safety = § Hard rules 1 (verbatim non-negotiable); device isolation = § Hard rule 2. |
| `gates` | `flutter analyze` (0 issues) · `dart format --output=none --set-exit-if-changed .` · `flutter test --exclude-tags live` (all green, ~443) · `flutter build apk --debug`. Expect `analysis_options.yaml` churn from analyze — commit it. |
| `report format` | per-unit report `.ai-dlc/night-2026-11-19/reports/<n>.md`, committed on the unit branch, mandatory fields: `SUMMARY`, `GATES` (verbatim tails), `OBSERVED` (action → result per device check, incl. BLOCKED-PENDING-SUPERVISION rows), `ASSUMPTIONS`, `RESOLVED FINDINGS` (per review round). A `docs/SESSION-LOG.md` entry is added by the build subagent in the unit's final commit (repo rule). |
| `external deps` | OwnTone server `192.168.1.13` (REST :3689, ws :3688, v29.3) — **shared with another active session.** GET freely. Safe unattended: `pause`, `stop`, `seek`, volume PUT, queue edits **without** `playback=start`, output enable/disable **while paused**, library reads. **NEVER** any call or UI tap that can start audio (`player/play|toggle`, `next/previous` that could transition into play, `playback=start`, app play button). Before any device step: `curl -s $BASE/api/player` — if `state == "play"` the user is listening: **skip device steps**, rely on fakes/widget tests, record it. Reliable outputs: Volumio Kitchen (AirPlay), Server (ALSA); Chromecast remote outputs fail server-side selection. No library mutations, ever. No `PUT /api/update|/api/rescan`. |
| `device policy` | Each unit creates its own AVD `OwnToneNight_API_36` (`android-36 google_apis`, arm64) and **deletes it at unit end, including on blockers**. Emulator/sdkmanager at `~/Library/Android/sdk/...` (no `ANDROID_HOME`). Resolve serial via `getprop ro.boot.qemu.avd_name` after boot; **never** touch `Pixel_9_Pro_API_36` / `emulator-5554` or any AVD you did not create; **Pixel 6 `25071FDF600953` is off-limits overnight** (unattended runs only; supervised passes are allowed per the AGENTS.md device table — it is THE test device). App under test via `flutter run -d <serial>`; inspect with flutter-agent-lens (widget tree, screenshot, console) + dart MCP tools; `evaluate_expression` returns cap 128 chars — chunk; read `flutter run` console for framework errors. **Hard interaction rules (2026-11-20 supervised session, enforced):** (1) take a fresh widget-tree dump for target coordinates IMMEDIATELY before every `input tap` — never reuse remembered or earlier coordinates, and abort the tap if the dump shows the element absent or off-screen. A Flutter widget-tree dump CANNOT see system overlays: before every tap — and after any tap that behaves oddly — verify `dumpsys activity activities | grep topResumedActivity` is the app's own activity (a tap that "worked" in the tree but landed under a Google/system overlay launches Google settings/Calendar — observed twice 2026-11-20); (2) after every step grep the `flutter run` console for `EXCEPTION CAUGHT`/red-screen signature (or count red-dominant pixels in a screencap) — the red error screen survives silently otherwise; (3) for luma/theme comparisons pin brightness first (`settings put system screen_brightness_mode 0; cmd display set-brightness 0.6`) — auto-brightness makes luma numbers meaningless; (4) never hold a press (motionevent DOWN…UP) within ~150 px of the navigation-bar edge — Android's hold-to-search system gesture hijacks it and leaves a system overlay. |
| `review grounding` | Reviewers load the `agentic-code-review` skill and follow it; grounding docs via docs-mcp: `owntone-server`, `flutter`, `audio_service`, `just_audio`, `provider`. Contract = `AGENTS.md` hard rules + `docs/ARCHITECTURE.md`. Deliberately-open defects that must NOT be re-reported: the OTHER issues in #38–#48 (out of this unit's scope) and the Known-limitations list in `docs/RELEASE-NOTES.md`. |
| `unit exceptions` | **#41, #45, #46, #47**: any completion criterion that needs AUDIBLE playback (#41 Play All/Shuffle, #45 bar play/pause live, #46 drag while playing, #47 remove-while-playing) and their "supervised manual once" rows are recorded `BLOCKED-PENDING-SUPERVISION` in the report's OBSERVED section and flagged in the morning summary — the unit still merges on the strength of the paused-state + fake-controller evidence. Queue add/move/delete WITHOUT `playback=start` and volume/seek PUTs remain safe unattended. **#42**: `dns-sd` browse/query and `live`-tagged discovery tests against the LAN server are safe (no playback); the mDNS plugin choice must be justified in the PR body. |
| `review cap` | 3 rounds. |
| `ledger path` | `docs/overnight-ledger.md` — gitignored (confirmed in Step 0), never committed. |
| `scratch` | **ONLY `/tmp/**` (subfolders included) and the repo working tree.** No reads or writes of user files outside these (no `~` scratch, no `/var/folders` scratch, no vault access). Reviewer/fix worktrees: `/tmp/owntone-night/pr<n>/`. Downloads/keystore material are never needed. |

## Process invariants — do not re-litigate mid-run

1. **Serial pipeline.** Per unit: build → PR → review → (fix → re-review)* →
   merge → next. Never two subagents at once.
2. **No permission prompts by design, no harness changes mid-run.** The
   `overnight` agent's permission block (repo `opencode.json` +
   `.opencode/agent/overnight.md`) pre-answers everything the run needs and
   hard-denies what it must not touch (repo creation, `question` tool, paths
   outside repo + /tmp). If a prompt still appears, that is a **hard
   blocker** — stop per policy; do not "work around" it.
3. **Orchestrator/subagent split.** Orchestrator: all git/gh mechanics, gate
   re-verification (runs them itself), ledger, merge decisions, AVD lifecycle
   supervision. Never writes feature code. Subagents: one build per unit,
   one review per round, one fix per round; fresh context each.
4. **Review cap 3**; final CHANGES_REQUESTED at cap = hard blocker.
5. **Commit + push + squash-merge are authorized** at the points named here,
   per the 2026-11-18 user authorization at the top. Nothing else is.
6. **Every unit runs the same flow**; exceptions live in `<cfg:unit
   exceptions>`, never invented mid-run.

## Kickoff

The human pastes this as the entire first message of a **fresh opencode
session at the repo root, started as the `overnight` agent**:

```
Read .ai-dlc/overnight/pipeline.md and execute it from the start, using its
Run configuration section. This is the unattended overnight run it defines.
Do not ask me questions — the document contains the assumptions policy.
```

## Roles

- **Orchestrator** — the `overnight` agent session. Keeps its context small;
  everything load-bearing goes in the ledger. Spawns one subagent at a time.
- **Build subagent** — implements one unit in the main working tree on the
  unit branch, incl. behaviour verification, SESSION-LOG entry, report.
- **Review subagent** — `agentic-code-review` procedure, own worktree under
  `/tmp/owntone-night/`, read-only toward repo and GitHub. Returns report +
  verdict line.
- **Fix subagent** — resolves the round's findings (fix or evidence-based
  rebuttal), re-runs gates, commits + pushes.

## The ledger

`docs/overnight-ledger.md`, append-only, single source of truth across
subagent boundaries and compaction. Entry format:

```
## <UTC timestamp> — <STEP NAME>
- actor:      orchestrator | build | review | fix
- state:      branch=<b> head=<sha> pr=<n+state> device=<serial|none>
- did:        <what happened, incl. any deviations>
- next:       <the exact next action, imperative>
```

Orchestrator appends after every gate; each subagent appends its own final
entry before returning. Crash recovery = read this doc, then the ledger,
continue from the latest `next:`.

## Hard gates

| Gate | Between | Condition | Check |
|---|---|---|---|
| `RUN_UNIQUE` | start | no other orchestration live | ledger absent or last entry > 2 h old; < 30 min old with `next:` ≠ `PIPELINE COMPLETE` → stop |
| `PREVIOUS_MERGED` | unit start | prior unit PR merged | `gh pr view <n> --json state -q .state` → `MERGED` |
| `BUILD_VERIFIED` | build → PR | gates + report + clean tree | orchestrator re-runs all `<cfg:gates>` itself; report exists with all fields; `git status --short` empty |
| `PR_OPEN` | build → review | PR with `Closes #<n>` | `gh pr view <n>` |
| `REVIEW_POSTED` | review → decision | report posted as PR comment | `gh api repos/jptrsn/owntone_remote/issues/<n>/comments` |
| `REVIEW_PASSED` | review → merge | APPROVE, no blocker/major | reviewer verdict line |
| `CI_GREEN` | merge | checks green | `gh pr checks <n>` — one re-run on red (AGENTS: in-step retry exists; still red = hard blocker) |
| `MERGED` | unit end | merged | `gh pr view <n> --json state -q .state` → `MERGED` |

## Pipeline steps

### Step 0 — preflight
1. Create the ledger (confirm gitignored). `RUN_UNIQUE`.
2. `git fetch origin && git checkout develop && git pull`; `git status --short` must be empty.
3. `gh auth status`; confirm `gh pr view` sees the repo.
4. No prior-state PRs to open (all units start at build). Enter the loop at unit #43.

### Step 1 — build unit N
1. Gate `PREVIOUS_MERGED`; `git checkout develop && git pull && git checkout -b fix/issue-<n>-<slug>`.
2. Ledger: device plan (AVD create params, server-pause check, unit's
   supervised rows pre-declared BLOCKED-PENDING-SUPERVISION).
3. Spawn build subagent. Wait.
4. `BUILD_VERIFIED` (re-run gates yourself). `BLOCKED:` → hard blocker policy.
5. Push if needed; `gh pr create --base develop --head <branch>` with
   `Closes #<n>` in the body + report path + behaviour-verification claim.

### Step 2 — review loop
1. Spawn review subagent for the PR.
2. Orchestrator posts the full report as a PR comment.
3. APPROVE → `REVIEW_PASSED`. CHANGES_REQUESTED → cap check → fix subagent → round += 1 → repeat.

**Review-integrity hard rules (2026-11-21, after a docs PR merged with no
review at all and an audit that could only trust self-reported ledger
lines):** the reviewer MUST be a spawned independent subagent (never the
orchestrator reviewing its own or any build-side work — the orchestrator
is a party, not a judge); the reviewer's FULL report must be posted to the
PR (`gh pr comment`) so the record exists outside the run's own files;
merge requires `VERDICT: APPROVE` with no unresolved blocker/major, and the
merge gate checks the posted comment, not the ledger. A PR merged without a
posted reviewer comment is a process violation — retroactive review is
mandatory on discovery (precedent: PRs #51–#61 + #63, reviewed post-merge
2026-11-21).

### Step 3 — merge
1. `CI_GREEN` → `gh pr merge <n> --squash --delete-branch` → `MERGED` →
   ledger merge SHA → `git checkout develop && git pull`.
2. **Close the issue explicitly** — `gh issue close <issue> --comment
   "Fixed in PR #<n> (squash <merge-sha> to develop)"`. This is mandatory,
   not optional: the run's PR bodies carry no `Closes #N` keyword, so
   GitHub's auto-close never fires (observed 2026-11-20 —
   all eleven run issues stayed open after merge and had to be closed by
   hand). Gate: `gh issue view <issue> -q .state` → `CLOSED`.

### Final summary
Ledger `PIPELINE COMPLETE` (or `PIPELINE STOPPED — <reason>`): every PR
number/state/head SHA, what merged, what is left for the human (supervised
rows from #41/#45/#46/#47, any ASSUMPTIONS/BLOCKED entries), device state (all
night AVDs confirmed deleted). Last message of the session mirrors it.

## The unattended contract

Byte-identical in every subagent prompt (after the standing-instructions
line). Never paraphrase per spawn.

```
Standing instructions: read AGENTS.md at the repository root before doing
anything else, and follow it. It routes you to the project documents that
matter for this task and states what "done" means.

This is an UNATTENDED run. There is no human at the terminal and nothing you
do will be approved interactively:
- NEVER call the `question` tool (or any human-confirmation tool), and never
  run anything that blocks on input (no `git rebase -i`, no `--interactive`
  flags, no editors).
- You may read and write ONLY inside the repository working tree and /tmp
  (including subfolders). Nothing else on this machine is in scope. If a task
  seems to need another location, use /tmp/owntone-night/ or record an
  ASSUMPTION and proceed with the in-scope alternative.
- NEVER start audible playback on the OwnTone server (no play/toggle, no
  playback=start, no app play button), never touch devices you did not
  create, never touch the Pixel 6, never create a git remote or GitHub
  repository.
- If something is ambiguous, choose the minimal interpretation consistent
  with the issue spec, record it under ASSUMPTIONS in your report, and
  proceed. Do not widen scope to fix adjacent problems.
- If you are truly blocked (a gate fails three times on the same fix, the AVD
  cannot be created or the server is unreachable > 15 min, the spec is
  ambiguous in a way that changes the shape of the build): stop working.
  Append a ledger entry to docs/overnight-ledger.md (reason, exact git/device
  state, the next action a fresh session would take), commit your current
  work ("WIP: " prefix if gates do not pass), push the branch, kill any AVD
  you started, and return a summary starting with "BLOCKED:".
```

## Hard blocker policy

Triggers: `RUN_UNIQUE` tripped; dirty tree at Step 0; a subagent returns
`BLOCKED:`; a gate fails after allowed retries; review cap reached; the
server unreachable > 15 min; disk < 5 GB; a permission prompt or
doom-loop/recovery prompt appears. On a hard blocker the orchestrator:
appends a full ledger entry, leaves branches committed+pushed, kills every
AVD it started, ends with the summary naming the blocker, does not attempt
the next unit.

## Prompt templates

Each = unattended contract (verbatim) + task block. Spawned via Task tool,
`general` subagent type.

### Build (Step 1)

```
Your task: fix GitHub issue #<n>, spec (frozen):
.ai-dlc/night-2026-11-19/issues/<n>.md. Branch <branch> exists and is checked
out. Read AGENTS.md, then docs/REQUIREMENTS.md (the R-IDs the issue names),
docs/ARCHITECTURE.md, and the code sites the issue names.

Derive/adjust tests from the requirements, citing the R-ID (repo test rule).
Device plan (ledger has the details): create AVD OwnToneNight_API_36, check
server state with curl (if play → skip device steps and record it),
flutter run -d <serial>, verify the behaviour OBSERVABLY via the widget tree /
screenshots / driver taps — a green suite is not evidence of behaviour.
Delet­e the AVD before returning (even on failure).

Commits: commit AND push after each verified step; final commit includes the
docs/SESSION-LOG.md entry. Message style per AGENTS (why, not what).

Before returning: all gates green in the tree; report at
.ai-dlc/night-2026-11-19/reports/<n>.md with every mandatory field; git
status clean; your AVD deleted; final ledger entry appended.

Return (and only this):
- SUMMARY / GATES (verbatim tails) / DEVICE (action → result lines) /
  REPORT path / ASSUMPTIONS / BLOCKERS
```

### Review (per round)

```
Your task: independent code review of PR <n> (<url>) on jptrsn/owntone_remote.
Load the agentic-code-review skill and follow it. Do all work in your own
worktree: git worktree add /tmp/owntone-night/pr<n> <branch>; dependencies
there. The diff is `gh pr diff <n>` — never the worktree's branch state.
Gates to run in the worktree: <cfg:gates>. Behaviour verification is already
recorded in .ai-dlc/night-2026-11-19/reports/<n>.md — cite it, do not re-run
device checks. Ground docs-mcp: ownTone-server, flutter, audio_service,
just_audio, provider. AGENTS.md hard rules + docs/ARCHITECTURE.md are a
contract; open issues #38–#48 (other than this one) and RELEASE-NOTES known
limitations are deliberately open — do not re-report them.
Read-only toward repo and GitHub: no edits, no push, no merges, no gh writes.
Every finding needs evidence (file:line, gate output, concrete failure).
End with exactly:
VERDICT: APPROVE   (no blocker/major)
VERDICT: CHANGES_REQUESTED  (≥1 blocker or major)
```

### Fix (per round)

```
Your task: address these findings on <branch> (main working tree, clean and
pushed). For each: fix, or rebut with evidence (cite the spec line,
invariant, or test). Do not touch anything not on the list.
FINDINGS (round <r>):
<verbatim blocker/major findings>
Before returning: gates green; any behaviour change observed per the issue's
repro plan (evidence appended to the report); each resolution appended under
"## Review round <r>"; committed AND pushed; ledger entry appended; AVD (if
created) deleted.
Return: PER-FINDING (id → fixed <sha> | rebutted <evidence>) / GATES /
DEVICE / ASSUMPTIONS
```

## Crash recovery

Fresh `overnight` session + Kickoff: read this doc, the ledger, ground-truth
via git + open PRs + checks, continue from the latest `next:`.

## Why this is shaped this way (for future readers)

File-based handoffs (ledger/reports/PR comments) survive fresh subagent
contexts and orchestrator compaction; the orchestrator re-runs gates because a
subagent's "green" is a claim; serial because parallel builds+reviews on a
moving base cost a class of failures; the scratch confinement to repo+/tmp is
a user constraint (2026-11-18) enforced by BOTH the contract and the
opencode permission blocks — a prompt appearing means the config drifted,
which is a blocker to fix in the config, never to click through.
