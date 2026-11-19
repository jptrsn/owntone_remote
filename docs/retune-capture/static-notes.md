# Static pass — ReTune 3.5.23 (`Retune_3.5.23_APKPure.apk`)

Tooling (2026-11-19): **REA `rea-agents` 6.7.0** `decode-android-resources`
(apktool lane; client 3.0.3 via PATH — outside REA's recommended window,
observation kept) + plain `apktool d -s` → `tools/retune/decoded/`
(gitignored, regenerable). REA evidence: `ev_86fc59ef…` (subject sha256
`b1279ad6…4b98`).

## Metadata (verified)
package `com.squallydoc.retune` · versionName 3.5.23 · versionCode 134 ·
minSdk 13 · **targetSdk 19** (install floor explanation — unit 001).

## Manifest component inventory
Activities (in-scope): RetuneAndroidActivity (launcher → restores last
view), LibraryViewActivity, AlbumsViewActivity, SongsViewActivity,
ArtistsViewActivity, PlaylistSongsViewActivity, PlaylistsViewActivity,
SearchViewActivity, NowPlayingViewActivity (exported, singleTop),
SpeakersViewActivity (exported), UpNextViewActivity, PlayQueueViewActivity,
RetunePreferencesActivity, ConnectingActivity, SelectLibraryViewActivity,
SwitchSharedLibraryActivity (multi-library — user server has 1 → drop),
PairLibraryActivity/PairManuallyViewActivity (out: pairing UI).
Out-of-scope activities (one-liners): RadioStationViewActivity,
VideoDeviceViewActivity (exported!), TVShowsViewActivity,
PodcastsViewActivity, ClassesViewActivity (iTunes U), AudioBooksViewActivity
— `out: itunes-only`.
Services: PairingService, LibraryLocatorService (JmDNS),
LibraryCommunicatorService (DAAP HTTP).
Receivers: MusicIntentReceiver (MEDIA_BUTTON — lockscreen/rocker path),
VolumeChangeReceiver (custom volume intents), 4× home-screen widgets
(Light/Dark × Small/Large) — `out: scope` (widget feature; new app has none;
not proposed — see diff list D-11).
Permissions: INTERNET, CHANGE_WIFI_MULTICAST_STATE + ACCESS_WIFI_STATE
(discovery), READ_PHONE_STATE (pause-on-call), WAKE_LOCK.
Note: `com.crashlytics.ApiKey` baked in (fabric telemetry — new app ships none).

## Preference keys (res/xml/preferences.xml) — keys/defaults vs runtime
| key (string-ref) | default | runtime captured |
|---|---|---|
| run_in_background_key | true | ON |
| disconect_time_key (sic) | default_disconnect_time | Immediately |
| use_lockscreen_controls_key | true | ON |
| pause_on_incoming_calls_key | false | OFF |
| use_physical_volume_buttons_key | true | ON |
| reorder_up_next_with_artwork_key | false | OFF |
| default_view_upon_connection_key | int | (Library View) |
| default_view_key | int | Playlists |
| use_theme_key | default_theme_value | Light |
| show_rating_on_now_play_key | true | ON |
| half_stars_key | false | OFF |
| screen_lock_key | false | OFF |
Runtime walk = ground truth; static pass confirms nothing hidden beyond
Donate/Licenses/Special Thanks/Version rows.

## Layout reconciliation (132 layouts in res/layout)
- **Covered by walk** (≈40 incl. row templates): libraryview,
  playlist_view_fragment, playlist_songs_*, artists/albums/genres/songs/
  courses-equivalents + advanced_* variants, media_list/grid/drag_sort
  display views, search_*, now_playing(_tab7)_*, play_queue/up_next(_history)
  fragments, playing_indicator, mini/nano_now_playing, speakers (speaker_view/
  renderer), preferences/preference_layout, custom_(big_)notification,
  master_volume_toaster, donate/license/special_thanks dialogs, basic_header/
  divider, simple_* rows for songs/albums/artists/playlist(/song)/up_next/
  search/view/shared_library.
- **`out: itunes-only`** (46): audiobooks/courses/classes/podcasts/series/
  movies/rentals/tv_shows/radio(genres,stations,tunes)/genius_mixes +
  their grid variants and simple rows.
- **`out: scope`** (4): widget layouts ×4 (manifest note above).
- **`out: pairing`** (2): pair_library, pair_manually_view (user decision —
  IP/port entry only; discovery = D-01).
- **Deferred** (3): `connecting` (needs server-stop to reach),
  `ratings_dialog` (trigger unidentified — PNG human review),
  `select_library(_row)` (multi-library — drop candidate).
- **No orphan screens found**: every non-out layout maps to a captured or
  explicitly deferred walk state. Walk ↔ static pass reconcile clean.

## DAAP request inventory (logcat, walk) → JSON equivalence
All observed request shapes had a JSON equivalent or are out (full mapping
in `feature-inventory.md`). No endpoint required a DAAP-only capability —
supports D5 (no fallback spike needed).
