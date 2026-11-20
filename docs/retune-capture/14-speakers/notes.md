# 14 — Speakers (SpeakersViewActivity)

Opened from the app-bar **Speakers** action (available on every screen —
one-tap output access from anywhere, incl. now-playing/search).

## Structure (hierarchy-verified)
- "Master Volume" label + master SeekBar [89,332][1064,416].
- One row per server output: CheckBox [16,·][100,·] + name.
- **Selected outputs render a per-output SeekBar below the row** (checked
  rows grow +110 px); unselected rows are compact.
- Checked state matched server: ESP-68F8, ESP-CAAC64, Volumio Kitchen
  (= `/api/outputs` selected).
- No confirm dialogs observed on this screen (toggling not exercised —
  server mutation; behavior assumed immediate from DAAP model).

## Diff-list notes
- New app: outputs reachable from now-playing line/app-bar? R-09 screen
  exists; ReTune exposes it as a persistent app-bar action — candidate.
- Per-output sliders shown only when selected = same pattern the new app
  adopted (CLK OFF sliders when unselected, unit 012/#19) — parity ✓.

## JSON mapping
- `GET /api/outputs`; toggles `PUT /api/outputs/{id}`; master `PUT /api/player/volume?volume=N`.
