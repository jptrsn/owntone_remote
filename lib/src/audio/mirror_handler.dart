import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';

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
List<MediaControl> controlsFor(PlayerState p) => p.isPlaying
    ? [MediaControl.pause, MediaControl.skipToNext, MediaControl.skipToPrevious]
    : [MediaControl.play, MediaControl.skipToNext, MediaControl.skipToPrevious];

/// The rocker step for a volume direction (R-06, unit 003): `null` means no
/// volume change — `same` is Android's key-release / end-of-sequence marker,
/// not a change (spike Finding 10: mapping it to "lower" silently cancels
/// every press and makes the volume drift down).
int? rockerStepFor(AndroidVolumeDirection direction, {required int step}) {
  if (direction == AndroidVolumeDirection.raise) return step;
  if (direction == AndroidVolumeDirection.lower) return -step;
  return null;
}

/// The AOSP volume-key direction names the Kotlin hook forwards on the
/// `owntone_remote/volume_keys` channel (issue #84). `null` for anything
/// else — an unrecognised name must never reach the server.
AndroidVolumeDirection? volumeDirectionForName(String name) => switch (name) {
  'raise' => AndroidVolumeDirection.raise,
  'lower' => AndroidVolumeDirection.lower,
  'same' => AndroidVolumeDirection.same,
  _ => null,
};

