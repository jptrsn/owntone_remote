# 16 — Up Next (UpNextViewActivity)

Reached: drawer → Up Next. First-entry onboarding dialog captured at
capture time: **"Reorder Up Next Support — tap and hold to drag"** (OK).

## Elements
- App bar: title "Retune" + **Spinner [126,128][386,254]** = queue context
  switcher with options **Up Next | History** (see 16b).
- Section header: `Up Next from Music` (per-library queue group).
- Row: two lines (title, "artist - album") + right accessory (drag
  handle/menu, presumed) — **current item is NOT in the list** (list
  starts at the item after current — Apple-Remote semantics).
- Reorder = tap-and-hold drag (pref: Reorder Up Next with Artwork = OFF).

## Behavioural data
- ReTune restores the last-viewed activity on relaunch (came back here
  after HOME+relaunch), not the library.

## JSON mapping
- `GET /api/queue?start=N&end=M` (new app Queue tab R-11 shows whole queue
  incl. current — semantic difference worth a diff row); reorder =
  `PUT /api/queue/items/{id}/move`.
