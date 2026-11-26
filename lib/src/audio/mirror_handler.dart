import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../core/artwork_probe.dart';
import '../player/player_controller.dart';
import '../player/player_state.dart';
import '../settings/settings_store.dart';

// -- pure notification mapping (R-07) ---------------------------------------
//
// Kept as free functions so the metadata/controls mapping is unit-testable
// without an audio_service platform (test/notification_mapping_test.dart).

/// The media-item mirror of the now-playing queue item (R-07: title,
/// artist, album, artwork, duration). Null when there is no item to show.
///
/// [hideArtwork] drops `artUri` from the published item — the caller
/// (MirrorAudioHandler._sync) sets it after [ArtworkProbe] confirmed the
/// artwork URL answers 204 (R-03 unit 010: audio_service's
/// flutter_cache_manager fetch of a 204 `artUri` logs `Invalid statusCode:
/// 204` per artwork-less item; not publishing the URL removes the fetch).
/// Default `false` keeps the pure mapping (and its tests) unchanged.
MediaItem? mediaItemFor({
  required NowPlayingItem? item,
  required PlayerState? p,
  bool hideArtwork = false,
}) {
  if (item == null) return null;
  return MediaItem(
    id: item.uri ?? 'owntone:${item.id ?? 'now_playing'}',
    title: item.title ?? 'Unknown title',
    artist: item.artist ?? 'Unknown artist',
    album: item.album,
    artUri: hideArtwork ? null : item.artworkUrl,
    duration: item.lengthMs != null
        ? Duration(milliseconds: item.lengthMs!)
        : null,
  );
}

/// The row published while the server is `stop`ped (issue #83, PR #87
/// review): replaces the previous track's metadata on the tile with a
/// neutral stopped row, matching what the in-app screens render
/// (`now_playing_screen.dart` shows 'Stopped').
///
/// Publishing this instead of `null` is the only metadata-clear path the
/// pinned audio_service 0.18.19 has: `_observeMediaItem` discards a null
/// before any platform call (`lib/audio_service.dart:1029-1033`), so
/// `mediaItem.add(null)` never reaches `MediaSessionCompat` and the shade
/// would keep the last track's title/artist/album. A fresh non-null item
/// does reach `setMetadata`; the Java builder is rebuilt per notify, so the
/// null artist/album/duration blank those lines and null `artUri` drops the
/// large icon on the next publish (residual: on API < 33 a previously
/// loaded `artBitmap` can persist in the re-raised notification).
MediaItem stoppedMediaItem() =>
    const MediaItem(id: 'owntone:stopped', title: 'Stopped');

/// Same now-playing item across a refetch: `PlayerController` replaces
/// `_nowPlaying` with a fresh instance on every `GET /api/queue`
/// (id=now_playing), so [identical] cannot be used across an await —
/// compare the stable identity fields instead.
bool _sameNowPlaying(NowPlayingItem? a, NowPlayingItem? b) =>
    a != null &&
    b != null &&
    a.id == b.id &&
    a.uri == b.uri &&
    a.title == b.title &&
    a.lengthMs == b.lengthMs &&
    a.artworkUrl == b.artworkUrl;

/// Transport controls for the notification / lockscreen (SCREENS.md:
/// play/pause · next · previous — the v1 notification has no stop or mode
/// controls).
///
/// Issue #83: a **stopped** server publishes `play` only. OwnTone does not
/// honour a skip while stopped — measured on the Pixel 6 host pass, `PUT
/// /api/player/next` answered 204 with the queue pointer frozen (a silent
/// no-op) and `previous` answered HTTP 500 — so exposing them made the tile
/// advertise a transport the server cannot service: taps looked accepted and
/// did nothing visible (the 500 surfaces only as an in-app snackbar, which
/// the shade cannot show). `play` *is* honoured from `stop` — the current
/// item stays queued and `PUT /api/player/play` restarts it — which is also
/// why NowPlaying keeps its play button live while stopped
/// (`now_playing_screen.dart`) and disables previous/next there. Do not
/// "unify" the stopped branch with the paused one: the tile mirrors what the
/// server acts on, not what the queue contains.
List<MediaControl> controlsFor(PlayerState p) {
  if (p.isStopped) return const [MediaControl.play];
  return p.isPlaying
      ? [
          MediaControl.pause,
          MediaControl.skipToNext,
          MediaControl.skipToPrevious,
        ]
      : [
          MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.skipToPrevious,
        ];
}

/// The rocker step for a volume direction (R-06, unit 003): `null` means no
/// volume change — `same` is Android's key-release / end-of-sequence marker,
/// not a change (spike Finding 10: mapping it to "lower" silently cancels
/// every press and makes the volume drift down).
int? rockerStepFor(AndroidVolumeDirection direction, {required int step}) {
  if (direction == AndroidVolumeDirection.raise) return step;
  if (direction == AndroidVolumeDirection.lower) return -step;
  return null;
}

