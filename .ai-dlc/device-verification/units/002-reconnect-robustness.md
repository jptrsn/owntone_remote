---
name: 002-reconnect-robustness
status: pending
intent: device-verification
supervised_steps: [2]
---

# Unit 002 — reconnect robustness

R-IDs: R-01, R-02. The app must survive the real world: Wi-Fi drops,
server restarts, long disconnects.

## Scenarios (each: before → disturb → observe → recover → assert)

1. **Wi-Fi off/on on the AVD** (unattended-safe, server stays paused):
   `adb -s <s> shell svc wifi disable` → app shows offline within ~15 s;
   `svc wifi enable` → auto-reconnect, player/outputs/queue correct, no
   crash, no duplicate notification.
2. `supervised: true` — **server restart** (user restarts OwnTone while
   the app is running, paused state): same assertions as 1 + after
   reconnect the app shows the server's fresh state (volume/state
   unchanged from before).
3. **Long disconnect** (≥10 min, unattended-safe): AVD wifi off 10 min,
   on → backoff sequence in logs (1→2→4→…→30 s cap), state converges,
   memory sane (no unbounded retry queue growth — check log volume).
4. **Rapid flapping** (unattended-safe): 5× quick wifi disable/enable in
   a row → no crash, no duplicate notifications, state consistent.

## Assertions after every scenario

- `GET /api/player` state == app-displayed state
- outputs set matches
- notification shows the current track, single instance
- `flutter` console: no unhandled exceptions (read the `flutter run`
  console — agent-lens `console_logs` misses framework errors, AGENTS.md
  UI loop §5)

## Completion criteria

1. All four scenarios pass with the assertion block green (evidence per
   scenario in `## Result`).
2. Backoff sequence visible in logs for scenarios 3.
3. No crash logs in any scenario.
4. Server left paused (evidence).

## Result

*(fill: per-scenario evidence, assertion outputs, log excerpts, incidents)*
