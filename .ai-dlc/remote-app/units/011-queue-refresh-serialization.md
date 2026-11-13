---
name: 011-queue-refresh-serialization
status: done
intent: remote-app
supervised_steps: []
---

# Unit 011 — QueueController: serialize per-event refreshes

R-IDs: R-11 (Queue — "queue list matches the server"; "WS `queue` events
refresh the list"), R-02 (D2: every event is an invalidation → refetch of
the affected slice). Origin: the race candidate recorded in unit 009's
Result (SESSION-LOG 2026-10-28 resume list, item 2): while another session
churned the shared server's queue (0 → 1514 → 0), the app's queue chip
showed a stale count — `QueueController._refresh`
(`lib/src/queue/queue_controller.dart:87-103`) fires unserialized on every
WS `queue` event, so overlapping `GET /api/queue` responses can land
**out of order** and the older one clobbers the newer (`_queue = await
api.getQueue()` with no in-flight guard).

## Goal

1. **Per-event refreshes are serialized**: at most one `GET /api/queue`
   in flight per controller at a time; requests triggered while one is
   running are **coalesced into a trailing fetch** after the in-flight one
   completes (not dropped — the final list must match the server's state
   as of the *last* event, R-11 "matches the server").
2. **No stale-write regression**: a refresh whose response was produced
   from pre-event server state can never overwrite the list after a newer
   refresh has already landed (last-event-wins is the observable rule).
3. User actions keep their contract: `clear()` optimistic + rollback,
   `playUris()` supervised, post-action `_refresh()` still awaited
   (unit 005b tests must stay green unedited).

Non-goals: same-pattern hardening in `PlayerController`/`OutputsController`
(smaller slices, no observed staleness — noted in `## Result`, not built
here); debouncing (this is single-flight + trailing, not a timer).

## Steps / notes

- TDD: contract tests in `test/queue_screen_test.dart` (new group,
  test-authored first, RED against the current `_refresh`), then the
  minimal controller change. Do not edit the pre-existing queue tests.
- The burst test must distinguish "skip while in flight" (breaks R-11:
  events arriving during a fetch get lost) from "trailing refetch":
  mutate the fixture **after** the first fetch starts → the stale
  in-flight response must not be the final state.
- Shared server untouched by the tests (fakes only). Any on-device
  confirmation uses the dv-003 AVD window or an unattended
  snapshot/restore queue edit (AGENTS §1: no `playback=start`).

## Completion criteria

1. **Contract tests (RED→GREEN, never edited after GREEN):**
   a. *stale-write*: event 1's fetch is held in flight; fixture changes;
      event 2's fetch lands (new list visible); event 1's response then
      lands → the list **still shows event 2's state** (red today: the
      late response clobbers it).
   b. *serialization + trailing*: burst of 5 events with a mid-burst
      fixture change → **max 1 concurrent** `GET /api/queue` (red today)
      **and** the mid-burst track is present after settle (red under a
      naive skip-while-in-flight impl).
   c. All pre-existing queue tests (005b set) green unedited;
      `git diff <contract>..HEAD -- test/` empty.
2. **Kill-check:** remove the in-flight guard → test (b) red; remove the
   trailing refetch → test (b)'s presence assert red; both restored green.
3. **Gates green + debug APK** (AGENTS.md quality gates verbatim).
4. **On-device:** in the dv-003 AVD run on this unit's HEAD, an external
   queue mutation (server API add/delete without `playback=start`,
   snapshot → restore, byte-identical) converges in the chip + list.
5. **Server unmutated** (start == end snapshot), **no AVDs remain**.
6. **SESSION-LOG entry + commit** `remote-app/011: …`.

## Result

**Status: DONE (2026-11-13).**

- **Contract (test-author first, RED at baseline):** two tests in
  `test/queue_screen_test.dart` group `R-11 refresh serialization
  (unit 011)`, committed at `96730f3` before any impl. The first
  contract revision asserted an impossible interleaving (event 2's
  fetch *landing* while event 1's was still in flight contradicts
  single-flight) — fixed to a FINAL-state oracle in `aa778e0` **before
  GREEN**; the fix was re-verified RED at baseline by stashing the
  impl (`git stash push lib/src/queue/queue_controller.dart`).
  Baseline RED reasons were the two exact oracles: (a) `Fresh Change`
  gone after the late stale response (0 widgets); (b) `maxInFlight ==
  3` under the burst.
