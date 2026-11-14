---
name: 012-refresh-serialization-hardening
status: done
intent: remote-app
supervised_steps: []
---

# Unit 012 — Player/Outputs: serialize per-event refreshes (unit-011 shape)

R-IDs: R-04 (transport state reflects the server), R-09 (outputs list
reflects the server), R-02 (D2: every event is an invalidation → refetch
of the affected slice). Origin: the candidate recorded in unit 011's
Result — `PlayerController._refreshAll`
(`lib/src/player/player_controller.dart:88`) and `OutputsController._refresh`
(`lib/src/outputs/outputs_controller.dart:95`) share the unguarded shape
that produced unit 009's stale queue chip: overlapping WS events fire
`GET /api/player`(+`/api/nowplaying`) / `GET /api/outputs` concurrently,
and an older response can land after a newer one and clobber the slice.
Approved by the user 2026-11-14 (SESSION-LOG) together with the CI pin
bump; also carries the reviewer's final PR #4 nit: a delivery-confirmed
gate on the unit-011 test-2 burst.

## Goal

1. **Both controllers become single-flight + coalesced trailing refetch**
   (exact unit-011 shape: in-flight guard, `_pendingRefresh` coalescing,
   do/while trailing loop, dispose break before notify) — events arriving
   during a fetch are never lost, and responses can never land out of
   order.
2. **Actions keep the post-commit read**: each controller's `_action`
   sets `_pendingRefresh = true` before awaiting the confirming refetch
   (unit-011 round-1 lesson — coalescing onto the pre-commit fetch
   silently weakened the guarantee there).
3. **Test-2 delivery gate**: the queue burst test asserts the burst was
   HANDLED (probe count) before it judges the outcome — a stalled
   delivery becomes an honest red instead of sparing a broken impl
   (PR #4 re-review nit).

Non-goals: debouncing; touching `QueueController` (done, unit 011);
`refreshState()` one-shot guardrail reads (different contract — always
fetches); `LibraryController`'s paged fetches (different shape, not
event-driven refetch).

## Steps / notes

- TDD: contract tests first (RED), committed before the impl (unit-011
  protocol, including the honest RED run pasted into `## Result`).
