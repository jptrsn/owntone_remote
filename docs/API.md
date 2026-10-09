# API — OwnTone JSON API (the subset this app uses)

Base: `http://192.168.1.13:3689` (web/JSON port). Websocket on the port
reported by `GET /api/config` → `websocket_port` (here `3688`).
This server has **no HTTP auth configured** (2026-10-08); if auth is later
enabled, `owntone_api.dart` must send Basic auth (R-01 error handling).

Full upstream reference: https://owntone.github.io/owntone-server/json-api
(docs-mcp: `search_docs library: "owntone-server"`).

## Verified live (2026-10-08)

`GET /api/config`:
```json
{
  "library_name": "My Music on hp-server",
  "hide_singles": false,
  "websocket_port": 3688,
  "version": "29.3",
  "buildoptions": ["ffmpeg","Spotify","librespot-c","LastFM","Chromecast","MPD","Websockets","ALSA","Webinterface","Regex"],
  "directories": ["/srv/media"],
  "radio_playlists": false,
  "allow_modifying_stored_playlists": false
}
```

`GET /api/player`:
```json
{
  "state": "pause", "repeat": "off", "consume": false, "shuffle": false,
  "volume": 75, "item_id": 196000,
  "item_length_ms": 353512, "item_progress_ms": 26368,
  "artwork_url": "./artwork/nowplaying"
}
```
Note: `artwork_url` is **relative** — resolve against the web root
(`http://192.168.1.13:3689/artwork/nowplaying`). Present on `/api/player`
even in older versions; may be absent → placeholder (R-03).

`GET /api/outputs` (abridged — 10 outputs; 2 selected):
```json
{ "outputs": [
  { "id": "189206612437240", "name": "Office-Airsync", "type": "AirPlay 1",
    "selected": true, "has_password": false, "requires_auth": false,
    "needs_auth_key": false, "volume": 75, "offset_ms": 0,
    "format": "alac", "supported_formats": ["alac"] },
  { "id": "0", "name": "Server", "type": "ALSA", "selected": true,
    "has_password": false, "requires_auth": false, "needs_auth_key": false,
    "volume": 12, "offset_ms": 0, "format": "pcm", "supported_formats": ["pcm"] },
  { "id": "1814023484", "name": "Bathroom display", "type": "Chromecast",
    "selected": false, "has_password": false, "requires_auth": false,
    "needs_auth_key": false, "volume": 50, "offset_ms": 0,
    "format": "opus", "supported_formats": ["opus"] }
] }
```
Note `type` values seen: `Chromecast`, `AirPlay 1`, `ALSA` (docs list
`AirPlay`, `Chromecast`, `ALSA`, `Pulseaudio`, `fifo` — parse defensively;
treat unknown types as display-only strings).

## Player (R-03, R-04, R-05, R-06)

| Method | Endpoint | Notes |
|---|---|---|
| GET | `/api/player` | state `play`\|`pause`\|`stop`; repeat `off`\|`all`\|`single`; consume, shuffle (bool); volume 0–100; item_id; item_length_ms; item_progress_ms; artwork_url |
| PUT | `/api/player/play` · `pause` · `stop` · `toggle` | 204. **play/toggle = SUPERVISED** (audio) |
| PUT | `/api/player/next` · `previous` | 204. Paused → stays paused (verify in spike); still SUPERVISED-treat |
| PUT | `/api/player/shuffle?state=true\|false` | 204 |
| PUT | `/api/player/repeat?state=off\|all\|single` | 204 |
| PUT | `/api/player/consume?state=true\|false` | 204 |
| PUT | `/api/player/volume?volume=0-100` \| `?step=-100..100` | 204. Omit `output_id` → master. **Rocker uses `step`** |
| PUT | `/api/player/volume?volume=N&output_id=<id>` | 204. Per-output volume (R-09) |
| PUT | `/api/player/seek?position_ms=N` \| `?seek_ms=N` | 204. No audio while paused |

## Outputs (R-09)

| Method | Endpoint | Notes |
|---|---|---|
| GET | `/api/outputs` | `outputs[]` (see live example) |
| GET | `/api/outputs/{id}` | single output |
| PUT | `/api/outputs/set` | body `{"outputs": ["id1","id2"]}` — **enables exactly this set, disables the rest** (use this for multi-select; not N toggles) |
| PUT | `/api/outputs/{id}` | body: `selected` (bool, opt), `volume` (int, opt), `pin` (str, opt), `format`, `offset_ms` |
| PUT | `/api/outputs/{id}/toggle` | 204 (convenience; prefer `/set` for batch) |

PIN: for `has_password`/`needs_auth_key` outputs send `pin` in the PUT body
when enabling (R-09).

## Queue (R-11)

| Method | Endpoint | Notes |
|---|---|---|
| GET | `/api/queue` | `version`, `count`, `items[]` (queue-item objects). `?id=now_playing` shortcut (v28+) |
| GET | `/api/queue?start=N[&end=M]` | paging (end exclusive) |
| POST | `/api/queue/items/add?uris=a,b,c` | `uris` = comma-joined `uri` fields (e.g. `library:track:42`, `library:album:7`, `library:playlist:3`, `library:artist:…`). Optional: `position`, `clear=true`, `playback=start` **SUPERVISED**, `playback_from_position`, `shuffle`, `limit`, or `expression` (smart-playlist query) |
| PUT | `/api/queue/items/{id}\|now_playing?new_position=N[&title=…&artwork_url=…]` | move/edit (v1: `new_position` only if S8 queue-reorder is kept — open item) |
| DELETE | `/api/queue/items/{id}` | 204 |
| PUT | `/api/queue/clear` | 204 |

Add response: `{version, count, items[]}`.