- **Impl (`5f27e55`):** single-flight + coalesced trailing fetch in
  `_refresh` (in-flight guard sets `_pendingRefresh`; do-while re-fetches
  after the last event; `_disposed` breaks the loop; `_action`'s
  post-action `await _refresh()` contract kept).
- **Test hardening (`4885ddb`, pre-final):** the gates moved from blind
  delays + Completers to **polling flags with request-arrival
  synchronisation** — a Completer created in the testWidgets
  (fake-async) zone deadlocks a waiter inside `runAsync` (deadlock
  observed: `TimeoutException` 2 s on `firstArrived`), and blind delays
  let A's request-time snapshot race past the mid-burst change,
  letting a skip-impl survive a kill-check. Responses are snapshotted
  at **request** time (a real server answers from
  request-handling state; response-time reads hid the lost-trailing
  oracle), and all five burst events provably land inside the 45 ms
  in-flight window.
- **Kill-checks (final tests):** delete the trailing loop
  (`while (false)`) → **both** tests red ((a) stale list kept, (b)
  `Burst Track` lost — skip-impl dies); delete the in-flight guard
  (`if (false)`) → **both** red ((b) via `maxInFlight`, (a) via
  clobber). Restored: **16/16**, green on 3 consecutive runs.
  Pre-existing queue tests (005b set) green unedited.
- **Gates (final tree):** analyze 0 issues · format 0 changed (92 files)
  · `flutter test --exclude-tags live` **421/421** · debug APK ✓ +
  release APK 54.6 MB (`926a6be`).
  *PR #4 review addendum:* the "format 0" row quoted the host toolchain,
  which brew had drifted to 3.47.9 while CI pins 3.41.7 — `26ddef4`
  reformatted three main-green test files under the wrong formatter and
  reddened the gates job. Those files are restored to their main bytes
  (byte-identical to a pinned-CI-green tree); the pinned CI is the
  format gate and is green at the PR #4 fix commit. `dart format` on the
  host reports those 3 files "Changed" — expected, do not act on it.
  The `_action` post-action refresh now forces `_pendingRefresh` before
  awaiting so a resolved action always re-reads post-commit state
  (reviewer minor; 421/421 stands).
  *Test 2 oracle-strength nit — taken:* A is now held 150 ms (6× the
  burst's ~25 ms firing window) instead of 45 ms, A-only (the trailing
  refetch answers promptly), and the test iterates settles until the
  trailing fetch arrives, then asserts `arrivals == 2` (A plus EXACTLY
  one coalesced trailing). Evidence: skip-impl, no-trailing and
  concurrent mutations all make both unit-011 tests red; the reviewer's
  decisive scenario (skip-impl × 80 ms event spacing — the case that
  SAVED the skip impl under the 45 ms hold) is now red; 10/10 green
  stress. Harness facts learned (they burned a long detour and will
  burn the next editor too): responder `Future.delayed`s tick on real
  time that flows ONLY inside `runAsync` windows — `pump()` does not
  advance them and a looped-hold variant starves; `pump(Duration(1s))`
  deadlocks in fake-async elapse re-entry (50 ms steps are the proven
  granularity); `settle()` = 80 ms runAsync + 3×50 ms pumps, so hold
  durations must be budgeted against the runAsync window, not the pump
  total.
- **Criterion 4 (on-device, release build, dv-003 window):** with the
  queue screen open on `OwnToneVerify003_API_36`, external
  `POST /api/queue/items/add` (no `playback=start`) → row +
  `now playing` marker present ≤3 s; `DELETE /api/queue/items/198830`
  → empty state + `count: 0` ≤3 s; `GET /api/player` `state=stop`
  throughout; queue snapshots start == end (0 items). Full rows +
  harness notes: `device-verification/003` § Result (Step 2
  "queue WS convergence" row, Baseline block).
- **Follow-up noted, not built (same pattern elsewhere):**
  `PlayerController`/`OutputsController` `_refresh` share the
  unguarded shape (smaller slices, no observed staleness).