- Kill-checks after GREEN: skipping guard, trailing-loop removal,
  concurrent (guard removed) — each must redden the new tests; restore
  from a BACKUP COPY, never `git checkout --` (AGENTS trap: it silently
  reverted unit-011's uncommitted strengthening once).
- Player note: `_refreshAll` chains TWO GETs (player + now-playing) —
  the guard must cover the whole chain; the burst test counts
  `GET /api/player` arrivals.
- Shared server untouched by tests (fakes only). On-device step uses the
  Pixel 6 (user decision 2026-11-14: THE test device) if run; the
  external mutations are server-API output-selection / volume writes —
  safe while `state == pause` (AGENTS §1); snapshot → restore, verify
  byte-identical. Re-verify `state` immediately before; NEVER start
  audio.
- CI runs on the 3.47.9 pin (post PR #5); format with the host formatter
  — it is the gate formatter now.

## Completion criteria

1. **Contract tests (RED→GREEN, never edited after GREEN):**
   a. *player stale-write + burst serialization*: burst of volume events
      with a mid-burst server-side volume change → max 1 concurrent
      `GET /api/player` and the final slice shows the LAST value (red
      today: concurrent + clobber; red under a skipping impl: last value
      lost).
   b. *outputs burst serialization*: burst of `outputs` events with a
      mid-burst selection change → max 1 concurrent `GET /api/outputs`,
      `arrivals == 2` (A + exactly one trailing), final list matches the
      fixture (red today).
   c. *action demands post-commit refetch*: with a fetch in flight
      during a (fake) action, the post-action state must be re-read
      after the action committed (arrivals/fixture observation).
   d. *test-2 delivery gate*: the queue burst test fails if probe < 4
      before judging (stalled delivery → honest red, not green).
   e. All pre-existing player/outputs/queue tests green unedited.
2. **Kill-checks** (per controller): skip → new tests red; no-trailing →
   trailing assert red; concurrent → concurrency assert red. Restore
   from backup; `git status` clean.
3. **Gates green + debug APK** (AGENTS verbatim, 3.47.9 pin).
4. **On-device (Pixel 6)**: external outputs/volume change (paused,
   snapshot→restore) converges on-screen. Server byte-identical, no
   AVDs, `state == pause` throughout.
5. **SESSION-LOG entry + commits** `remote-app/012: …`.

## Result

**DONE 2026-11-14 (after one request-changes round — see § Review).**
Commits: `796364b` contract (RED), `a91c8d3` pre-green contract fix
(missing `await pump(60)` in the stale-write test — unit-011 `aa778e0`
precedent), `f067039` impl, `3bbdf28` formatter-only (pure formatter
output on the two new test files, 26ddef4 precedent), `b0ceb0e` review
round-1 contract addition (criterion-1c tests), `ee168a5` review nit
(comment).

### 1. Contract tests (RED → GREEN)

Baseline (impl unguarded, at contract commit `a91c8d3`): player group
`R-04 refresh serialization (unit 012)` **`+0 -2`** — BOTH shipped tests
(stale-write race + burst serialization) red; new
`test/outputs_refresh_serialization_test.dart` group `R-09 refresh
serialization (unit 012)` **`+0 -2`** (both tests red). (PR #6 review
correction: an earlier wording here claimed "stale-write passes baseline"
and named a red "action-post-commit" test — both wrong; the stale-write
tests were red at baseline after the `a91c8d3` pump fix, and no 1c test
existed yet. Reviewer reproduced the reds; the numbers above are the true
shipped reality.)
GREEN after `f067039`: full suite `flutter test --exclude-tags live` →
**`+425`**; with the round-1 1c tests (`b0ceb0e`): **`+427: All tests
passed!`** (421 pre-existing, all unedited, + 6 new).
Criterion 1c (added in review round 1): one test per controller — an
event fetch holds answering from a PRE-action request-time snapshot while
the action's PUT commits; the slice must end at the committed value with
A plus exactly ONE trailing fetch. RED under M2 (trailing removed) and
under M4 (coalesce-without-demand — the unit-011 round-1 bug shape,
reproduced red). RED evidence nuance, stated honestly: M3 (deleting only
the `_action` `_pendingRefresh = true;` demand line) keeps the suite
green — with the guard's coalesce branch setting the same flag, the line
is an **equivalent mutant** in the current shape (defense-in-depth for a
future coalesce-branch regression); the pinned behavior is the post-commit
observation itself, which M2/M4 redden.
The same test first exercised the player volume-PUT responder branch: the
query param arrives as an int, so the shipped `int.parse(v)` threw and
`_action`'s catch silently swallowed it — now `int.parse('$v')`
(`b0ceb0e`; the class of bug where a green suite hides untested fake
paths).
Criterion 1d: the queue burst test now carries a delivery-confirmed gate
(`expect(probe, 4, …)` before judging the outcome — green-now,
red-if-stalled; mid-test `cancel()` from the fake zone hangs the next
`runAsync`, so the probe is read at the trailing check and the
subscription is cancelled only via `tearDown`).

Harness wrinkle found mid-RED: the responder hold must arm on the **next**
arrival — the initial load already consumed a count, so a fixed-index hold
never held and the first run was vacuously green.

Impl notes: `PlayerController._refreshAll` = guarded wrapper +
`_refreshChain` (guard covers BOTH GETs — player + now-playing; the burst
test counts `/api/player` arrivals). `refreshState()` keeps its unit-004
always-fetch contract by bypassing the guard **but still notifies** —
RatingController mirrors the slice via that notification; the first impl
dropped the notify and `stop clears the rating slice` went red (pinned).
Both `_action`s set `_pendingRefresh = true` before the confirming await
(unit-011 round-1 lesson).

### 2. Kill-checks (restored from `cp` backups, never `git checkout --`)

| Mutation | Player group | Outputs group |
|---|---|---|
| guard skips (always refetch) | red `+0 -2` | red `+0 -2` |
| trailing-loop removed | red (trailing assert) | red (trailing assert) |
| concurrent (guard removed) | red (concurrency assert) | red (concurrency assert) |
| M3: `_action` demand line only | green — equivalent mutant, see §1 | green — same |
| M4: coalesce-without-demand (round-1 shape) | 1c test red | 1c test red |

`git status` clean after every restore (lib files md5-verified against
pre-mutation copies: player `ade24c18…`, outputs `58156ac8…` — the same
md5s the independent reviewer later recorded from their own restore).

### 3. Gates + APK (host==CI 3.47.9)

`flutter build apk --debug` succeeded (installed on-device below).
Gates re-run at final HEAD `ee168a5`: `flutter analyze` → **No issues
found!**; `dart format --output=none --set-exit-if-changed .` → **93
files, 0 changed**; `flutter test --exclude-tags live` → **+427: All
tests passed!** (at `3bbdf28` pre-review: 425/425.)

### 4. On-device (Pixel 6 `25071FDF600953`, THE test device — user decision 2026-11-14)

Debug APK on `dev.educoder.owntone_remote`, `flutter run --debug`
(`--dart-define` server 192.168.1.13), screen kept awake.
`flutter_driver` extension not enabled and uiautomator a11y dead → oracle
was the live widget tree read from the VM via `evaluate_expression`
(AGENTS recipe). Server `state=pause` verified immediately before and
around every write; baselines saved to `/tmp/u012/{player,outputs}.baseline.json`.

```
VM read  (baseline)              → "Playing via: Volumio Kitchen||73"
PUT /api/outputs/set {"outputs":["207183922776680","0"]}  → 204   (Server/ALSA added)
VM read  (no UI interaction)     → "Playing via: Volumio Kitchen, Server||73"   ← outputs slice converged
PUT /api/outputs/set {"outputs":["207183922776680"]}      → 204   (restore)
PUT /api/player/volume?volume=50                            → 204
VM read  (no UI interaction)     → "Playing via: Volumio Kitchen||50"           ← player slice converged + restore converged
PUT /api/player/volume?volume=73                            → 204
diff vs baselines (python dict-equal) → player IDENTICAL, outputs IDENTICAL
GET /api/player                                             → state pause (throughout; audio never started)
```

Note: the first selection target (`Will clock`, Chromecast) returned
400/500 server-side — the AGENTS-documented broken Chromecast outputs;
switched to the two reliable outputs (Volumio Kitchen AirPlay + Server
ALSA). `flutter run` killed, `svc power stayon false` restored, no AVDs
created.

### 5. Wrap

SESSION-LOG entry appended; pushed as stacked PR against
`ci/flutter-3.47.9` (retarget to `main` once PR #5 merges).

### 6. Review (PR #6)

Round 1 (independent reviewer, own worktree, no device/server access):
**request-changes** — two majors, both upheld and fixed in `b0ceb0e`:
(1) criterion 1c had no test (reviewer's M3 mutation stayed green —
added the two 1c tests, killed under M2/M4, M3 documented as equivalent
mutant); (2) this Result's §1 misreported the baseline color and named a
non-existent red test (corrected above). Minor (judgment, refreshState
raw-vs-guarded overlap) taken as comment `ee168a5`. All four gates and
kill-checks M1/M2 reproduced independently by the reviewer; on-device
criterion accepted on this unit's evidence (reviewers are barred from the
shared server by design).
