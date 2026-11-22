# .ai-dlc — how this repo uses ai-dlc (manual mode)

The full ai-dlc plugin/harness is **not** installed; we apply the
methodology as repo artifacts + discipline. (Methodology reference:
docs-mcp `ai-dlc` — intents with quality gates, small units with explicit
completion criteria, backpressure, file-based memory for handoff.)

## Layout

```
.ai-dlc/
├── settings.yml
├── orchestrator/          # unattended issue pipeline (authoritative process)
│   ├── PROCEDURE.md       #   orchestrator state machine + gates + spawn templates
│   ├── contract.md        #   unattended contract, pasted verbatim into subagent prompts
│   ├── run-template.md    #   per-run config → .ai-dlc/night-<date>/run.md (human-filled)
│   └── roles/             #   per-subagent role contracts: planner, builder, reviewer, fixer
├── overnight/             # DEPRECATED pointer (history in git)
└── <intent-slug>/
    ├── intent.md          # frontmatter (quality_gates, status) + Problem /
    │                      #   Solution / Domain Model / Success Criteria / Context
    ├── discovery.md       # environment + findings (where relevant)
    └── units/NNN-<slug>.md
```

**Unattended runs** (issue list → merged PRs): follow
`orchestrator/PROCEDURE.md`; the orchestrator spawns planner → builder →
reviewer →(fixer ↺ reviewer)* per issue per AGENTS.md § "ai-dlc discipline".
**OpenHands Software Factory** is the default maintenance path for issue
work (AGENTS.md § "Maintenance model"); `orchestrator/PROCEDURE.md` §
"OpenHands Software Factory mapping" carries its repo contract, and
`.agents/skills/device-bound-work/` keeps device steps host-side.
This file's unit/backpressure discipline below still governs manual work and
is what the roles' "done means" derives from.

## Intent lifecycle

`planned → active → done | aborted`. Only one intent is `active` at a time,
except `audio-service-spike` ∥ `retune-ux-capture` (they're independent;
PLAN §10).

## Unit lifecycle

Frontmatter `status`: `pending → in_progress → done | blocked`.
A unit is **done** only when ALL of:

1. every completion criterion verified, **evidence pasted into `## Result`**
   (command + output, or timestamped device observation);
2. the intent's quality gates pass (commands in `intent.md` frontmatter —
   run them, paste the tail of the output into `## Result`);
3. device behaviour observed where the criterion requires it;
4. session log entry appended;
5. committed (`<intent>/<unit>: <why>`).

`blocked` means: state what's missing (device? user decision? supervision?)
and the exact next action in `## Result`.

**Backpressure:** a failing gate is data, not an obstacle. Fix and re-run.
Never mark done with failing criteria. Never rationalize.

## Supervised steps

Criteria marked `supervised: true` need the user present + explicit
confirmation for the specific action (audio safety, AGENTS.md §1). Unattended
→ **skip** and record `BLOCKED-PENDING-SUPERVISION` for that criterion only;
the unit can still be done if every *non-supervised* criterion passed and
the unit notes list the pending supervised remainder.

## Picking the next unit

`docs/SESSION-LOG.md` last entry says what to do. Otherwise: the lowest
`pending` unit in the active intent, respecting intent order (PLAN §8).

## Context economy

For a unit, read: `AGENTS.md` (always), the intent file, the unit file,
plus only the docs the unit names. Do not load all of `docs/` or other
intents into context.

## Deviations from full ai-dlc

- No plugin worktrees/branches: single repo, commit per unit on `main`.
- No harness-enforced stop hooks: gates are enforced by discipline (paste
  output into `## Result`); a reviewer session may re-run gates.
- `discovery.md` only where findings exist (spike).
