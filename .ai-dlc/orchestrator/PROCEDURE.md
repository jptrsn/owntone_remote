# Orchestrated issue pipeline — unattended plan → build → PR → review → merge

Authoritative process for an **unattended run** that resolves a list of
GitHub issues serially. Per unit: **plan → validate plan → build → PR →
agentic review → (fix → re-review)* → merge → delete branch → close issue →
next unit.** Executed by the **`overnight` agent** session
(`.opencode/agent/overnight.md`) as **orchestrator**, spawning fresh-context
subagents (Task tool, `general` type) — one at a time.

Supersedes `.ai-dlc/overnight/pipeline.md` (kept as a tombstone; the
2026-11-18/19/20 runs' frozen specs and reports under `.ai-dlc/night-*/`
remain historical). Lessons baked in: the 2026-11-21 audit found reviews lost
to orchestrator context compaction, a merged PR with no review record, false
claims in the session log, and issues left open after merge.

**Design rule:** no step's instructions live only in the orchestrator's
context. Every role's detailed procedure is a file the subagent itself reads;
every load-bearing artifact is a file on disk (or a PR comment) before it is
acted on. The orchestrator's context carries pointers, not content.

## What lives where

| File | Audience | Content |
|---|---|---|
| `PROCEDURE.md` (this file) | orchestrator | state machine, gates, blockers, ledger, spawn templates |
| `contract.md` | every subagent | the unattended contract — pasted **verbatim** into every spawn prompt |
| `roles/planner.md` | planning subagent | plan procedure + plan file format + return format |
| `roles/builder.md` | build subagent | build/verify procedure + report format |
| `roles/reviewer.md` | review subagent | review procedure + report format + the one GitHub write it may make |
| `roles/fixer.md` | fix subagent | findings-resolution procedure |
| `run-template.md` | the human, before kickoff | per-run configuration: units, order, authorization, device policy, exceptions |
| `.ai-dlc/night-<date>/run.md` | orchestrator | **this run's** filled template — the only per-run config |
| `docs/overnight-ledger.md` | orchestrator | gitignored append-only state; crash recovery source |

Standing instructions file: `AGENTS.md` (repo root) — quality gates, audio
safety (hard rule 1), device isolation (hard rule 2) apply verbatim to every
role. Review grounding docs via docs-mcp and the review skill
(`agentic-code-review`) per the run config.

## Run prerequisites (before kickoff)

1. A human fills `run-template.md` into `.ai-dlc/night-<date>/run.md`:
   issue numbers + serial order, branch slug plan, AVD name, review cap,
   unit exceptions, device/scratch policy, and the **run authorization**
   sentence (what unattended actions the user approved for THIS run).
   The orchestrator never acts beyond that config.
2. The session starts as the `overnight` agent at repo root. Kickoff message
   (paste as the entire first message):

   ```
   Read .ai-dlc/orchestrator/PROCEDURE.md and the run configuration at
   .ai-dlc/night-<date>/run.md, then execute the pipeline from Step 0.
   This is the unattended run it defines. Do not ask me questions — the
   documents contain the assumptions policy.
   ```

3. If any prerequisite is missing (no run.md, no authorization line), that is
   a **run blocker**: stop, say why, do not improvise a config.

## Roles and spawning

- **Orchestrator** — git/gh mechanics, gate verification (re-runs gates
  itself), ledger, merge decisions, AVD lifecycle supervision, spawn prompts.
  **Never writes feature code, never reviews.** It is a party, not a judge.
- **Planner / Builder / Reviewer / Fixer** — spawned fresh per unit/round via
  the Task tool (`general`). One subagent at a time (serial pipeline). Each
  spawn prompt = the role's template from §Spawn templates + the unattended
  contract **copied verbatim from `contract.md`**. Never paraphrase the
  contract; never recite a role file — the subagent reads its own file.

## The ledger

`docs/overnight-ledger.md` (gitignored, append-only) — the cross-boundary
source of truth. Entry format:

