# 21 — Persistent notification (Run in Background = ON)

Shade screenshot captured; ReTune notification verified via
`dumpsys notification --noredact`:
- `pkg=com.squallydoc.retune id=1 flags=NO_CLEAR|FOREGROUND_SERVICE`,
  custom `contentView` (0x7f030022 = `custom_notification` layout; big
  variant `custom_big_notification`), importance=2 (silent) → collapses
  into the "silent" group.
- Lockscreen controls pref ON (Use Lockscreen Controls).

Control buttons live in RemoteViews — not exposed in a11y dump; PNG for
human review. Layout inventory (static pass) + R-07 in the new app cover
equivalence (title/artist/album + play/pause/next/prev).

## DAAP model note
ReTune keeps a FOREGROUND SERVICE alive while paired (even paused) —
the new app's mediaPlayback FGS + silent channel already matches (unit 002).
