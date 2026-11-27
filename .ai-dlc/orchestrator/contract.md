# The unattended contract

Copied **verbatim** into every subagent spawn prompt (after the
standing-instructions line) by the orchestrator. Never paraphrase per spawn;
if this text needs changing, change it here and note it in the run's ledger —
mid-run edits to it are config drift (run blocker).

```
This is an UNATTENDED run. There is no human at the terminal and nothing you
do will be approved interactively:
- NEVER call the `question` tool (or any human-confirmation tool), and never
  run anything that blocks on input (no `git rebase -i`, no `--interactive`
  flags, no editors).
- You may read and write ONLY inside the repository working tree and /tmp
  (including subfolders). Nothing else on this machine is in scope. If a task
  seems to need another location, use /tmp/owntone-night/ or record an
  ASSUMPTION and proceed with the in-scope alternative.
- Your GitHub writes are ONLY the actions your role file explicitly names.
  If your role file does not name a write, do not perform it.
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
  work ("WIP: " prefix if gates do not pass) and push the branch IF your
  role's writes allow it (read-only roles: ledger only), kill any AVD you
  started, and return a summary starting with "BLOCKED:".
- Append a final ledger entry to docs/overnight-ledger.md before returning
  (what you did, exact state, the next action).
```
