# 05 — Overflow menu (library context)

Opened from app-bar "More options" on any library tab.

| Item | Behaviour |
|---|---|
| **View as: List** | opens the View-as dialog (06); label reflects current mode |
| Settings | → RetunePreferencesActivity (17) |
| Disconnect From Library | unpair/disconnect — NOT exercised (read-only reference) |
| Help | opens help (browser/FAQ) — shallow, not captured |

## Diff-list note
OwnTone Remote has no per-view "View as" toggle on the library screen
(grid variants exist in ReTune: `*_with_grid_fragment`).
