# ARCHITECTURE — OwnTone Remote

**Status: v0.1 draft.** Structure is settled (D10/D11/D3); details that
depend on the spike outcome (FGS survival, remote-volume behaviour) are
marked `(spike-dependent)`. Finalized in `spec-authoring`.

## Principles

1. **The UI never sees the protocol.** All server interaction goes through
   the domain `MusicProvider` interface. OwnTone is implementation #1.
2. **Websocket events are invalidations, not state.** The server is the
   source of truth; the app re-fetches (D2). No local prediction of
   playback position except a short local ticker while playing.
3. **Tests are the source of truth** for behaviour (ai-dlc). Every R-ID has
   tests; live-server tests are `@Tags('live')` and out of the gate.
4. **The app does not play audio locally** (N5). `audio_service` is used for
   the media session / notification / remote-volume plumbing only; its
   `AudioStream` is never fed a real media stream.

## Layers

```
lib/
├── main.dart                  # DI wiring, provider registration, app shell
├── core/
│   ├── errors.dart            # typed errors (ConnectionError, ApiError(401/5xx), …)
│   ├── backoff.dart           # exponential backoff helper (unit-tested)
│   └── log.dart
├── domain/
│   ├── models/                # PlayerState, Track, Album, Artist, Playlist,
│   │                          # QueueItem, Output, Genre, SearchResults,
│   │                          # Paging<T>, ServerConfig
│   ├── music_provider.dart    # THE interface + ProviderCapabilities
│   └── repeat_mode.dart
├── data/
│   ├── providers/
│   │   └── owntone/
│   │       ├── owntone_api.dart        # dio REST client (typed per endpoint)
│   │       ├── owntone_socket.dart     # WS client: subscribe, event stream,
│   │       │                            #   reconnect/backoff, resubscribe
│   │       ├── owntone_music_provider.dart  # implements MusicProvider
│   │       └── mappers.dart            # JSON models → domain models
│   └── settings_store.dart    # shared_preferences: host, port, rocker step
├── presentation/
│   ├── providers/             # ChangeNotifier controllers (package: provider)
│   │   ├── connection_controller.dart
│   │   ├── player_controller.dart      # owns PlayerState, optimistic UI,
│   │   │                                #   pause-origin tracking (R-08)
│   │   ├── library_controller.dart
│   │   ├── outputs_controller.dart
│   │   └── queue_controller.dart
│   ├── screens/               # per SCREENS.md (spec-authoring)
│   └── widgets/               # track row, rating stars, output row, …
└── platform/
    ├── audio_service_handler.dart   # AudioServiceHandler: mirrors state,
    │                                #   remote volume (androidSetRemoteVolume)
    └── call_state.dart              # MethodChannel wrapper for the Kotlin
                                     #   TelephonyCallback channel
```

**Second-backend extension (D10):** a new backend = `data/providers/<x>/`
implementing `MusicProvider` + a factory entry
(`providerFactory(ProviderKind kind)` in `main.dart`). Capabilities let the
UI hide unsupported features. No controller, screen or widget changes.

## `MusicProvider` contract (sketch)

```dart
class ProviderCapabilities {
  final bool outputs;      // remote speaker selection
  final bool rating;
  final bool search;
  final bool consume;
  final bool queueEditing;
  final bool composerBrowse; // false on OwnTone (search-type only)
}

abstract class MusicProvider {
  ProviderCapabilities get capabilities;
  Stream<ProviderEvent> get events;       // invalidation events, typed
  Stream<PlayerState> get playerState;    // refetched on player/volume/options
                                          //   + a local ticker while playing

  Future<void> connect(ServerConfig cfg);
  Future<void> disconnect();

  // Transport (R-04, R-05)
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> next();
  Future<void> previous();
  Future<void> seek(Duration position);
  Future<void> setShuffle(bool enabled);
  Future<void> setRepeat(RepeatMode mode);
  Future<void> setConsume(bool enabled);

  // Volume (R-06)
  Future<void> setMasterVolume(int percent);   // 0..100
  Future<void> adjustMasterVolume(int step);   // rocker

  // Queue (R-11)
  Future<QueueSnapshot> getQueue();
  Future<void> playUris(List<String> uris, {bool clearFirst = true}); // SUPERVISED
  Future<void> addUris(List<String> uris);     // no autoplay
  Future<void> clearQueue();

  // Library (R-10)
  Future<Paging<Playlist>> playlists({int offset = 0, int limit = 50});
  Future<Paging<Track>> playlistTracks(String playlistId, {int offset = 0, int limit = 50});
  Future<Paging<Artist>> artists({int offset = 0, int limit = 50});
  Future<Paging<Album>> artistAlbums(String artistId, {int offset = 0, int limit = 50});
  Future<Paging<Album>> albums({int offset = 0, int limit = 50});
  Future<Paging<Track>> albumTracks(String albumId, {int offset = 0, int limit = 50});
  Future<Paging<String>> genres();

  // Search (R-13)
  Future<SearchResults> search(String query, {int limit = 20});

  // Outputs (R-09)
  Future<List<Output>> getOutputs();
  Future<void> setEnabledOutputs(List<String> outputIds);
  Future<void> setOutputVolume(String outputId, int percent);
  Future<void> setOutputPin(String outputId, String pin);

  // Rating (R-12)
  Future<void> setTrackRating(String trackId, int percent); // 0..100
}
```