/// The session's volume-control type (D20): server-volume mapping only
/// while the app is foregrounded. `absolute` routes rocker presses to the
/// session; `fixed` takes the session out of volume-key selection so a
/// backgrounded app leaves the phone's volume keys to their normal
/// behaviour — even while the server is playing.
AndroidVolumeControlType volumeControlTypeFor(bool appForeground) =>
    appForeground
    ? AndroidVolumeControlType.absolute
    : AndroidVolumeControlType.fixed;

/// The playback-state mirror. [positionMs] overrides the server progress
/// (the 1 s extrapolation ticker feeds it while the server plays).
PlaybackState playbackStateFor(PlayerState p, {int? positionMs}) =>
    PlaybackState(
      controls: controlsFor(p),
      processingState: AudioProcessingState.ready,
      playing: p.isPlaying,
      updatePosition: Duration(
        milliseconds: positionMs ?? p.itemProgressMs ?? 0,
      ),
      speed: 1.0,
    );

/// audio_service handler that *mirrors* the remote server instead of playing
/// local audio:
///
///  - `playbackState.playing` / `mediaItem` / `androidPlaybackInfo` are
///    pushed from [PlayerController].
///  - Media-session commands (notification, lockscreen, hardware keys) are
///    forwarded to the server via [PlayerController].
///
/// Known audio_service constraint (verified in 0.18.19 source): the service
/// only starts the foreground service and creates the media notification on
/// a `playing` false→true transition (`AudioService.enterPlayingState`). A
/// remote mirror that boots while the server is paused would otherwise never
/// show a notification, so [start] performs a brief one-shot "wake": report
/// `playing: true` once (with the real metadata/controls), then the real
/// state. `androidStopForegroundOnPause: false` keeps the FGS up afterwards.
class MirrorAudioHandler extends BaseAudioHandler {
  MirrorAudioHandler(this._player, {required SettingsStore settings})
    : _settings = settings,
      super();

  final PlayerController _player;
  final SettingsStore _settings;

  /// The rocker step (R-14): 1–10, default 5, from [SettingsStore], read
  /// **at keypress time** — a change in the Settings screen applies to the
  /// next press with no restart (SharedPreferences is an in-memory cache).
  int get rockerStep => _settings.rockerStep;
  Timer? _positionTicker;
  bool _started = false;
  bool _woken = false;

  /// D20: whether the app is foregrounded. Conservative default — a
  /// service-restarted process (no UI) is backgrounded until the first
  /// `AppLifecycleState.resumed`.
  bool _appForeground = false;

