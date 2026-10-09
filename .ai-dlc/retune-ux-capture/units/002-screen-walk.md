---
name: 002-screen-walk
status: pending
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

## Result

*(fill: screens captured, nav graph reference, coverage table, supervised
windows used, incidents, gate checklist output)*