Domain models are protocol-neutral (e.g. `Track.rating` is `int?` 0–100;
`Output.type` is a string). OwnTone-specific quirks (relative artwork URLs,
string-vs-int id types, `uri` fields) live in `mappers.dart`.

## State flow

```
                ┌────────────────────────────────────────────────┐
                │              PlayerController                  │
 user action ──▶│  optimistic update → MusicProvider → REST      │
                │  PlayerState ◀── refetch ◀── invalidation ────┼──▶ MusicProvider
                └───────────────┬───────────────────────────────┘   (OwnTone)
                                │ stream
              ┌─────────────────┼──────────────────┐
              ▼                 ▼                  ▼
        Screens (UI)   AudioServiceHandler   (later: widgets)
                          │
                          ▼
              notification / lockscreen / remote volume
```

- WS event → `ProviderEvent` → controller refetches its slice → stream
  emits → UI + handler update. One source of truth per slice; no
  controller-to-controller writes.
- `PlayerController` tracks **pause origin** (user vs call) for the R-08
  auto-resume rule: resume on call-end only if the call caused the pause.

## OwnTone provider details

- `owntone_api.dart`: dio, base URL `http://host:port`, 10 s timeouts;
  `artworkUrl` resolver (relative → absolute, appends `?maxwidth=`);
  typed errors on 401/404/5xx/network.
- `owntone_socket.dart`: `ws://host:<websocket_port from /api/config>/`,
  sends `{"notify":[...]}` on connect and after every (re)connect;
  reconnect with `core/backoff.dart`; emits `ProviderEvent` per WS message;
  on reconnect completes → emits a `RefetchAll` event.
- Invalidations: `player`/`volume`/`options` → player slice; `outputs` →
  outputs; `queue` → queue + player (item_id); `database`/`update` →
  library lists that are visible.

## audio_service design (spike-dependent details flagged)

- `AudioService.startForeground` with a custom handler. The handler
  **mirrors** `PlayerController` state into `playbackState`/`mediaItem`
  (`AudioService` treats "playing" as `PlayerState.playing` even though
  no local audio flows — this is the remote-control pattern; verify
  Android-16 FGS consequences in the spike).
- `(spike-dependent)` FGS type: `mediaPlayback` is the candidate — a
  media session exists and controls remote playback. Fallback if Android
  16 rejects it: `dataSync` has a 6 h limit (unacceptable) → Kotlin+Media3
  fallback (PLAN §11).
- Remote volume: publish `RemoteAndroidPlaybackInfo(max: 100, current: v)`;
  implement `androidSetRemoteVolume` / `androidAdjustRemoteVolume` →
  `MusicProvider.setMasterVolume/adjustMasterVolume` (R-06).
- Notification: `androidNotificationIcon`, media style, artwork, controls
  (play/pause/prev/next). `(spike-dependent)` behaviour while paused.

## Call-state channel

Kotlin side (~30 lines): `MethodChannel("owntone_remote/call_state")`,
`TelephonyCallback` (API 31+) registered in an `Application` subclass;
events `idle`/`ringing`/`offhook` → Dart stream. `PlayerController`:
`ringing|offhook` → if state==play, `pause()` + mark pause-origin=call;
`idle` → if pause-origin==call, `resume()` (R-08, supervised test).

## Error / offline policy (v1)

- `ConnectionController` states: `idle | connecting | connected | offline |
  error(message)`. App-wide banner when not connected.
- Controls while offline: disabled with a tooltip (no offline queue in v1 —
  open item in PLAN §12).
- REST failure → typed error surfaced (snackbar) + state refetch; no
  cascading retries beyond the WS backoff.

## Testing strategy

- `test/fakes/`: `FakeMusicProvider` (scripted streams), `FakeOwnToneApi`
  (in-memory dio interceptor or direct fake), fake WS.
- Unit: mappers (JSON fixtures from API.md), backoff, controllers
  (state transitions incl. R-08 pause-origin), provider→interface mapping.
- Widget: screens against fakes (loading/empty/error/offline states,
  R-10).
- `@Tags('live')`: real-server round trips per R-ID; excluded from the
  gate; playback-touching ones run only in supervised windows (N7).
