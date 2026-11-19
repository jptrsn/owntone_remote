# 19 — Now playing, playing (supervised 2026-11-19)

Captured during the user-confirmed supervised window (server `play` on
item 210493 "Cheap Thrills"). ~18 s of audio (paused server-side by the
concurrent session after ~18.5 s — see SESSION-LOG incident notes).

## Playing-only facts (hierarchy)
- Progress ticker runs: elapsed/−remaining update live (`0:18 / -3:26` at
  dump time; DAAP `playstatusupdate` polling loop visible in logcat).
- Play/pause button toggles icon only (no state attrs) — visual (PNG for
  human review).
- Peak meter / visualizer: layouts `peak_meter_1/2.xml`, visualizer via
  `dacp.visualizer` — rendering is pure visual, not in a11y tree →
  `deferred: playing-state (visual)`; PNG retained for human check.

## Behaviour datum
ReTune **live-synced an external cue** (API `play?item_id` from agent)
within ~2 s without interaction — DAAP `playstatusupdate` revision polling.