/// The session's volume-control type (D20, reworked by issue #84): **always**
/// `fixed`. The session must never expose a volume control — not foregrounded
/// and not backgrounded.
///
/// `absolute` was what made SystemUI's media tile / output row render a
/// slider showing the *server* volume, and what routed the hardware rocker to
/// [MirrorAudioHandler.androidAdjustRemoteVolume]. There is no audio_service
/// configuration that keeps that mapping while hiding the slider
/// (`AudioService.setPlaybackInfo` only rebuilds the `VolumeProviderCompat`
/// when type/maxVolume change), so the rocker→server path is app-local
/// instead: the Activity's `onKeyDown` hook → the volume-key channel →
/// [MirrorAudioHandler.handleVolumeKey]. `fixed` takes the session out of
/// volume-key selection entirely, in every app state.
const sessionVolumeControlType = AndroidVolumeControlType.fixed;

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
  ///
  /// Since issue #84 this gates the *foreground key path* only: the media
  /// session is published `fixed` in every state, so the session itself can
  /// never receive a volume key.
  bool _appForeground = false;

  /// Pushed from main() on every app lifecycle transition.
  ///
  /// It used to re-publish the playback info so the session's volume-control
  /// type could follow the app (`absolute` ↔ `fixed`, the old D20 shape). The
  /// type is now constant, so instead this gates the foreground key path: the
  /// Activity-side hook only forwards keys while the app is resumed, which is
  /// what keeps a backgrounded / screen-off / service-only app from touching
  /// the server volume at all (R-06).
  void setAppForeground(bool foreground) {
    final changed = _appForeground != foreground;
    _appForeground = foreground;
    if (changed && _volumeKeysStarted) {
      unawaited(_setPlatformForwarding(foreground));
    }
  }

  // -- foreground volume key path (R-06/D20, issue #84) ----------------------

  /// Kotlin side: `VolumeKeys` (fed by `MainActivity.onKeyDown`/`onKeyUp`/
  /// `onKeyMultiple`). The platform forwards a key only while an Activity is
  /// attached *and* this side has reported the app resumed via
  /// `startForwarding`, so a backgrounded app never receives one. The
  /// session's own remote-volume provider is deliberately `fixed`, so Android
  /// never routes those keys to the media session (see
  /// [sessionVolumeControlType]).
  static const volumeKeyChannel = MethodChannel('owntone_remote/volume_keys');

  bool _volumeKeysStarted = false;

  /// Whether the foreground key path is installed. Exposed for tests and for
  /// main()'s degraded-audio path (an app without a handler must leave the
  /// phone's volume keys entirely to the system).
  bool get volumeKeysStarted => _volumeKeysStarted;

  /// Install the foreground key path: listen on [volumeKeyChannel] and ask
  /// the platform to forward volume keys while the app is resumed.
  /// Idempotent. The platform is only told to forward once Dart is actually
  /// listening, so a failed `AudioService.init` (or a handler that was never
  /// created) can never leave the phone's volume keys swallowed.
  Future<void> startVolumeKeys() async {
    if (_volumeKeysStarted) return;
    _volumeKeysStarted = true;
    volumeKeyChannel.setMethodCallHandler(_onVolumeKeyCall);
    await _setPlatformForwarding(_appForeground);
  }

  /// Tear the foreground key path down — the counterpart of
  /// [startVolumeKeys], mirroring the Kotlin plugin's detach cleanup. A key
  /// delivered afterwards is a no-op that the system keeps handling.
  Future<void> stopVolumeKeys() async {
    if (!_volumeKeysStarted) return;
    _volumeKeysStarted = false;
    await _setPlatformForwarding(false);
    volumeKeyChannel.setMethodCallHandler(null);
  }

  Future<void> _setPlatformForwarding(bool forwarding) async {
    try {
      await volumeKeyChannel.invokeMethod<void>(
        forwarding ? 'startForwarding' : 'stopForwarding',
      );
    } on MissingPluginException {
      // No Android side (unit tests, another runner): the path stays a
      // Dart-side no-op, which is the safe direction.
    } on PlatformException {
      // Same treatment; the keys stay with the phone.
    }
  }

  Future<bool> _onVolumeKeyCall(MethodCall call) async {
    if (call.method != 'volumeKey') return false;
    final name = call.arguments;
    if (name is! String) return false;
    final direction = volumeDirectionForName(name);
    if (direction == null) return false;
    return handleVolumeKey(direction);
  }

  /// A forwarded volume key (R-06/D20). Returns whether *this app took the
  /// key* — `true` only when it moved the server. The key-release marker and
  /// anything delivered while the app is not resumed answer `false`.
  ///
  /// The Kotlin side cannot wait for this answer (`invokeMethod` is async
  /// while Android key consumption is synchronous), so it decides from its own
  /// gates; this return value is the Dart-side statement of the same rule and
  /// is what the tests pin.
  ///
  /// The foreground check is the second layer: with no resumed Activity the
  /// hook is not forwarding at all, but a key can still arrive for the
  /// window Android is in the middle of deselecting, and that must never move
  /// the server's volume.
  Future<bool> handleVolumeKey(AndroidVolumeDirection direction) async {
    if (!_appForeground || !_volumeKeysStarted) return false;
    final step = rockerStepFor(direction, step: rockerStep);
    if (step == null) return false;
    await _player.stepVolume(step);
    return true;
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
  /// notification progress bar fresh with a 1 s ticker while the server
  /// plays (OwnTone sends no periodic `player` events).
  Future<void> _sync() async {
    final p = _player.player;
    final item = _player.nowPlaying;

    if (item != null) {
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
      mediaItem.add(
        mediaItemFor(item: item, p: _player.player, hideArtwork: hideArtwork),
      );
    } else if (p != null && p.isStopped) {
      mediaItem.add(null);
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

  /// The session's (always `fixed`) remote playback info. Publishing the type
  /// as a constant — never `absolute` — is what keeps SystemUI's media tile /
  /// output row from rendering a volume slider for the *server* volume, and
  /// keeps the session out of the volume-key selection in every app state
  /// (issue #84). `volume` still mirrors the server so the provider stays
  /// consistent with the real state; nothing renders it while the type is
  /// `fixed`.
  Future<void> _publishPlaybackInfo() async {
    final p = _player.player;
    if (p == null) return;
    androidPlaybackInfo.add(
      RemoteAndroidPlaybackInfo(
        volumeControlType: sessionVolumeControlType,
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

  // Volume rocker (D20, R-06): since issue #84 the media session is always
  // published `fixed`, so Android never routes rocker presses here — the
  // foreground key path ([handleVolumeKey]) owns that mapping. These overrides
  // stay as a second layer: if the platform ever does deliver a remote-volume
  // call (a future audio_service change re-advertising a volume provider, for
  // instance), it must not move the server while the app is backgrounded, and
  // must not move it at all for the absolute-index form the UI no longer has.
  @override
  Future<void> androidSetRemoteVolume(int volumeIndex) => Future.value();

  @override
  Future<void> androidAdjustRemoteVolume(AndroidVolumeDirection direction) =>
      handleVolumeKey(direction).then((_) {});
}
