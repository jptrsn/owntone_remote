# 15 — Now playing, paused (NowPlayingViewActivity)

Reached: drawer → Now Playing; or mini-bar tap (from library views).

## Layout (hierarchy, top→bottom)
1. App bar: "Retune" (drawer) · Search · Speakers · More.
2. Track title (large), "artist - album" (small) — centered.
3. Progress row: **elapsed `2:25` left, negative remaining `-1:34` right**
   (ReTune shows −remaining, not total) — NO seek slider on this screen.
4. Large artwork (clickable ImageView [212,506][868,1807] — tap behaviour
   not exercised; no content-desc).
5. **Small 4-button row** (all ImageButton, NO content-desc — a11y gap):
   - [222,1846][306,1930] = **shuffle** (verified: `setproperty?dacp.shufflestate=0`,
     server `shuffle` flipped; restored via `PUT /api/player/shuffle?state=true`)
   - [406,1846][490,1930] = **visualizer** toggle (`setproperty?dacp.visualizer=1`;
     reset to 0 after)
   - [590,1846][674,1930] = **Genius shuffle** (out: itunes-only — opens
     "Communication Error / Unable to cue genius shuffle. Error code: 500"
     dialog; dropped per user 2026-11-19)
   - [774,1846][858,1930] = **repeat** (`setproperty?dacp.repeatstate=2` →
     server `repeat: all`; cycled; restored to off)
   - On/off state is icon-only (no `selected` attribute) — visual.
6. **Large 3-button row** (transport): prev [222,1969][390,2137] ·
   play/pause [456,1969][624,2137] · next [690,1969][858,2137].

## Overflow (np context)
Go to Artist · Go to Album · Settings · Disconnect From Library · Help.
**Go to Artist/Album** = navigate to that browse context from now playing.

## Rating
"No rating stars rendered in paused now-playing hierarchy" — pref *Show
Rating on Now Playing* = ON yet no star nodes appeared; likely
ImageView-only (visual) — **human check of screen.png requested**.
`ratings_dialog` trigger point not identified during walk.

## Notable absences vs new-app now-playing
- No seek bar on the big now-playing screen (progress text only; seek =
  ReTune has `master_volume_toaster`-style? not observed here).
- No explicit volume slider on np (volume = hardware keys + toaster — see 19).
- No consume/stop controls; modes = shuffle/repeat(+visualizer/genius).

## DAAP→JSON
- getproperty dmcp.volume; playstatusupdate (polling); playpause;
  setproperty dacp.shufflestate/repeatstate.
- New app equivalents already exist (R-03/R-04/R-05).