```
## <UTC timestamp> — <STEP NAME>
- actor:      orchestrator | planner | builder | reviewer | fixer
- state:      unit=<n> branch=<b> head=<sha> pr=<n+state> device=<serial|none>
- did:        <what happened, incl. deviations>
- next:       <the exact next action, imperative>
```

**Compaction-survival rules (non-negotiable):**

1. The orchestrator appends an entry **before and after every spawn**
   (before: role + task variables; after: the subagent's key returns —
   verdict, SHAs, paths).
2. Content lives in files, pointers in the ledger: plans, reports, review
   reports (also posted to the PR), fix resolutions. The ledger carries
   paths + verdicts + SHAs, never paragraphs.
3. A review report is written to `/tmp/owntone-night/reviews/<pr>-r<r>.md`
   **and posted to the PR by the reviewer itself at production time** — the
   PR comment is the durable record; the review is never queued for the
   orchestrator to post later, never only in any context. The merge gate
   reads GitHub, not the ledger.
4. After any gap/ambiguity, re-read the ledger and ground-truth via
   `git`/`gh` before acting; continue from the latest `next:`.
5. Each subagent appends its own final ledger entry before returning.

## Per-unit state machine

Gate definitions: §Gates. `BLOCKED:` returns and cap exhaustion are
**unit blockers** (skip, continue); safety/config/environment failures are
**run blockers** (§Blockers) and stop the run.

### Step 0 — preflight (once per run)

1. Confirm `run.md` exists with an authorization line; `RUN_UNIQUE` gate.
2. Create the ledger; `git fetch && git checkout develop && git pull`;
   `git status --short` empty; `gh auth status` ok.
3. For every unit in `run.md`: issue open, no existing branch/PR for it
   (a leftover from a prior run is adopted per its ledger/PR state, not
   silently restarted).

### Step 1 — plan (per unit)

1. Gate `PREVIOUS_MERGED`; `git checkout <base> && git pull &&
   git checkout -b fix/issue-<n>-<slug>` (`<base>` from `run.md`). Ledger entry.
