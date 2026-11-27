# DEPRECATED — superseded by .ai-dlc/orchestrator/

This document was the authoritative overnight process for the 2026-11-18 run
(issues #19–#26) and the 2026-11-19 run (issues #38–#48). It is **no longer
the process**; its history is preserved in git, and its lessons (review
integrity, explicit issue close, tap-safety, compaction survival) are
carried forward — generalized and split into role files — in:

- **`.ai-dlc/orchestrator/PROCEDURE.md`** — the state machine + gates
  (orchestrator reads this),
- `.ai-dlc/orchestrator/contract.md` — the unattended contract,
- `.ai-dlc/orchestrator/roles/*.md` — per-subagent role contracts
  (planner / builder / reviewer / fixer),
- `.ai-dlc/orchestrator/run-template.md` — per-run config, instantiated by
  the human as `.ai-dlc/night-<date>/run.md`.

Do not execute this file. Do not edit it except to correct a historical
statement.
