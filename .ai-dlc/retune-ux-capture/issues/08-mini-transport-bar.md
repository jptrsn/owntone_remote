---
title: "Persistent bottom mini transport bar while a track is loaded"
labels: enhancement, area:ui, area:player
---

## Change
No screen except Now Playing can see or control playback: pushed screens
(Library/Queue/Outputs/Settings/Search) have **no player surface at all**
(`browse_screen_scaffold.dart` full read — no bar). ReTune pins a mini
player on every activity — verified in all three states on the Pixel 6
(`docs/retune-capture/23-playing-audit/notes.md`: playing → metadata +
transport; paused → same; stopped → transport only, metadata hidden).
User decision 2026-11-19: "the bottom bar when a track is playing"
(pairs with the drawer, #44).

## Expected
A pinned **bottom mini player** on every main screen except Now Playing:
- Two-line metadata (`title` / `artist - album`) + prev / play-pause / next.
- State source: `PlayerController.player` — icon mapping identical to
  `mirror_handler.controlsFor` (`lib/src/audio/mirror_handler.dart:58-60`).
- Presses route to `PlayerController` (`play`/`pause`/`next`/`previous`) —
  **never** `QueueController.playUris` (that call carries `clear=true` —
  see the issue-#21 lesson in `queue_controller.dart:172-174`).
- Tap on the metadata zone → `showNowPlaying` (`root_screen.dart:19-20`).
- **Visible iff a current item exists** (playing or paused); hidden when
  stopped/`nowPlaying == null` (ReTune keeps dead transport buttons when
  stopped — deliberate simplification, record in the PR).
- All three buttons carry tooltips + semantics labels (ReTune's are
  unlabeled ImageButtons — a11y gap not copied).
- Renders **above** list content as its own layer (not a list footer —
  must not scroll away, must not eat row taps); coexists with the
  offline ConnectionBanner (banner above the bar); offline → transport
  inert like every other control.
- Auto-hide semantics: none — the bar persists by design (contrast the
  transient volume toast, `22-volume-toaster`, which auto-hides ~2 s).

## Where
New `lib/src/ui/mini_player.dart`; host as `Scaffold.bottomNavigationBar`
(or a Stack layer) in `browse_screen_scaffold.dart` + outputs/settings
screens; reuse `ArtworkProbe`-gated thumbnail only if it costs no extra
fetch beyond the probe cache (unit 010) — otherwise icon-only v1.

## Requirements
R-22. Diff-list N-01.

## Repro / verification
Widget tests (fakes): bar present on Library/Queue/Outputs/Settings
routes while a fake current item is loaded; absent when
`nowPlaying == null`; play/pause button calls `PlayerController.pause`
(captured call), never `playUris`; tap on metadata zone pops to root;
list row taps still fire with the bar shown; offline → buttons disabled.
Supervised once on device (bar play/pause against the real server).
Gates green.