2. Spawn **planner** (issue number, run dir). Ledger before/after.
3. Planner returns `PLAN:`: validate the plan file against the checklist
   below.
   Any check failed → **one** revise spawn carrying the failed items;
   second failure → **unit blocker**: `BLOCKED-SKIP` (record reason, keep
   branch if it has commits — usually it won't; no PR). Proceed to next unit.
4. `PLAN-BLOCKED:` from the planner (spec ambiguous in a way that changes
   the build's shape) → same `BLOCKED-SKIP`; the question goes to the
   morning summary.

**Plan-validation checklist (orchestrator, mechanical — this is the unattended
stand-in for AI-DLC's human inception approval; if any item cannot be checked
from the file, the plan fails):**

- [ ] All mandatory sections present (`INTENT`, `APPROACH`, `TESTS`, `DEVICE`,
      `SAFETY`, `RISKS`, `OPEN-QUESTIONS` empty or answered).
- [ ] Every acceptance criterion traces to a requirement R-ID (or issue AC)
      and to at least one planned test; tests cite R-IDs, not implementation.
- [ ] `APPROACH`'s file set stays inside the issue's scope (no "while we're
      here" files).
- [ ] `SAFETY` enumerates every server/UI action the build or device pass may
      trigger; every playback-capable one is marked supervised/
      `BLOCKED-PENDING-SUPERVISION`; nothing unattended can start audio.
- [ ] `DEVICE` uses only this run's per-unit disposable AVD; Pixel 6 and
      other sessions' emulators absent as targets.
- [ ] No step skips or weakens a quality gate ("comment the test out" = fail).
- [ ] `VERIFY-LIVE` items (assumptions about server/API behaviour) are listed
      for the builder to confirm before coding against them.
- [ ] Nothing requires a human mid-build.

### Step 2 — build

1. Spawn **builder** (issue, frozen spec path, plan path, branch).
2. On return, gate `BUILD_VERIFIED`: the orchestrator re-runs **all** gates
   from `run.md` itself (a subagent's "green" is a claim), checks the report
   has every mandatory field, `git status --short` empty, and
   `adb devices` shows no AVD left running from this unit.
3. Builder returned `BLOCKED:` or a gate fails the third time on the same
   fix → `BLOCKED-SKIP` (branch stays committed+pushed for the human).
4. Push if needed; `gh pr create --base <base> --head <branch> --title
   "<issue title>"` (`<base>` from `run.md`, usually `develop`) — body MUST
   contain `Closes #<n>`, the spec/plan/report paths, and the
   behaviour-verification claim. Gate `PR_OPEN`.

### Step 3 — review loop (round r = 1..cap from run.md)

1. Spawn **reviewer** (PR number, branch, report path, round r,
   deliberately-open list from run.md).
2. Gate `REVIEW_POSTED`: `gh api repos/<repo>/issues/<pr>/comments` must show
   a comment containing `## Agentic Review — PR #<pr> — round <r>` and a
   `VERDICT:` line. Missing → re-spawn once; still missing → `BLOCKED-SKIP`.
3. `VERDICT: APPROVE` with no unresolved blocker/major → `REVIEW_PASSED` →
   Step 4. `CHANGES_REQUESTED`:
   - r < cap → spawn **fixer** with the verbatim blocker/major findings;
     after `BUILD_VERIFIED`-lite (orchestrator re-runs gates on the pushed
     head) → r += 1, repeat from 1.
   - r = cap → **unit blocker**: `BLOCKED-SKIP`. Leave the PR open with the
     findings posted; ledger + morning summary name it. Do not merge.

### Step 4 — merge, delete, close

1. Gate `CI_GREEN` (`gh pr checks <pr>`; one re-run on red per AGENTS CI
   policy, still red = unit blocker). Re-confirm `REVIEW_PASSED` from the
   **posted comment** (fresh `gh api` read, not context).
2. `gh pr merge <pr> --squash --delete-branch` → verify
   `gh pr view <pr> --json state` = `MERGED` → ledger the merge SHA.
3. **Close the issue explicitly** (mandatory — `Closes #n` keywords are not
   trusted): `gh issue close <n> --comment "Fixed in PR #<pr> (squash
   <merge-sha> to <base>)"` → gate `ISSUE_CLOSED`
   (`gh issue view <n> -q .state` → `CLOSED`).
4. `git checkout develop && git pull`. Confirm this unit's AVD deleted
   (create/delete is the builder's and fixer's; the orchestrator verifies
   none survive).

### Final summary (run end)

Ledger `PIPELINE COMPLETE` (or `PIPELINE STOPPED — <reason>`) + final session
message mirroring it: per-unit table (issue, PR, state, merge SHA, issue
state), merged vs `BLOCKED-SKIP` with reason, pending supervised rows,
assumptions recorded, server state (verified `pause`), device state (all
this run's AVDs confirmed deleted).

## Gates

| Gate | Between | Check |
|---|---|---|
| `RUN_UNIQUE` | start | ledger absent, or last entry > 2 h old; < 30 min old with `next:` ≠ `PIPELINE COMPLETE` → stop |
| `PREVIOUS_MERGED` | unit start | prior unit's PR `MERGED` (or recorded `BLOCKED-SKIP`) |
| `PLAN_VALIDATED` | plan → build | plan file passes the checklist; one revise allowed |
| `BUILD_VERIFIED` | build → PR | orchestrator re-ran all gates; report complete; clean tree; no AVD left |
| `PR_OPEN` | build → review | `gh pr view <pr>` ok; body has `Closes #<n>` |
| `REVIEW_POSTED` | review → decision | posted comment with marker + `VERDICT:` |
| `REVIEW_PASSED` | review → merge | posted latest-round comment says `VERDICT: APPROVE`, no unresolved blocker/major |
| `CI_GREEN` | merge | `gh pr checks <pr>` green (one re-run on red) |
| `MERGED` | merge → close | PR state `MERGED` |
| `ISSUE_CLOSED` | unit end | issue state `CLOSED` |

## Blockers

**Run blockers — stop the run immediately:** a permission prompt or
doom-loop/recovery prompt appears (config drift — never click through);
any audio-safety or device-isolation violation (stop, verify server
`pause`, ledger); `RUN_UNIQUE` tripped; dirty tree at Step 0; server
unreachable > 15 min; disk < 5 GB; two consecutive units blocked on the
same environmental cause (AVD creation, flaky harness) — that is the
environment, not the units. On a run blocker: full ledger entry, branches
left committed+pushed, kill every AVD this run started, final summary names
the blocker.

**Unit blockers — `BLOCKED-SKIP` and continue:** planner `PLAN-BLOCKED:` or
plan fails validation twice; builder `BLOCKED:`; `BUILD_VERIFIED` fails after
three same-fix attempts; review cap exhausted; CI red after its one re-run.
Precedence: a `BLOCKED:` return whose cause appears on the run-blocker list
(e.g. server unreachable > 15 min) is a **run** blocker, not a unit blocker.
Record in ledger + summary; leave branch/PR for the human. Never merge on a
skipped gate; never mark a skipped unit done.

## Review-integrity hard rules

(after the 2026-11-21 audit — a docs PR merged with no review, reviews lost
to compaction, an audit that could only trust self-reported ledger lines):

1. Reviewers are spawned independent subagents, never the orchestrator or
   any build-side actor.
2. The reviewer's **full report** must be posted to the PR by the reviewer
   itself before it returns (file + PR comment, same content).
3. Merge requires the posted `VERDICT: APPROVE` (gate `REVIEW_PASSED` reads
   GitHub). A PR merged without a posted reviewer comment is a process
   violation → retroactive review is mandatory on discovery.
4. Fixers resolve findings by fix **or evidence-based rebuttal**; a rebuttal
   must cite the spec line, invariant, or test. The round's resolutions are
   appended to the report under `## Review round <r>`.

## Evidence and truthfulness rules

(the 2026-11-21 audit found session-log claims contradicted by the session's
own logs — these are contract-level obligations for builder/fixer/reviewer):

1. Every claim in a report, SESSION-LOG entry, or PR body cites an artifact:
   the command + verbatim output tail pasted into the report, or a committed
   file path (+line/serial/timestamp). "Console was clean" without a pasted
   grep is not evidence.
2. Mechanism stories ("X caused Y") are labelled hypothesis unless measured.
   Numbers in claims must be reproducible; the reviewer re-derives
   load-bearing figures independently.
3. Corrections are **append-only** (`§ Corrections` in the affected report /
   SESSION-LOG entry); never rewrite history in place.
4. A green suite is not evidence of behaviour: `OBSERVED` rows are
   action → result per device check; withheld checks say WITHHELD and name
   the substitute test proof.
5. Mutation experiments restore from a backup copy, never
   `git checkout -- <path>` (it silently reverts uncommitted work — the
   PR #4 fabricated-evidence lesson).

## Process invariants — do not re-litigate mid-run

1. Serial pipeline; one subagent at a time; every unit runs the same flow —
   exceptions live in `run.md`, never invented mid-run.
2. No permission prompts by design; no harness/permission config changes
   mid-run. A prompt appearing = config drift = run blocker.
3. The unattended contract (`contract.md`) is byte-identical in every spawn
   prompt, after the standing-instructions line.
4. Commit/push/merge happen only where this document names them, within the
   `run.md` authorization.
5. The orchestrator never writes feature code and never reviews.

## Spawn templates

Each = the lines below + the **unattended contract verbatim** + the role's
`Return` block (the role file repeats it; keep both in sync). Fill every
`<placeholder>`; nothing else in the prompt.

```
Standing instructions: read AGENTS.md at the repository root before doing
anything else, and follow it.

Then read .ai-dlc/orchestrator/roles/<role>.md and follow it exactly — it is
your role contract for this task. This is an UNATTENDED run.

<CONTRACT — copy verbatim from .ai-dlc/orchestrator/contract.md>

Task: <role-specific variables per the role file's Inputs section:
issue #<n>; run dir .ai-dlc/night-<date>; branch <b>; plan/report/review
paths; round <r>; verbatim findings (fixer only)>
```

## OpenHands Software Factory mapping (default maintenance path, 2026-11-22)

Issue-driven maintenance runs on OpenHands Software Factory automations
against this repo. This document's roles map onto the factory's:

| Factory automation | This document | Binding obligation |
|---|---|---|
| factory-triage | run-config intake + plan-validation checklist | acceptance criteria + R-ID trace before `ready-for-dev`; anything needing host tools gets `needs-host-tools`, never `ready-for-dev` |
| factory-developer | planner + builder | branch off `<base>`, gates green before PR, report-style evidence in the PR body (`SUMMARY`/`GATES`/`OBSERVED`/`ASSUMPTIONS`), SESSION-LOG entry in the final commit |
| factory-reviewer | reviewer | independent of the developer; posts its FULL report to the PR with the `## Agentic Review — PR #<pr> — round <r>` marker + exactly one `VERDICT:` line; contract = AGENTS.md hard rules + docs/ARCHITECTURE.md + § Evidence and truthfulness rules |
| delivery watchdog | Step 4 merge gates | the watchdog is deterministic — it merges only a current branch with passing independent **acceptance statuses** (recorded by the reviewer at the exact head) + green `gates` Actions runs; the reviewer's posted full report (marker + `VERDICT:` line) is its own contract obligation and the durable record the audit trail and the host merge gate read; after merge, **explicit `gh issue close` with a comment** (never trust the keyword) |

What survives the harness change: the Gates table, Review-integrity hard
rules, Evidence and truthfulness rules, GitFlow, and the close mandate.
What is opencode-specific (Task-tool spawns, `run.md`, the ledger, AVD
lifecycle) applies to host-side unattended runs only — and those runs
remain the ONLY thing that touches devices or the OwnTone server, per
AGENTS.md § Maintenance model. A factory agent that cannot verify a
criterion without hardware records it `BLOCKED-PENDING-HOST-VERIFICATION`
and requests the `needs-host-tools` label; fabricating device evidence is
the repo's worst recorded failure mode and is a blocker-class finding.

## Crash recovery

Fresh `overnight` session + the kickoff message: read this file + `run.md` +
the ledger, ground-truth via `git branch -a`, open PRs, `gh issue view`
states, `adb devices`; continue from the ledger's latest `next:`. Anything
the ledger asserts that GitHub contradicts: GitHub wins — correct the ledger
(append, never edit) and proceed.

## Why this is shaped this way (for future readers)

File-based handoffs (ledger, plan, report, posted review) survive fresh
subagent contexts and orchestrator compaction; the orchestrator re-runs gates
because a subagent's "green" is a claim; the plan step exists because the
2026-11-19 run started eleven units straight into build and several
adjudications (sort key, position semantics, plugin choice) were made
mid-build under context pressure — a checklist-validated plan moves that
judgement to a dedicated fresh context where it can be audited before code
exists; skip-and-continue because one stuck issue must not strand the other
ten, while every skip stays visible; reviews posted by the reviewer itself
because end-of-run posting is what lost the 2026-11-19 review record to
compaction. Prompt authoring follows the `prompt engineering guide` library
(specificity, role/task/context/process/constraints sections, task
decomposition, explicit output format, evidence-per-finding) and the
`ai-dlc-method` model (persisted artifacts as context memory; validation
steps as loss functions pruned before downstream waste).
