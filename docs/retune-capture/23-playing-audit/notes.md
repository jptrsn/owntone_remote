# 23 — Playing-state + navigation audit (supervised, 2026-11-19, user-approved)

Window: `play?item_id=211617` (~13 s audible, incl. audit taps) → `pause` +
`seek 199028`; player restored (`pause`, item 211617 @199001, volume 100 —
volume had been set to 100 by the concurrent session before this audit).

## Mini/nano bar (N-01 evidence)
- **Visible on every activity**: library tabs (`lib-playing.xml` — metadata
  `Dust In The Summer Rain` / `Parov Stelar feat. Lilja Bloom - The
  Princess` two lines + **3 transport ImageButtons** [726|844|962,
  2025][·,2117]), queue, settings, search.
- **While playing**: bar keeps metadata + the 3 buttons (icon flip =
  visual — `lib-playing.png` / `np-playing.png` for human review; buttons
  carry NO content-desc in any state — a11y gap ReTune has and the new
  app must not replicate).
- **While stopped** (`/tmp/stop_lib.xml`, 2026-11-19): bar remains with
  the 3 transport buttons, **metadata hidden** (no text nodes).
- Bar tap (text zone) → NowPlayingViewActivity (verified this window —
  use the CURRENT hierarchy's bounds: text rows y≈2020-2122, buttons x≥726).

## Drawer (N-02 evidence, re-dumped `/tmp/dw_audit.xml`)
Sections: **Connected To** (server name row, non-nav) · **Playing** (Now
Playing, Up Next) · **Libraries** (one row per library; current marked at
container level only — **no a11y selection state on any row**) · **Views**
(Playlists/Artists/Albums/Songs/Genres/Composers). No Settings/Outputs/
Search in the drawer (Search + Speakers are app-bar actions there).
Scope: opens from library/np/search/settings; **does NOT open from
UpNextViewActivity** (its title area is the Up Next/History spinner).

## Volume keys + toaster (A4 — machine-verified now)
- Keys intercepted app-wide: VOL_DOWN on np AND VOL_UP on library both hit
  `dmcp.volume` (logcat) — step 5, 100→95→100 (restored; 100 was the
  concurrent session's value).
- Toaster: center-band overlay (pixels differ y≈900–1500 in t1/t2, back
  to baseline by t3) — **appears ~1–2.5 s then auto-hides** (byte-diff
  evidence; `22-volume-toaster/screen.png` replaced with the caught frame
  `/tmp/t1.png`). No a11y node (Toast).

## Queue row affordances (N-03/N-04 evidence)
- Header accessory → popup: **Clear**.
- Row accessory → popup menu: **Play Next** · **Remove** (CheckedTextViews
  [798,503][1059,757]; opened with player `pause` verified — no audio
  request in logcat).
- Tap-and-hold row = drag (visual lift only, a11y silent; `drag_hold.png`
  /tmp). Row tap itself = nothing (no in-place skip observed — contrast:
  new app skips via PUT play?item_id per #21).

## External playback observation (this session's audit window)
Player was found `play` 211617 @183.8 s vol **100** before the audit
(concurrent session's cue — matches AGENTS note); paused immediately
(~15 s audible), recorded in SESSION-LOG.
