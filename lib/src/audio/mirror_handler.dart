import 'dart:async';

import 'package:audio_service/audio_service.dart';

import '../player/player_controller.dart';
import '../player/player_state.dart';

// -- pure notification mapping (R-07) ---------------------------------------
//
// Kept as free functions so the metadata/controls mapping is unit-testable
// without an audio_service platform (test/notification_mapping_test.dart).

/// The media-item mirror of the now-playing queue item (R-07: title,
/// artist, album, artwork, duration). Null when there is no item to show.
MediaItem? mediaItemFor({
  required NowPlayingItem? item,
  required PlayerState? p,
}) {
  if (item == null) return null;
  return MediaItem(
    id: item.uri ?? 'owntone:${item.id ?? 'now_playing'}',
    title: item.title ?? 'Unknown title',
    artist: item.artist ?? 'Unknown artist',
    album: item.album,
    artUri: item.artworkUrl,
    duration: item.lengthMs != null
        ? Duration(milliseconds: item.lengthMs!)
        : null,
  );
}

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
  MirrorAudioHandler(this._player) : super();

  /// TODO(R-14): make the rocker step configurable in settings (P2).
  static const rockerStep = 5;

  final PlayerController _player;
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
  /// notification progress bar fresh with a 1 s ticker while the server
  /// plays (OwnTone sends no periodic `player` events).
  Future<void> _sync() async {
    final p = _player.player;
    final item = _player.nowPlaying;

    if (item != null) {
      mediaItem.add(mediaItemFor(item: item, p: p));
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
