# Run configuration template

Copy to `.ai-dlc/night-<YYYY-MM-DD>/run.md` before kickoff, fill every
`<placeholder>`, and have the **user** confirm the authorization line. The
orchestrator runs nothing this file does not name.

```markdown
# Run <YYYY-MM-DD> — configuration

## Authorization (user-confirmed — the run does not start without it)
The user authorized, on <date>, unattended: plan, build, commit, push,
review, fix, squash-merge to <base>, branch deletion, and issue closure —
ONLY for the units listed below, within the limits of AGENTS.md (no audible
playback, no repo creation, no devices outside the per-unit night AVD, no
library mutations). <anything extra authorized or explicitly withheld>

## Units
| order | issue | slug | notes |
|---|---|---|---|
| 1 | #<n> | <slug> | <frozen-spec quirks, expected R-IDs> |
| 2 | #<n> | <slug> | |

Branch per unit: `fix/issue-<n>-<slug>` off <base>. Serial, in this order.

## Config
| Key | Value |
|---|---|
| repo | `<owner>/<repo>`, remote `origin`, base **`<base>`** (usually `develop`), merge **squash** (`gh pr merge <n> --squash --delete-branch`) |
| gates | `flutter analyze` (0) · `dart format --output=none --set-exit-if-changed .` · `flutter test --exclude-tags live` · `flutter build apk --debug`. Expect `analysis_options.yaml` churn from analyze — commit it. |
| external deps | OwnTone server `<ip>` (REST :3689, ws :3688, v<ver>) — shared; GET freely; safe unattended per AGENTS §1 (pause/stop/seek/volume/queue-edit-without-start/output-toggle-while-paused/reads); NEVER any playback-capable call or tap. Reliable outputs for routing tests: <list>. No library mutations, no `/api/update|/api/rescan`. |
| device policy | Per-unit disposable AVD `<AvdName>` (`android-36 google_apis`, arm64), created AND deleted by the unit (incl. on blockers); serial via `getprop ro.boot.qemu.avd_name`; never touch another AVD / `emulator-5554` / Pixel 6. Harness: MCP-first, uiautomator+screencap fallback. Hard interaction rules: fresh widget dump immediately before every `input tap` + `topResumedActivity` is the app; red-screen grep per step; brightness pin for luma checks; no held press within ~150 px of the nav-bar edge. |
| review grounding | `agentic-code-review` skill; docs-mcp: `owntone-server`, `flutter`, `audio_service`, `just_audio`, `provider`. Contract: AGENTS.md hard rules + docs/ARCHITECTURE.md. Deliberately-open (do not re-report): the OTHER run issues + docs/RELEASE-NOTES.md known limitations. |
| review cap | <r> rounds (default 3) |
| unit exceptions | <per-issue: rows whose criteria need audible playback → pre-declare BLOCKED-PENDING-SUPERVISION with substitute proof; any special rulings> |
| scratch | `/tmp/owntone-night/` + repo working tree only |
| ledger | `docs/overnight-ledger.md` (gitignored, never committed) |
```

## Notes for the human filling this

- Order units so independent UI lands first and shared-scaffold/server-
  semantics work later; discovery/riskier integration last.
- Every unit must be buildable unattended: if an issue's whole point needs
  audible playback or the Pixel 6, keep it out of the run and schedule a
  supervised pass instead.
- The authorization line is a scope contract, not a formality — the
  orchestrator's permission blocks (`.opencode/agent/overnight.md`) enforce
  its negative space.
