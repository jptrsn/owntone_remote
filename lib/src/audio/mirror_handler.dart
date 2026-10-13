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

  static const rockerStep = 5;

  final PlayerController _player;
  Timer? _positionTicker;
  bool _started = false;
  bool _woken = false;

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

    // Remote playback info: this routes volume-rocker presses to
    // androidAdjustRemoteVolume instead of a local audio stream.
    androidPlaybackInfo.add(
      RemoteAndroidPlaybackInfo(
        volumeControlType: AndroidVolumeControlType.absolute,
        maxVolume: 100,
        volume: p.volume,
      ),
    );

    if (p.isPlaying) {
      _startPositionTicker(p);
    } else {
      _stopPositionTicker();
    }
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

  // Volume rocker: the media session's remote volume provider routes rocker
  // presses here (RemoteAndroidPlaybackInfo). Android routes the keys to the
  // session only while it is selected (verified: playing, or app foreground);
  // backgrounded + screen off the keys stay with the system streams.
  @override
  Future<void> androidSetRemoteVolume(int volumeIndex) =>
      _player.setVolume(volumeIndex);

  @override
  Future<void> androidAdjustRemoteVolume(AndroidVolumeDirection direction) {
    // "same" is the key-release / end-of-sequence marker, not a volume
    // change — treating it as "lower" cancels (or outraces) the press and
    // makes the volume drift down.
    if (direction == AndroidVolumeDirection.same) return Future.value();
    final step = direction == AndroidVolumeDirection.raise
        ? rockerStep
        : -rockerStep;
    return _player.stepVolume(step);
  }
}
