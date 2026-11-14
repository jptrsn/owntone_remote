---
name: 012-refresh-serialization-hardening
status: in_progress
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

(pending)
