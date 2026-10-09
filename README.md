# OwnTone Remote

A Flutter + Android remote control for a self-hosted
[OwnTone](https://owntone.github.io/owntone-server/) music server.

It is a clean-room re-implementation of the **UX** of [ReTune](https://github.com/izzysoft/retune)
(the legacy Android remote for iTunes, 2014 era) in modern **Material 3**, speaking
**exclusively** to OwnTone's JSON API and websocket notifications. No DACP/DAAP.
No reverse-engineering of ReTune's code. No ReTune assets. No iTunes-specific
features (radio, movies/TV, iTunes U, podcasts, audiobooks, Genius, etc.) — the
OwnTone feature set is the only relevant feature set.

**Status: planning complete (2026-10-08). Build not started.**

## For a new session — read in this order

1. [`AGENTS.md`](AGENTS.md) — hard rules: **audio safety** (no unattended playback),
   device isolation, ReTune read-only, quality gates. Read *all* of it.
2. [`docs/PLAN.md`](docs/PLAN.md) — the approved plan and every recorded decision.
3. [`docs/SESSION-LOG.md`](docs/SESSION-LOG.md) — last entry for current state.
4. The active intent: `.ai-dlc/<intent-slug>/intent.md` + its `units/`.

**Next action:** `.ai-dlc/audio-service-spike` (Phase 1 risk spike — the go/no-go
gate for the Flutter approach). `.ai-dlc/retune-ux-capture` unit 001 can start in
parallel but pauses for user pairing on the capture AVD.

## Repo map

| Path | What it is |
|---|---|
| `AGENTS.md` | Operating rules for AI sessions (router + hard rules) |
| `docs/PLAN.md` | Approved plan: decisions, scope, devices, phases, risks |
| `docs/REQUIREMENTS.md` | Feature requirements R-01… with acceptance criteria (v0.1 draft, finalized in `spec-authoring`) |
| `docs/ARCHITECTURE.md` | Layered design, `MusicProvider` abstraction, state flow (v0.1 draft) |
| `docs/API.md` | OwnTone JSON API reference for the endpoints this app uses + live-verified examples |
| `docs/SESSION-LOG.md` | Append-only handoff log (one entry per session) |
| `docs/retune-capture/CAPTURE-PROTOCOL.md` | How the Phase 2 UX capture is executed, incl. guardrails |
| `.ai-dlc/` | ai-dlc artifacts: intents, units with completion criteria + quality gates (see `.ai-dlc/README.md`) |
| `tools/retune/` | ReTune 3.5.23 APK — UX reference material only (proprietary; never shipped, never ported) |
| `lib/`, `android/`, `test/` | The app (created by `.ai-dlc/audio-service-spike` unit 001) |

## Protocol

JSON API at `http://<host>:3689` + websocket notifications (port from
`GET /api/config`; `3688` on the user's server). Websocket events are
**invalidation signals**: the app re-fetches on every event and on every
reconnect. See [`docs/API.md`](docs/API.md).

## Devices

| Role | Device | Notes |
|---|---|---|
| Capture | new AVD `Retune_API_33` (Android 13) | ReTune sideloaded, paired with the server by the user |
| Dev / test / QA | new AVD `RemoteDev_API_36` (Android 16) | all automated + supervised dev testing |
| Release candidate | Pixel 10 (GrapheneOS) | Phase 5 only; nothing installed until the build passes everything on the dev AVD |
| **Other session** | `emulator-5554` / `Pixel_9_Pro_API_36` | **hands off — never touch** |
