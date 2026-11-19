# 01 — Library root (Playlists tab, LibraryViewActivity)

State captured: Playlists view selected, drawer closed. (First screencap
caught the Recent/tab-strip variant before a tap moved it; hierarchy below
is the authoritative Playlists state.)

## Elements
| Element | Type | Bounds | Behaviour |
|---|---|---|---|
| Tab title "Playlists" (clickable) | action bar | [0,128][321,254] | opens navigation drawer (see 02) |
| Search | Button | [638,128][785,254] | → search screen (see 11) |
| Speakers | Button | [785,128][932,254] | → output/speaker selection (see 12) |
| More options | overflow | [932,128][1080,254] | context menu (see 03) |
| Smart-playlist rows: All Music, Brass, Five Stars, Holiday Music, Master, One Star, Recently Added, Recently Played, Recently Skipped, Rediscover, Smart Shuffle, Soul, Unrated | clickable rows | ~133 px pitch | tap → playlist songs (server smart playlists, from DAAP `/containers`) |
| Mini now-playing bar: track title + "artist - album" + 3 ImageButtons | persistent, bottom | [0,2006][1080,2137] | tap bar → now playing; buttons = transport (unlabeled — no content-desc; accessibility gap) |

## Notes
- Mini bar present on library screens: title + subtitle (artist - album) +
  prev/play/next buttons, no artwork/progress (nano variant).
- Smart playlists come from the server (OwnTone smart playlists render as
  normal playlists in ReTune).
- Rows are `android.widget.LinearLayout` clickables with a secondary
  clickable box at row right ([909,·][1014,·]) — the disclosure/accessory
  (same tap target as row? to verify in a re-walk pass if cheap).
- No tab strip in this state — navigation is entirely via the drawer
  (earlier state showed a strip below the app bar; see 02).

## JSON mapping (new app)
- Smart playlists → `GET /api/library/playlists` (OwnTone exposes smart
  playlists as regular playlist entries with smart flags).
- Mini bar transport → `PUT /api/player/{play,pause,previous,next}`.
- Mini bar tap → now-playing screen (`GET /api/queue?id=now_playing`).
