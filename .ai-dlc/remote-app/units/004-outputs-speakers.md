---
name: 004-outputs-speakers
status: pending
intent: remote-app
supervised_steps: [3]
---

# Unit 004 — outputs / speakers screen

R-IDs: R-09. Real server has 10 outputs (8× Chromecast, AirPlay, ALSA) —
this screen gets exercised for real.

## Goal

Outputs screen per SCREENS.md: list (name, type, selected, volume),
multi-select enable/disable via **one** `PUT /api/outputs/set` with the
full selected id list, per-output volume (`PUT /api/player/volume?
output_id=`), PIN dialog for `has_password`/`needs_auth_key` outputs.

## Steps / notes

- `OutputsController`: holds `List<Output>`; toggle = compute new set →
  single `/outputs/set` (optimistic UI, rollback on 5xx); refetch on WS
  `outputs`.
- Type rendering: display the string as-is (server sends `AirPlay 1`,
  `Chromecast`, `ALSA` — parse defensively, unknown = plain text, no
  icon).
- PIN: dialog before enabling a protected output → `PUT
  /api/outputs/{id}` with `selected: true, pin: …`; wrong PIN → server
  error surfaced, output stays disabled.
- Guardrail: changing outputs while **playing** redirects live audio to
  other rooms → `supervised`. While paused: safe.
- Tests: selection-set math (toggle on/off, multi-select, empty set
  behaviour — ask the server, record the answer in Result), PIN flow
  (fake 4xx), type-string rendering.

## Completion criteria

1. List matches `GET /api/outputs` exactly (all 10, fields correct) on
   the dev AVD.
2. Toggling one output sends exactly one `PUT /api/outputs/set` with the
   full id list (evidence: captured request or log) — not N toggles.
3. `supervised: true` — full audio verification: while playing (user-
   approved), move output A→B: audio follows; `selected` flags correct
   after; restore original output set afterwards (evidence: final
   `/api/outputs` matches the pre-test state).
4. Per-output volume slider verified via `GET /api/outputs` (paused —
   safe).
5. PIN dialog appears for protected outputs (none on this server —
   verify with a unit/widget test against a fake output with
   `has_password: true`; note the live gap).
6. Gates pass.

## Result

*(fill: pre/post output-set evidence, request captures, gate output,
incidents — this unit is the one most likely to play audio in the wrong
room: pause + verify after every supervised step, restore the original
set)*
