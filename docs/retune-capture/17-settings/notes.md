# 17 — Settings (RetunePreferencesActivity)

Single scrollable list; drawer available everywhere (app-bar title toggles
it). Current values captured from CheckBox states + dialog CHECKED marks.

## BACKGROUND OPTIONS
| Pref | Current | Summary/semantics |
|---|---|---|
| Run in Background | **ON** | persistent notification (FGS) |
| Screen off disconnection | **Immediately** | list: Immediately / 2 / 5 / 10 / 15 / 30 min / Never |
| Use Lockscreen Controls | **ON** | lockscreen controls (perm note) |
| Pause on Incoming Calls | **OFF** | pause on call, resume after (READ_PHONE_STATE) |

## VIEW OPTIONS
| Pref | Current |
|---|---|
| Use Volume Buttons | **ON** (hardware keys → server volume — R-14 parity) |
| Reorder Up Next with Artwork | **OFF** |
| Default View | **Library View** (options: Library View / Now Playing / Up Next) |
| Default Library View | **Playlists** (options incl. ALL Views: Artists, Albums, Songs, Genres, Composers, Genius Mixes, Radio, iTunes Radio, Movies, Rentals, TV Shows, Podcasts — iTunes-only ones out) |
| Select Theme | **Light** (Light/Dark) |
| Show Rating on Now Playing | **ON** |
| Half Star Ratings | **OFF** (iTunes half-star hack) |
| Screen Lock | **OFF** (keep screen on when plugged in) |

## OTHER
Donate (dialog: Via PayPal / Via Bitcoins / Cancel), Licenses (dialog —
captured screen3), Special Thanks (row), Version (row).

## Diff-list relevance
- Rocker step (R-14 new-app setting) has NO ReTune equivalent — ReTune
  step = fixed 5 (verified: 2 presses = 31→41) — new app already exceeds.
- Screen-off disconnection, Pause on Incoming Calls, Default view prefs,
  Theme = candidates (server-parity/UX).
