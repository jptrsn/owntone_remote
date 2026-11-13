---
name: 011-queue-refresh-serialization
status: in_progress
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
