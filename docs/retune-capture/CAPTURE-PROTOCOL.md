# ReTune UX Capture Protocol

**Intent:** `retune-ux-capture`. **Device:** `Retune_API_33` (Android 13
AVD, ReTune 3.5.23 sideloaded, **paired with 192.168.1.13 by the user**).
**Purpose:** produce the information-architecture + flow reference for
`SCREENS.md` and the pruned feature inventory for `REQUIREMENTS.md`.

## What this is NOT

- **Not a pixel spec.** The target UI is Material 3 (D6). Capture documents
  screens, elements, states and navigation edges — not colours, fonts or
  spacing. If you find yourself measuring px offsets, stop.
- **Not a protocol reverse-engineering effort.** ReTune speaks DAAP/DACP;
  this app speaks JSON (D1). DAAP paths surfaced by the static pass are used
  **only** to map "what ReTune does here" → "which JSON endpoint does the
  new app use". We never implement DAAP.
- **Not a code/asset source.** No ReTune strings, layouts, drawables or
  names may enter the app (N8). The inventory is behaviour, not code.
- **Not a documentation of iTunes-only surfaces.** Those get one line:
  `out: itunes-only (<feature>)`, then move on (PLAN §4, AGENTS.md §5):
  radio, movies/TV, iTunes U, podcasts, audiobooks, courses, classes,
  Genius, home sharing, Apple widgets.

## Hard guardrails (from AGENTS.md — restated because capture is where they bite)

1. **Audio safety (D16).** The capture runs against the **real** server with
   **real** speakers.
   - Before starting the walk: `curl -s -X PUT http://192.168.1.13:3689/api/player/pause`
     and verify `"state": "pause"`.
   - Operate ReTune **from the paused state**. The now-playing screen is
     fully capturable while paused.
   - **Never tap ReTune's play control** (screen, notification, lockscreen,
     widget) without the user present and confirming *that specific tap*.
     Screens that only exist while playing (e.g. animated visualizer) are
     captured in the paused state + noted, or deferred to a supervised
     window — never triggered unattended.
   - If playback starts accidentally (stray tap): **immediately**
     `curl -s -X PUT http://192.168.1.13:3689/api/player/pause`, verify
     `state == pause`, and record an incident in `docs/SESSION-LOG.md`
     (what played, for how long, how it was triggered).
   - Re-verify paused before each new screen and after any action that
     could change playback.
   - ReTune's own volume controls: changing server volume while paused is
     safe (no audio). Tapping play is not.
2. **ReTune is a read-only reference (D17).** No `pm clear`, no uninstall,
   no reinstall, no settings changes, no pairing changes — all without
   explicit user approval. `am force-stop com.squally.retune` (verify the
   real package name first via `pm list packages | grep -i retune`) is
   allowed. Losing the pairing costs the reference.
3. **Server data is real and curated (AGENTS.md §4).** The walk is
   read-only against the library. No creating/deleting playlists in ReTune,
   no rescan.
4. **Device isolation.** `adb -s <capture-serial>` on every command. The
   other session's `emulator-5554` is never touched.

## Preconditions (unit 001 establishes)

- `Retune_API_33` AVD created, booted, serial recorded in AGENTS.md.
- ReTune installed; package name recorded.
- **User has configured ReTune and completed pairing with 192.168.1.13**
  (ReTune's own add-server/pairing flow; the agent may guide, the user
  completes the PIN exchange).
- Library screens show real data (pairing verified).
- Server verified paused.
- AVD snapshot saved after pairing (`adb -s <s> emu snapshot_save paired`)
  so the paired state survives reboots.

## The walk (unit 002)

For **each screen/state**, in `docs/retune-capture/<NN>-<screen-slug>/`:

| File | How |
|---|---|
| `screen.png` | `adb -s <s> exec-out screencap -p > screen.png` |
| `hierarchy.xml` | `adb -s <s> shell uiautomator dump /sdcard/walk.xml && adb -s <s> pull /sdcard/walk.xml hierarchy.xml` (empty result while an overlay/sheet is open — AGENTS.md trap; re-dump after closing it) |
| `notes.md` | elements (what they are, what they do), navigation edges (tap X → screen Y), actions and their visible effects, states observed (empty/error/paused), one line per element's presumed JSON mapping |

Naming: `01-main`, `02-artists`, `03-albums`, `04-artist-detail`,
`05-album-detail`, `06-playlists`, `07-playlist-detail`, `08-now-playing`,
`09-connecting`, `10-settings`, … (numbers = walk order).

### Expected screen list (from the APK's layout inventory — verify, don't assume)

