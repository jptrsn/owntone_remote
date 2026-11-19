---
name: 002-screen-walk
status: done
intent: retune-ux-capture
supervised_steps: [1, 4]
---

# Unit 002 — the screen walk

## Goal

Capture every in-scope screen/state of ReTune (paused-state operation) per
`docs/retune-capture/CAPTURE-PROTOCOL.md` § "The walk": PNG + hierarchy +
notes per screen, plus the navigation graph.

## Preconditions

- Unit 001 done (paired, snapshot, paused verified).
- Server re-verified paused **before the walk starts and after any action
  that could change playback**.
- The walk itself is **supervised in practice**: a stray tap on ReTune's
  play control starts real audio. If the user is absent, do only
  read-only navigation (lists, details, back) and skip anything near
  transport controls; mark skipped items.

## Steps

1. `supervised: true` (or read-only subset if unattended) — walk the
   expected screen list (protocol doc): main/library root, artists,
   artists→albums, albums, album→songs, genres, composers (if present),
   playlists, playlist→songs, now playing (**paused state**),
   connecting/setup, settings/preferences, about/license/donate (shallow).
   iTunes-only surfaces: one line `out: itunes-only` each, then skip.
2. Per screen: `screen.png` + `hierarchy.xml` + `notes.md` (elements,
   actions, nav edges, JSON mapping guesses) into
   `docs/retune-capture/<NN>-<screen-slug>/`.
3. Long-press menus on list rows (safe while paused) — capture the sheet
   (screencap; uiautomator may be empty for overlays — known trap).
4. `supervised: true` — playing-only states (visualizer, peak meter):
   either a supervised window where the user explicitly approves one
   playback start (pause + verify immediately after), or mark
   `deferred: playing-state (supervised window required)`. **Never
   unattended.**
5. Empty states where cheaply reachable in the real library; error state
   optional (user-coordinated server stop) or noted as spec-from-failures.
6. Keep `docs/retune-capture/navigation.md` (mermaid) current as the walk
   progresses; capture back-button behaviour at each level.
7. Re-verify paused at the end; if any playback escaped, incident entry in
   SESSION-LOG.

## Completion criteria

1. Every in-scope screen captured (PNG + hierarchy + notes) or explicitly
   marked out (itunes-only / scope) in the coverage table.
2. Now playing captured in the **paused** state with all controls visible.
3. Navigation graph covers all in-scope screens + edges + back behaviour.
4. Coverage table written (screen → status: covered / out / missed).
5. Server verified paused at the end; incidents (if any) logged.

## Result — DONE 2026-11-19

**Walk on Pixel 6 (deviation per unit 001), paired, server pause-verified
throughout (curl before each drill-down).** 22 screen dirs in
`docs/retune-capture/` each with `screen.png` + `hierarchy.xml` (uiautomator —
works on the Pixel 6 foreground) + `notes.md` (+`activity.txt`):

01 library root (Playlists tab incl. smart playlists) · 02 nav drawer
(all Views incl. Songs; out one-liners: Radio, Audiobooks, Composers) ·
03 artists · 04 artist detail (SongsViewActivity, genre headers) ·
05 overflow (View as/Settings/Disconnect/Help) · 06 view-as dialog ·
07 artists grid (artwork + "N album, M songs") · 08 albums · 09 album
detail · 10 genres (section headers) · 11 genre→artists (ArtistsViewActivity) ·
12 **Songs (all-songs — gap candidate)** · 13+13b search (grouped
Albums→Artists→Songs, live-as-you-type, **no playlists**; DAAP = 3
parallel queries not /search) · 14 speakers (master + per-output slider
when selected — parity w/ R-09) · 15 now-playing paused (button-by-button
identification incl. shuffle/visualizer/genius(out)/repeat via logcat
DAAP + API restore) · 16 up-next (**post-current-only list**; drag-reorder
onboarding) · 16b **history (gap — no JSON endpoint)** · 17 settings
(all 11 prefs + values + option lists) · 18/18b playlist detail + overflow
(Play All/Shuffle/Play Next/Add to Up Next/Sort By) · 19 np **playing**
(supervised) · 20 queue current-row semantics · 21 notification
(FOREGROUND_SERVICE NO_CLEAR silent, custom layout) · 22 volume toaster
(DEFERRED visual; rocker step=5 datum).

Nav graph + back-behaviour + a11y-gap inventory: `navigation.md`. Key
behavioural data: long-press = tap (no row context menus); global drawer +
mini nano-player on all browse/search screens; last-viewed activity
restored on relaunch; live external-state sync (~2 s polling).

**Supervised windows used:** 2026-11-19 user-approved "proceed with both"
(cue-restore + play ~5 s) — actual audible ~18.5 s before an external
pause (concurrent session). **Incidents:** 2 (1 harness-caused prev-tap
~35 s; 1 external) — full entries in `docs/SESSION-LOG.md` 2026-11-19.
**Server end state:** `pause`, volume 31, shuffle on, repeat off (queue +
outputs belong to concurrent session; left as they set). Player
current-item byte-restore impossible (concurrent session replaced baseline
queue entry) — recorded.

**Deferred (visual-only, human review of PNGs):** np artwork tap,
rating-stars/ratings_dialog trigger, peak-meter/visualizer, volume toaster,
mini-bar icon identity. Error/connecting state not captured (needs
server-stop coordination) — spec from failure modes per protocol.
**Gate self-check:** every in-scope reachable screen captured or
explicitly deferred/out — coverage table lives in unit 004 output.
