# PLAN — OwnTone Remote

**Status:** approved 2026-10-08 (user). Planning session recorded in
`docs/SESSION-LOG.md`. This document is the source of truth for *what* we are
building and *why*; per-unit *how* lives in the `.ai-dlc/` intent files.

---

## 1. Background

ReTune (APK in `tools/retune/`) is the UX reference: a 2014-era Android remote
for iTunes that controlled forked-daapd/OwnTone servers over DACP/DAAP. It is
proprietary, obfuscated, and iTunes-shaped. We are **not** cloning it:

- Protocol: OwnTone JSON API + websocket (ReTune's DACP is irrelevant).
- Code: clean-room. No decompiled ReTune code, no ReTune assets, no ReTune
  branding (the app is planned as open source).
- Feature set: **OwnTone's feature set is the only relevant feature set.**
  Every iTunes-specific ReTune feature is dropped (radio, movies/TV,
  iTunes U, podcasts, audiobooks, courses/classes, Genius, home sharing,
  Apple widgets).
- What we take from ReTune: the *shape* of the UX — the screen inventory,
  navigation flows, and interaction patterns of a music-remote (library
  browsing, now playing, queue, speakers, pairing/connection, settings) —
  re-expressed in modern Material 3.

The same host runs a prior Flutter app, `~/Documents/owntone_sync` (offline
sync of an OwnTone library, `just_audio` + `audio_service`, clean
`data/domain/presentation` architecture, dio, provider). It is a convention
reference and the origin of the dependency choices — not a code dependency.

## 2. Recorded decisions (do not relitigate)

| # | Decision | Value |
|---|---|---|
| D1 | Protocol | OwnTone JSON API at `http://192.168.1.13:3689` + websocket notifications at `:3688` (port read from `/api/config`). **No DACP/DAAP.** |
| D2 | Websocket semantics | Events are **invalidation signals**. Re-fetch on every relevant event and on every reconnect. |
| D3 | Stack | Flutter/Dart. `audio_service` for the media session, persistent notification, lock-screen controls and hardware volume rocker. Small Kotlin platform channel for call-state detection (~30 lines, TelephonyCallback). |
| D4 | Scope (v1) | See §3. |
| D5 | Out of scope | See §4. |
| D6 | Visual fidelity | **Same UX, modern Material 3.** Capture documents information architecture + flows, not pixels. |
| D7 | Servers | Single server (one configured host:port). Multi-server is a later extension behind the same `MusicProvider` interface. |
| D8 | Discovery | **Manual host:port entry only.** No mDNS in v1 (emulator can't test it anyway; discovery is a later unit). |
| D9 | Call behaviour | Incoming call **pauses** server playback; on call end, **auto-resume**. |
| D10 | Modularity | The OwnTone API is fully abstracted behind a domain `MusicProvider` interface + `ProviderCapabilities`. A second backend (MPD, LMS, …) = a new `data/providers/<x>/` implementation, zero UI changes. |
| D11 | SDK | targetSdk 36, minSdk 26. No Google Play Services. Cleartext HTTP allowed (LAN). |
| D12 | Distribution | Open source planned → spec is behaviour-based; no decompiled code/assets; app name/package must not imply official OwnTone affiliation. Defaults: package `dev.educoder.owntone_remote`, display name "OwnTone Remote", license **MIT** (finalize in `spec-authoring`). |
| D13 | Capture device | **Older** AVD `Retune_API_33` (Android 13, `google_apis`) with ReTune sideloaded; user configures + pairs it with the server. Chosen by user 2026-10-08. (The APK is pure Java — no native libs — so it would probably run on API 36 too, but the user chose an older image to be safe.) |
| D14 | Dev / test / QA device | **Modern** AVD `RemoteDev_API_36` (Android 16, `google_apis` — image already installed). All dev, test and QA work happens here. |
| D15 | Release candidate | Pixel 10 (GrapheneOS) — **only** in the final verification phase; nothing is installed there until the build passes everything on the dev AVD. Real incoming-call test happens here (no SIM on the emulators). |
| D16 | Audio safety | **No unattended, unconfirmed audible playback on the real server.** Full rule in `AGENTS.md` §1. This project may run overnight; music must never start playing unexpectedly. |
| D17 | ReTune install | Read-only reference (paired instance). No `pm clear`/uninstall/reinstall/settings changes. `am force-stop` allowed. |
| D18 | ai-dlc | Work is organized as ai-dlc intents + units with explicit completion criteria and quality gates (backpressure). Artifacts committed per completed unit — that is the handoff mechanism. |
| D19 | Other session's emulator | `Pixel_9_Pro_API_36` is owned by a separate session on this host. Never touched by this project. (Serial at last check: `emulator-5556` — serials shift, always re-verify; this project's dev AVD `RemoteDev_API_36` currently occupies `emulator-5554`.) |
| D20 | Volume-rocker scope (2026-10-22, user) | The rocker maps to the server's master volume **only while the app is in the foreground**. Backgrounded (any screen state, any server state — including server `play`): the phone's volume keys perform their normal function; the app must never control volume in the background. Replaces S4's original "screen off + backgrounded" form. |

## 3. Scope — v1 (in)

| ID | Feature | Notes |
|---|---|---|
| S1 | Connection | Manual host + port entry, persisted; connection status surface; websocket lifecycle with reconnect + full refetch |
| S2 | Now playing | Artwork, title/artist/album, progress + seek, elapsed/total, play/pause, prev/next, shuffle, repeat (off/all/single), consume, master volume slider |
| S3 | Persistent notification | Media notification: artwork, metadata, transport controls; stays in sync with the server (WS-driven) |
| S4 | Hardware volume rocker | → master volume (step), **only while the app is foregrounded** (D20); backgrounded = normal phone volume, no server control |
| S5 | Call handling | Pause on incoming call; auto-resume on call end (D9) |
| S6 | Speakers / outputs | List, enable/disable (multi-select), per-output volume, PIN prompt for password-protected outputs |
| S7 | Browse | Library browsing + playlists + play from lists. Exact depth (genres, composers, playlist folders, grid views) decided from the pruned capture inventory in `spec-authoring` |
| S8 | Queue | View current queue, play/clear (no reordering in v1 unless capture shows a need) |
| S9 | Rating | Display + edit (0–100 → 5 stars), WS `database` event refresh |
| S10 | Search | Full-text search (tracks/artists/albums/playlists) — P1; confirm against inventory |

Detailed requirements with acceptance criteria: `docs/REQUIREMENTS.md`.

## 4. Scope — out

- **All iTunes-specific ReTune features:** radio, movies/TV, iTunes U,
  podcasts, audiobooks, courses, classes, Genius, home sharing, Apple
  widgets/complications.
- Home-screen & lock-screen **widgets** (the persistent notification +
  MediaSession cover the use case; widgets are a later intent at most).
- mDNS / `_daap._tcp` discovery (D8).
- Multiple concurrent servers (D7).
- Playlist create/edit/delete (server has `allow_modifying_stored_playlists:
  false` anyway; the JSON API does not expose playlist writes).
- Offline playback, downloads, file sync (that is `owntone_sync`'s job).
- DAAP/DACP in any form; reverse-engineering ReTune's protocol traffic.
- Library rescan triggers, library file management.

## 5. Devices

| Role | Device | Serial | State (2026-10-08) |
|---|---|---|---|
| Other session — **HANDS OFF** | `Pixel_9_Pro_API_36` (Android 16) | `emulator-5556` (2026-10-09; was `-5554` — serials shift) | running headless |
| Capture | `Retune_API_33` (Android 13, `google_apis`, arm64) | _record on creation_ | not created; needs `sdkmanager "system-images;android-33;google_apis;arm64-v8a"` |
| Dev / test / QA | `RemoteDev_API_36` (Android 16, `google_apis`, arm64) | `emulator-5554` (2026-10-09) | created + running |
| Release candidate | Pixel 10 (GrapheneOS) | _record when connected_ | user's daily driver; Phase 5 only |

Rules: `adb -s <serial>` always; re-verify `adb devices -l` before any adb
work; run the capture AVD only during the capture phase (three emulators at
once on this Mac is heavy); `am force-stop` ReTune before any dev testing on
the capture AVD (it will not be used for dev, but the rule costs nothing).

## 6. Server

`192.168.1.13`, OwnTone **29.3** (verified live 2026-10-08):

- JSON API: `:3689` — no HTTP auth configured on this server (if auth is
  later enabled, handle 401 in `remote-app` unit 001).
- Websocket: `:3688` (`websocket_port` from `/api/config`).
- Build options: ffmpeg, Spotify, librespot-c, LastFM, Chromecast, MPD,
  Websockets, ALSA, Webinterface, Regex.
- Library root: `/srv/media`. `allow_modifying_stored_playlists: false`.
- Outputs at verification time (10): 8× Chromecast, 1× AirPlay 1
  ("Office-Airsync", **selected**), 1× ALSA ("Server", **selected**).
- Player at verification time: `state: pause`, volume 75, item 196000.

Full endpoint reference + live-verified examples: `docs/API.md`.

## 7. Repository structure

```
owntone_remote/
├── AGENTS.md                  # operating rules (read first, every session)
├── CLAUDE.md                  # pointer → AGENTS.md
├── README.md
├── .ai-dlc/
│   ├── README.md              # how the manual ai-dlc mode works here
│   ├── settings.yml
│   └── <intent-slug>/
│       ├── intent.md          # frontmatter: quality_gates; Problem/Solution/Domain Model/Success Criteria
│       ├── discovery.md       # (spike) environment findings
│       └── units/NNN-<slug>.md  # completion criteria, procedure, ## Result
├── docs/
│   ├── PLAN.md                # this file
│   ├── REQUIREMENTS.md        # R-IDs + acceptance criteria (draft → finalized in spec-authoring)
│   ├── ARCHITECTURE.md        # layers, MusicProvider contract, state flow (draft → finalized)
│   ├── API.md                 # JSON API subset + WS protocol + live examples
│   ├── SCREENS.md             # created in spec-authoring
│   ├── SESSION-LOG.md         # append-only handoff log
│   └── retune-capture/
│       ├── CAPTURE-PROTOCOL.md
│       └── <NN>-<screen>/     # capture output (unit 002)
├── tools/retune/              # ReTune APK + README (reference only)
├── lib/  android/  test/      # the app — created by audio-service-spike unit 001
```

## 8. ai-dlc structure (manual mode)

The full ai-dlc plugin is not installed; we apply its methodology as repo
artifacts + discipline (see `.ai-dlc/README.md` for the mechanics).

**Quality gates** (enforced before any unit is marked done; commands run by
the session, output pasted into the unit's `## Result`):

```sh
flutter analyze                                    # 0 issues
dart format --output=none --set-exit-if-changed .  # no diffs
flutter test --exclude-tags live                   # unit + widget tests, no network
flutter build apk --debug                          # from remote-app intent onward
```

**Intents (in order):**

| # | Intent | Mode | Gate |
|---|---|---|---|
| 1 | `audio-service-spike` | OHOTL | Exit criteria in unit 001 → **GO** (Flutter) / **NO-GO** (Kotlin+Media3 fallback before any further build work) |
| 2 | `retune-ux-capture` | HITL | Screen walk + apktool static pass + feature inventory; **user prunes the inventory** |
| 3 | `spec-authoring` | HITL | Finalized REQUIREMENTS/SCREENS/ARCHITECTURE/API docs; **user reviews** |
| 4 | `remote-app` | AHOTL | Units 001–006, each ≤10 completion criteria, gates must pass, supervised steps need the user |
| 5 | `device-verification` | HITL | Dev-AVD full pass, reconnect robustness, Pixel 10 GrapheneOS checklist |

Intents 1 and 2 are independent and may run in parallel once the capture
AVD is paired (unit 2.1 has a user pause point).

## 9. Phases

### Phase 1 — Risk spike (`audio-service-spike`)
Minimal Flutter app: hardcoded `192.168.1.13:3689`, one now-playing screen,
`audio_service` handler that **mirrors server state without playing locally**,
websocket subscription. Exit criteria (unit 001): volume rocker → master
volume (screen off, backgrounded); notification reflects server-side changes;
simulated call pauses + auto-resumes (supervised); **documented report on
paused-state foreground-service survival** (the key unknown: does Android 16
keep a `mediaPlayback` FGS alive when nothing plays locally?).
**NO-GO fallback:** Kotlin + Media3 before any further work.

### Phase 2 — UX capture (`retune-ux-capture`)
On the paired `Retune_API_33` AVD: systematic screen walk
(screencap + `uiautomator dump` + notes per screen), static apktool pass
(strings, layouts, `preferences.xml`, URL/DAAP path constants from smali —
for *mapping* only), then a feature inventory mapping every ReTune action to
the JSON API equivalent (or marking it out).
**Explicit capture instruction:** document information architecture, elements
and flows — *not* pixel styling (D6). iTunes-only surfaces get a one-line
`out: itunes-only` entry and nothing more (D: OwnTone-only feature set).
No traffic capture: the protocol is settled (D1); ReTune's DAAP traffic would
only re-confirm the action mapping the inventory already produces.

### Phase 3 — Spec authoring (`spec-authoring`)
Finalize `REQUIREMENTS.md` (every v1 feature, verifiable acceptance
criteria), `SCREENS.md` (each screen: Material 3 equivalent, elements,
actions → endpoints, loading/empty/error/offline states),
`ARCHITECTURE.md` (spike-validated structure, `MusicProvider` contract,
state flow, error/reconnect policy), `API.md` (verified subset).
Gate: user review.

### Phase 4 — Build (`remote-app`, units 001→006)
001 connection-settings → 002 now-playing (incl. notification hardening) →
003 volume-rocker + call-handling → 004 outputs/speakers →
005 browse + queue + play → 006 rating. Each unit: TDD where sensible
(API client units), fakes for unit/widget tests, `live`-tagged tests for
server behaviour, supervised steps marked and skipped when unattended.
UI work uses the `flutter_agent_lens` loop (AGENTS.md § "UI debug loop").

### Phase 5 — Verification (`device-verification`)
Full requirements pass on `RemoteDev_API_36`; reconnect robustness (Wi-Fi
drop, server restart — coordinated with user); release APK on Pixel 10
GrapheneOS: per-app Network permission, FGS/notification survival, volume
rocker, **real** incoming call + auto-resume.

## 10. Execution order (for the next session)

1. Read `AGENTS.md` → this file → `docs/SESSION-LOG.md` (last entry).
2. `audio-service-spike` unit 001 (creates `RemoteDev_API_36`, `flutter
   create`, spike app). User present for the `supervised: true` criteria.
3. In parallel: `retune-ux-capture` unit 001 (creates `Retune_API_33`,
   sideloads ReTune) → **user pairs ReTune with 192.168.1.13** → units
   002–004 (walk, static, inventory) → **user prunes inventory**.
4. `spec-authoring` → user review.
5. `remote-app` units 001–006 (one unit per session-commit).
6. `device-verification` → Pixel 10 with the user.

## 11. Risks

| Risk | Mitigation |
|---|---|
| `audio_service` FGS killed in paused state on Android 16 (no local audio to justify `mediaPlayback`) | That is exactly spike criterion 7; alternatives: keep the media session active with a remote "playing" flag, or fall back to Kotlin+Media3 (D: NO-GO path) |
| ReTune misbehaves on Android 13 | Unlikely (pure Java, no 32-bit libs); fallback: try API 34/35/36 images on the capture AVD |
| Overnight automation plays music | Hard rule D16 + `supervised: true` step marking + pause-before-work verification (AGENTS.md §1) |
| Three emulators at once (incl. other session's) | Run capture AVD only during Phase 2; dev AVD only during Phase 1/4/5 |
| Screenshot baseline flakes (status-bar clock) | Compare with system UI hidden or accept small diffs (known `flutter_agent_lens` caveat) |
| GrapheneOS grants no implicit Network permission | Explicit Phase 5 checklist item |
| Stale docs/instructions | "Verify claims against the code and the live server" (AGENTS.md traps) |

## 12. Open items (decide in the phase that needs them)

- Display name / package / license (defaults in D12) — `spec-authoring`.
- Browse depth: genres? composers? (JSON API has no `/api/library/composers`
  browse endpoint — search-type only), playlist folders, grid views —
  from pruned inventory.
- Queue reordering in v1? (JSON API supports `new_position`.)
- Volume-rocker step size (default −5/+5 assumed).
- Offline behaviour beyond "status banner + stale data" (D: no offline queue
  in v1).
- Whether `RemoteDev_API_36` should carry a snapshot for fast reboots
  (capture AVD should — ReTune pairing state lives in the AVD image).

## 13. Handoff protocol

Every session, at the end of work:

1. Fill the `## Result` section of every unit touched (evidence or BLOCKED
   reason).
2. Update unit frontmatter `status`.
3. Append one entry to `docs/SESSION-LOG.md`: date, what was done, evidence
   pointers, current state, **next action for the next session**.
4. Commit per the unit-commit rule (AGENTS.md § ai-dlc discipline).
5. If a decision was made that isn't in this file, add it to §2 with a new
   D-number and note it in the session log.