- main / library root (tabs: artists, albums, …)
- artists list; artist → albums; albums list; album → songs
- artists-with-grid / albums-with-grid variants (display mode toggle?)
- genres; composers (if present — note it; JSON has no composer browse)
- playlists; playlist → songs; playlist folder handling
- now playing (paused state; controls, rating star, volume)
- connecting / setup / pairing screens
- settings / preferences (every preference key visible — they define the
  expected settings surface)
- about / license / donate (shallow: existence + one screenshot)
- **one line each, then skip** (out, itunes-only): radio, movies/TV,
  iTunes U, podcasts, audiobooks, courses, classes, Genius
- home-screen/lockscreen widgets: **out of scope** (PLAN §4) — note
  existence only (they appear in `res/layout/*widget*`)

### States to capture

- Normal (data populated) — the main walk.
- Paused now playing — mandatory (it's the only capture-safe now playing).
- Empty states — where cheaply reachable (e.g. a playlist folder with no
  contents in *the real library*; do not fabricate empties by deleting data).
- Error/offline — **optional, needs user coordination** (stopping the server
  is a server-side action the user performs on request). If not done, mark
  the error state in the inventory as "spec from API failure modes".
- Playing-only states (visualizer animation, peak meter): note as
  `deferred: playing-state (supervised window required)`; do not trigger.

### Navigation rules

- Navigate by `input tap x y` / `input swipe` using coordinates from
  `hierarchy.xml` bounds (center of the element).
- After each navigation: wait for settle (1–2 s), verify the new screen
  (screencap + a hierarchy sanity check that it's not the same screen).
- Keep a running nav graph: `docs/retune-capture/navigation.md`
  (mermaid `flowchart` of screens + edges + trigger).
- Back button behaviour is part of the spec: capture what back does at each
  level (pop vs close vs main).
- Long-press menus: trigger on list rows (play/add/rate?) — safe while
  paused; capture the menu sheet (screencap; uiautomator may be empty for
  the sheet — screencap + a second dump attempt is enough).

## Static pass (unit 003)

```sh
apktool d tools/retune/Retune_3.5.23_APKPure.apk -o tools/retune/decoded
```
(`decoded/` is gitignored — regenerable.)

Extract into `docs/retune-capture/static-notes.md`:
- `res/values/strings.xml` — feature names, preference labels, action
  labels (these name the UX surface better than any screen).
- `res/xml/preferences.xml` — the full settings surface (keys + defaults).
- Layout inventory vs walk coverage — **which layouts did the walk never
  reach** (missed screens/states; re-walk if cheap, else note).
- DAAP/DACP constants in smali (URL paths, DMAP tags) — **mapping table
  only**: "ReTune action X (DAAP path P) → JSON endpoint E (or none → drop
  / simpler JSON way)".
- `AndroidManifest.xml` — permissions + activities (confirms surface;
  e.g. media button receiver, widget providers — out of scope, noted).
- `jadx` (if available) is optional; apktool smali strings are usually
  enough. Do not spend time de-obfuscating logic — we're not porting it.

## Inventory (unit 004)

`docs/retune-capture/feature-inventory.md` — one row per feature/screen:

| # | Feature / screen | Screens (refs) | Elements | Actions (user → effect) | ReTune behaviour notes | JSON API mapping (endpoint) | Status |
|---|---|---|---|---|---|---|---|
| F-01 | Browse artists | 02,04 | artist row (name, album/track counts) | tap → artist detail | … | `GET /api/library/artists` … | in-v1 / out / gap |

Status values:
- `in-v1` — maps cleanly to the JSON surface, keep.
- `out: itunes-only` — radio/movies/podcasts/etc. One line, no further
  documentation (AGENTS.md §5).
- `out: scope` — in-scope protocol-wise but cut for v1 (e.g. queue
  reordering) with a one-line rationale.
- `gap` — ReTune does it, JSON API doesn't obviously support it →
  recommend either the simpler JSON equivalent or drop. **Never**
  "reverse-engineer the DAAP call".

**Coverage table** (same file): every walked screen + every layout from the
static pass, marked covered / out / missed.

**Gate:** the user prunes/approves the inventory (status column) before
`spec-authoring` starts. The agent recommends; the user decides.

## Definition of done (intent)

- [ ] Every reachable screen captured (PNG + hierarchy + notes) or marked out
- [ ] Nav graph complete for in-scope screens
- [ ] Static pass complete; missed screens reconciled
- [ ] `feature-inventory.md` complete: every action mapped to JSON or
      explicitly out/gap; zero iTunes-only features documented in depth
- [ ] Coverage table honest (misses listed, not hidden)
- [ ] Server verified paused at the end; no incidents, or incidents logged
- [ ] User pruned + approved the inventory
