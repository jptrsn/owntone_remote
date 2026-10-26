import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../connection/connection_controller.dart';
import '../player/player_controller.dart';

/// The rating slice (R-12, unit 006).
///
/// OwnTone keeps the rating on the *track* (0–100), not on the queue item,
/// so the now-playing rating resolves through [PlayerController]'s
/// now-playing item (`GET /api/queue?id=now_playing` → `track_id`) to
/// `GET /api/library/tracks/{id}` — the same flow docs prescribe, with the
/// queue hop owned by [PlayerController].
///
/// Slice contract (units 004/005b): refetch on the relevant WS event and on
/// reconnect; typed action errors for the snackbar; optimistic mutation with
/// rollback for the one user action here.
///
/// Browse-list rows (album / playlist tracks) are **not** held here — they
/// are the owning [PagedList]'s rows, refreshed wholesale by the
/// `database`-event reload BrowseScreenScaffold wires (R-02: invalidation →
/// refetch). Only the now-playing rating needs its own slice state.
class RatingController extends ChangeNotifier {
  RatingController({
    required ConnectionController connection,
    required PlayerController player,
  }) : _conn = connection,
       _player = player,
       _logger = Logger(printer: PrettyPrinter(methodCount: 0));

  final ConnectionController _conn;
  final PlayerController _player;
  final Logger _logger;

  StreamSubscription<List<String>>? _eventsSub;
  StreamSubscription<void>? _refetchSub;
  ConnectionPhase? _lastPhase;
  bool _initialized = false;
  bool _disposed = false;

  int? _nowPlayingTrackId;
  int? _nowPlayingRating;

  /// The track the cached [nowPlayingRating] belongs to (pairs with it —
  /// the UI shows the rating only while the two agree with the player's
  /// current item).
  int? get nowPlayingTrackId => _nowPlayingTrackId;

  /// Server rating (0–100) of the current item, null until loaded or when
  /// nothing is playing.
  int? get nowPlayingRating => _nowPlayingRating;

  /// Last failed user action (optimistic rollback + snackbar, same shape
  /// as the other slice controllers).
  String? get actionError => _actionError;
  int get actionErrorSeq => _actionErrorSeq;
  String? _actionError;
  int _actionErrorSeq = 0;

  /// Wires the controller to the connection, the WS events, and the player
  /// slice (which owns "which track is current"). Idempotent.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _lastPhase = _conn.phase;
    _conn.addListener(_onConnectionChanged);
    _eventsSub = _conn.events.listen(_onWsEvents);
    _refetchSub = _conn.refetchAll.listen((_) => unawaited(_refreshRating()));
    _player.addListener(_onPlayerChanged);
    if (_conn.isConnected) unawaited(_refreshRating());
  }

  void _onConnectionChanged() {
    final phase = _conn.phase;
    final prev = _lastPhase;
    _lastPhase = phase;
    if (phase == ConnectionPhase.connected &&
        prev != ConnectionPhase.connected) {
      unawaited(_refreshRating());
    }
  }

  /// R-02: `database`/`update` events mean library data changed (a rating
  /// edit in the web UI included) → refetch the visible rating. Item
  /// changes arrive through the player slice, not here.
  void _onWsEvents(List<String> events) {
    if (!_conn.isConnected) return;
    if (!events.any((e) => e == 'database' || e == 'update')) return;
    unawaited(_refreshRating());
  }

  /// Re-key on item change: the player slice carries the new track id.
  void _onPlayerChanged() {
    final trackId = _player.nowPlaying?.trackId;
    if (trackId == _nowPlayingTrackId) return;
    unawaited(_refreshRating());
  }

  /// `GET /api/library/tracks/{trackId}` for the current item. In-flight
  /// staleness is guarded by re-reading the player's track id afterwards.
  Future<void> _refreshRating() async {
    final api = _conn.api;
    if (api == null || !_conn.isConnected) return;
    final trackId = _player.nowPlaying?.trackId;
    if (trackId == null) {
      _nowPlayingTrackId = null;
      _nowPlayingRating = null;
      if (!_disposed) notifyListeners();
      return;
    }
    try {
      final track = await api.getTrack(trackId);
      if (_player.nowPlaying?.trackId != trackId) return; // item moved on
      _nowPlayingTrackId = trackId;
      // An absent field reads as unrated (0), not "no control": the star
      // row must stay tappable so the user can set the first rating.
      _nowPlayingRating = track.rating ?? 0;
    } catch (e) {
      _logger.e('rating refetch failed', error: e);
    }
    if (!_disposed) notifyListeners();
  }

  /// `PUT /api/library/tracks/{id}?rating=` (0–100, the UI's canonical
  /// 0/20/…/100 — `ratingForStars`). **Supervised**: this mutates the real
  /// library (AGENTS.md §4).
  ///
  /// Optimistic when [trackId] is the current item (the stars flip at once;
  /// the confirming GET reconciles); on failure the previous value is
  /// restored and the typed error surfaced. Browse rows keep their own
  /// optimistic copy in `RatingStars` — the `database` event's list reload
  /// is their confirmation.
  Future<bool> setRating(int trackId, int rating) async {
    final api = _conn.api;
    if (api == null || !_conn.isConnected) return false;
    final isNowPlaying = trackId == _nowPlayingTrackId;
    final before = _nowPlayingRating;
    if (isNowPlaying) {
      _nowPlayingRating = rating.clamp(0, 100);
      if (!_disposed) notifyListeners();
    }
    try {
      await api.setRating(trackId, rating);
      _actionError = null;
    } catch (e) {
      _logger.e('setRating failed', error: e);
      if (isNowPlaying) _nowPlayingRating = before;
      _actionError = _describeActionError(e);
      _actionErrorSeq++;
      if (!_disposed) notifyListeners();
      return false;
    }
    if (isNowPlaying) await _refreshRating();
    return true;
  }

  String _describeActionError(Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      if (status != null) {
        return 'Rating failed — server answered HTTP $status.';
      }
      return 'Rating failed — could not reach the server.';
    }
    return 'Rating failed: $e';
  }

  @override
  void dispose() {
    _disposed = true;
    _conn.removeListener(_onConnectionChanged);
    _player.removeListener(_onPlayerChanged);
    _eventsSub?.cancel();
    _refetchSub?.cancel();
    super.dispose();
  }
}