  /// Pushed from main() on every app lifecycle transition. Re-publishes the
  /// playback info immediately so the session's volume-control type follows
  /// the app without waiting for the next player change.
  void setAppForeground(bool foreground) {
    final changed = _appForeground != foreground;
    _appForeground = foreground;
    if (changed && _started) unawaited(_publishPlaybackInfo());
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _player.addListener(_onPlayerChanged);
    // The one-shot wake must carry real metadata: wait briefly for the
    // first server state (the controller may still be fetching its first
    // slice when the audio service starts).
    var waited = 0;
    while (_player.player == null && waited < 100) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      waited++;
    }
    await _sync();
    await _wakeMediaSession();
  }

  void _onPlayerChanged() {
    unawaited(_sync());
  }

  /// Push the controller's state into the media session, then keep the
  /// notification progress bar fresh with 1 s ticker while the server
  /// plays (OwnTone sends no periodic `player` events).
  Future<void> _sync() async {
    final p = _player.player;
    final item = _player.nowPlaying;
    // Issue #83: `stop` is authoritative over the item. OwnTone keeps
    // `item_id` set and `GET /api/queue?id=now_playing` keeps answering the
    // track after a stop, so testing `item != null` first made the stopped
    // branch unreachable — the tile kept the previous track's metadata and
    // looked like a loaded, resumable card while the server was stopped.
    final stopped = p != null && p.isStopped;

    if (item != null && !stopped) {
      // R-03 unit 010 (device-side half): never publish an `artUri` the
      // server answers with 204 — audio_service's flutter_cache_manager
      // would fetch it and log `Invalid statusCode: 204` as an exception
      // on the happy path. The probe resolves once per URL (cached;
      // failures/timeouts answer false so a reachable-but-flaky artwork
      // endpoint degrades to today's behaviour, not missing art).
      final artwork = item.artworkUrl;
      final hideArtwork =
          artwork != null && await ArtworkProbe.isNoArtwork(artwork);
      // The await let another (newer) sync start if the item changed —
      // every _nowPlaying replacement is followed by a notifyListeners →
      // _sync, so skipping here never drops metadata.
      if (!_sameNowPlaying(_player.nowPlaying, item)) return;
      // Re-read: the await also let the server reach `stop`, and a stopped
      // publish must not land a fresh item after the placeholder below.
      // (The stop itself re-notifies the controller → _sync, so the
      // placeholder always arrives; this guard only orders the two.)
      if (_player.player?.isStopped ?? false) return;
      mediaItem.add(
        mediaItemFor(item: item, p: _player.player, hideArtwork: hideArtwork),
      );
    } else if (stopped) {
      // PR #87 review (blocking): a `null` publish is discarded by
      // audio_service 0.18.19 before any platform call — `_observeMediaItem`
      // early-returns on null (`lib/audio_service.dart:1029-1033`) — so
      // `mediaItem.add(null)` left the previous track's title/artist/album
      // on the tile (the Java `mediaMetadata` field is reset only in
      // `onDestroy()`). Publishing the neutral stopped row is the only
      // metadata-clear path the pinned plugin has: a fresh non-null id
      // reaches `setMetadata` and `buildNotification()` re-raises it.
      mediaItem.add(stoppedMediaItem());
    }

    if (p == null) return;

    // The library extrapolates `position` from updatePosition+updateTime
    // while playing, so a fresh updatePosition per event (and per ticker
    // tick) is what keeps the notification progress honest.
    playbackState.add(playbackStateFor(p));

    _publishPlaybackInfo();

    if (p.isPlaying) {
      _startPositionTicker(p);
    } else {
      _stopPositionTicker();
    }
  }

  /// Remote playback info: this routes volume-rocker presses to
  /// [androidAdjustRemoteVolume] while foregrounded (D20: `fixed` type
  /// while backgrounded keeps the keys on the system streams).
  Future<void> _publishPlaybackInfo() async {
    final p = _player.player;
    if (p == null) return;
    androidPlaybackInfo.add(
      RemoteAndroidPlaybackInfo(
        volumeControlType: volumeControlTypeFor(_appForeground),
        maxVolume: 100,
        volume: p.volume,
      ),
    );
  }

  void _startPositionTicker(PlayerState p) {
    if (_positionTicker != null) return;
    var baseMs = p.itemProgressMs ?? 0;
    var baseTime = DateTime.now();
    final totalMs = p.itemLengthMs;
    _positionTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final current = _player.player;
      if (current == null || !current.isPlaying) return;
      if (current.itemProgressMs != baseMs) {
        // Server refetched with fresh progress — resync the extrapolation.
        baseMs = current.itemProgressMs ?? baseMs;
        baseTime = DateTime.now();
      }
      var ms = baseMs + DateTime.now().difference(baseTime).inMilliseconds;
      if (totalMs != null && ms > totalMs) ms = totalMs;
      playbackState.add(playbackStateFor(current, positionMs: ms));
    });
  }

  void _stopPositionTicker() {
    _positionTicker?.cancel();
    _positionTicker = null;
  }

  /// The one-shot wake described in the class docs. Skipped entirely when
  /// no server state exists yet — a disconnected app must not post a bogus
  /// "playing" notification.
  Future<void> _wakeMediaSession() async {
    if (_woken) return;
    _woken = true;
    final p = _player.player;
    if (p != null && !p.isPlaying) {
      playbackState.add(
        PlaybackState(
          controls: controlsFor(p),
          processingState: AudioProcessingState.ready,
          playing: true,
        ),
      );
      // Platform channel messages are FIFO: the next _sync() (real state)
      // is only processed after this one, so the FGS has been entered by
      // then and the notification already exists.
    }
    await _sync();
  }

  // -- media-session commands → server --------------------------------------

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> skipToNext() => _player.next();

  @override
  Future<void> skipToPrevious() => _player.previous();

  @override
  Future<void> seek(Duration position) =>
      _player.seekMs(position.inMilliseconds);

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _player.setShuffle(shuffleMode == AudioServiceShuffleMode.all);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _player.setRepeat(switch (repeatMode) {
        AudioServiceRepeatMode.none => Repeat.off,
        AudioServiceRepeatMode.all ||
        AudioServiceRepeatMode.group => Repeat.all,
        AudioServiceRepeatMode.one => Repeat.single,
      });

  // Volume rocker (D20, R-06): the session's remote volume provider routes
  // rocker presses here while foregrounded (`absolute` volume-control type).
  // Backgrounded, the session is published `fixed`, so Android leaves the
  // keys to the system streams — and these overrides stay no-ops as a
  // second layer against the transition window, where a key event could
  // still arrive for a session the system was just deselecting.
  @override
  Future<void> androidSetRemoteVolume(int volumeIndex) {
    if (!_appForeground) return Future.value();
    return _player.setVolume(volumeIndex);
  }

  @override
  Future<void> androidAdjustRemoteVolume(AndroidVolumeDirection direction) {
    if (!_appForeground) return Future.value();
    final step = rockerStepFor(direction, step: rockerStep);
    if (step == null) return Future.value();
    return _player.stepVolume(step);
  }
}