## Library (R-10)

| Method | Endpoint | Notes |
|---|---|---|
| GET | `/api/library` | stats: songs, artists, albums, db_playtime, started_at, updated_at, updating |
| GET | `/api/library/playlists[?offset&limit]` | playlists (no folders; `paging`) |
| GET | `/api/library/playlists/{id}/tracks[?offset&limit]` | `paging` of tracks |
| GET | `/api/library/playlists/0/playlists[?offset&limit]` | **root folder** children (id 0) — for folder browsing if kept |
| GET | `/api/library/artists[?offset&limit]` | `paging` of artists |
| GET | `/api/library/artists/{id}/albums[?offset&limit]` | `paging` of albums |
| GET | `/api/library/albums[?offset&limit]` | `paging` of albums |
| GET | `/api/library/albums/{id}/tracks[?offset&limit]` | `paging` of tracks |
| GET | `/api/library/tracks/{id}` | single track (has `rating`) |
| PUT | `/api/library/tracks/{id}?rating=0-100` | 204 (R-12; supervised). Also `usermark`, `play_count`, `skip_count`, … |
| PUT | `/api/library/tracks` | body `{"tracks":[{"id":1,"rating":100},…]}` batch |
| GET | `/api/library/genres` | `paging` of `{name}` (browse-info) |
| GET | `/api/library/count` | tracks/artists/albums/db_playtime (+`expression`) |

**No `/api/library/composers` endpoint.** Composers exist only as a
`/api/search?type=composers` result type — a composer *browse* screen would
be search-driven (PLAN §12 open item).

**Genre → albums:** `GET /api/search?type=albums&expression=genre is "Name"`
(URL-encode; `Rock/Pop` → `Rock%2FPop`, `Drum & Bass` → `Drum%20%26%20Bass`).

## Search (R-13)

`GET /api/search?type=tracks,artists,albums,playlists,genres,composers&query=Q[&media_kind=music&offset&limit]`
→ response keys per requested type, each a `paging` object.
Case-insensitive title matching. Also `?expression=` (smart-playlist query
language) for `artist|album|track` types.

## Server info (R-01)

`GET /api/config` → `version`, `websocket_port` (0 = WS disabled),
`buildoptions[]`, `library_name`, `directories[]`, `allow_modifying_stored_playlists`.

*(`/api/settings` — web-UI options — is NOT used by this app.
`/api/update`, `/api/rescan`, `/api/library/add`, `/api/library/files`,
playlist PUT/DELETE — out of scope, PLAN §4.)*

## Websocket (R-02)

- URL: `ws://<host>:<websocket_port>/` (here `ws://192.168.1.13:3688/`).
- On connect (and after every reconnect) send:
  ```json
  { "notify": ["player", "volume", "outputs", "queue", "options", "database", "update"] }
  ```
- Server then sends a message per event, e.g. `{ "notify": ["player"] }` —
  the payload is just the event name(s); **refetch the affected slice**.

| Event | Refetch |
|---|---|
| `player` | `/api/player` |
| `volume` | `/api/player` (+ `outputs` if output volume changed) |
| `outputs` | `/api/outputs` |
| `queue` | `/api/queue?id=now_playing` + player (item_id may change) |
| `options` | `/api/player` (shuffle/repeat/consume live there) |
| `database` | visible library lists (R-12 rating refresh) |
| `update` | visible library lists + stats (rescan progress) |

## Artwork

- Relative URLs (the norm here): resolve against the web root
  (`/artwork/nowplaying`, `/artwork/item/<id>`, `/artwork/album/<id>` …).
- `?maxwidth=` / `?maxheight=` supported (scale-down only).
- Absolute URLs point at external images.
- **A relative URL may 404** — always have a placeholder (R-03).

## Objects (fields the app consumes)

**track**: id (int), title, title_sort, artist(+_sort), album(+_sort),
album_id, album_artist(+_sort), album_artist_id, composer, genre, comment,
year, track_number, disc_number, length_ms, **rating (0–100)**, play_count,
skip_count, time_played, time_skipped, time_added, date_released,
seek_ms, media_kind, data_kind, path, uri, artwork_url (opt), usermark,
lyrics.

**album**: id (string), name, name_sort, artist_id, artist, track_count,
length_ms, uri, artwork_url (opt).

**artist**: id (string), name, name_sort, album_count, track_count,
length_ms, uri, artwork_url (opt).

**playlist**: id (string), name, path, parent_id, type (`special|folder|
smart|plain`), smart_playlist, folder, uri.

**queue item**: id, position, track_id, title, artist(+_sort), album(+_sort),
album_id, album_artist(+_sort), album_artist_id, composer, genre, year,
track_number, disc_number, length_ms, media_kind, data_kind, path, uri,
artwork_url (opt), type, bitrate, samplerate, channel.

**output**: id (string!), name, type, selected, has_password, requires_auth,
needs_auth_key, volume, offset_ms, format, supported_formats[].

**paging**: items[], total, offset, limit (`limit: -1` = unbounded request).

**browse-info**: name, name_sort, artist_count, album_count, track_count,
time_played, time_added.

## Where the JSON surface is *simpler* than ReTune's DAAP behaviour

Use these; do not mirror DAAP ceremony:

- Queue play: one `POST /api/queue/items/add?uris=…&clear=true&playback=start`
  replaces ReTune's clear→add→play sequence.
- Speaker selection: one `PUT /api/outputs/set` with the full id list
  replaces per-output enable/disable calls.
- Now-playing item: `GET /api/queue?id=now_playing` (v28+) instead of
  parsing player state + queue.
- Rating: direct `PUT …?rating=` — no DACP rating tags.
- Server discovery of WS port: `/api/config` (no port hardcoding).
