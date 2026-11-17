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
    @visibleForTesting this.confirmPolls = 10,
    @visibleForTesting
    this.confirmPollDelay = const Duration(milliseconds: 300),
  }) : _conn = connection,
       _player = player,
       _logger = Logger(printer: PrettyPrinter(methodCount: 0));

  final ConnectionController _conn;
  final PlayerController _player;
  final Logger _logger;

  /// How many extra GETs [_confirmRating] polls while the server's async
  /// rating commit settles, and how far apart. Measured on OwnTone 29.3
  /// (2026-11-17): `GET /api/library/tracks/{id}` can serve the PRE-write
  /// rating for 0.1–1.6 s after the PUT returned 2xx — a single
  /// confirm-GET lands inside that window and used to roll the optimistic
  /// stars back (the "first tap did nothing, double-tap works" report).
  @visibleForTesting
  final int confirmPolls;
  @visibleForTesting
  final Duration confirmPollDelay;

  /// The pending user write the UI is holding optimistic (server value is
  /// shadowed for this track until a GET confirms it equals [_overrideValue]
  /// — or a newer write, an item change, or a reconnect replaces it; "the
  /// shadow" throughout this file and the PR narrative == this `_override*`
  /// pair). See [_confirmRating] for why it is NOT abandoned when the polls
  /// run out.
  int? _overrideTrackId;
  int? _overrideValue;
  int _confirmGen = 0;

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
    _refetchSub = _conn.refetchAll.listen((_) {
      _overrideTrackId = null;
      _overrideValue = null;
      unawaited(_refreshRating());
    });
    _player.addListener(_onPlayerChanged);
    if (_conn.isConnected) unawaited(_refreshRating());
  }

  void _onConnectionChanged() {
    final phase = _conn.phase;
    final prev = _lastPhase;
    _lastPhase = phase;
    if (phase == ConnectionPhase.connected &&
        prev != ConnectionPhase.connected) {
      // A new connection is a resync-from-reality point: drop any stuck
      // shadow so the following GET can carry server truth (review PR
      // #12 R1: without this, the ws event after reconnect was the very
      // non-matching GET the guard refuses — the "reconnect clears it"
      // claim would have been false).
      _overrideTrackId = null;
      _overrideValue = null;
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

  /// Re-key on item change: the player slice carries the new track id. A
  /// write still unconfirmed for the OLD track must not shadow the new
  /// track's rating — the override is keyed by track id, and the pending
  /// confirm loop bails on the item-change check in [_confirmRating].
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
      // Nothing is current — a pending shadow (stop during the commit
      // window) must not survive to shadow the SAME track's next play:
      // the server value may have settled to something else entirely.
      _overrideTrackId = null;
      _overrideValue = null;
      if (!_disposed) notifyListeners();
      return;
    }
    try {
      final track = await api.getTrack(trackId);
      if (_player.nowPlaying?.trackId != trackId) return; // item moved on
      final fetched = track.rating ?? 0;
      // Server-truth shadowing while a user write is unconfirmed (the
      // async-commit window measured on OwnTone 29.3): a GET still serving
      // the PRE-write value must not roll the optimistic stars back — not
      // from the confirm poll, not from a `database` ws event landing in
      // the same window. Only the VALUE is shadowed; the track-id KEY is
      // server truth and must land (review PR #12 R1: skipping the key
      // here left the stars unrendered — and so un-tappable — after
      // stop/replay inside the window).
      if (trackId == _overrideTrackId && fetched != _overrideValue) {
        _logger.d('rating GET stale vs pending write — holding optimistic');
        if (_nowPlayingTrackId != trackId) {
          _nowPlayingTrackId = trackId;
          if (!_disposed) notifyListeners();
        }
        return;
      }
      // Server truth lands: a GET that MATCHES the pending write (e.g. the
      // late `database`-event refetch after the async commit) ends the
      // shadow — without this clear, the stuck shadow would mask every
      // later external edit of this track. A different track's refresh
      // also drops a stale keyed shadow.
      _overrideTrackId = null;
      _overrideValue = null;
      _nowPlayingTrackId = trackId;
      // An absent field reads as unrated (0), not "no control": the star
      // row must stay tappable so the user can set the first rating.
      _nowPlayingRating = fetched;
    } catch (e) {
      _logger.e('rating refetch failed', error: e);
    }
    if (!_disposed) notifyListeners();
  }

  /// `PUT /api/library/tracks/{id}?rating=` (0–100, the UI's canonical
  /// 0/20/…/100 — `ratingForStars`). **Supervised**: this mutates the real
  /// library (AGENTS.md §4).
  ///
  /// Optimistic when [trackId] is the current item: the stars flip at once
  /// and the value is SHADOWED ([_overrideTrackId]/[_overrideValue]) until a
  /// GET confirms it — OwnTone commits ratings asynchronously, so the
  /// immediate confirm-GET can still serve the pre-write value for over a
  /// second (measured 2026-11-17; a single confirm-GET there is what made
  /// the first tap look dead). On failure the previous value is restored
  /// and the typed error surfaced. Browse rows keep their own optimistic
  /// copy in `RatingStars` — the `database` event's list reload is their
  /// confirmation.
  Future<bool> setRating(int trackId, int rating) async {
    final api = _conn.api;
    if (api == null || !_conn.isConnected) return false;
    final isNowPlaying = trackId == _nowPlayingTrackId;
    final before = _nowPlayingRating;
    final value = rating.clamp(0, 100);
    if (isNowPlaying) {
      _overrideTrackId = trackId;
      _overrideValue = value;
      _nowPlayingRating = value;
      if (!_disposed) notifyListeners();
    }
    try {
      await api.setRating(trackId, rating);
      _actionError = null;
    } catch (e) {
      _logger.e('setRating failed', error: e);
      if (isNowPlaying) {
        _overrideTrackId = null;
        _overrideValue = null;
        _confirmGen++; // abandon any running confirm loop
        _nowPlayingRating = before;
      }
      _actionError = _describeActionError(e);
      _actionErrorSeq++;
      if (!_disposed) notifyListeners();
      return false;
    }
    if (isNowPlaying) await _confirmRating(trackId, value);
    return true;
  }

  /// Poll the track GET until the server's async commit is visible
  /// ([confirmPolls] × [confirmPollDelay], default ~3 s — the measured
  /// stale window is ≤1.6 s). On confirmation the shadow clears and the
  /// (equal) server value applies.
  ///
  /// When the polls run out WITHOUT confirmation the shadow is kept on
  /// purpose: applying the still-stale server value would re-create the
  /// first-tap-rolls-back bug. The shadow is bounded by reality — any later
  /// GET that matches (e.g. the `database` ws event after the commit)
  /// clears it via [_refreshRating], and a newer write, an item change, or
  /// a reconnect replaces it. The price: a web-UI edit made while the
  /// shadow is stuck is masked until one of those events.
  Future<void> _confirmRating(int trackId, int value) async {
    final gen = ++_confirmGen;
    for (var attempt = 0; attempt <= confirmPolls; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(confirmPollDelay);
        if (gen != _confirmGen || _disposed) return; // superseded
      }
      if (_player.nowPlaying?.trackId != trackId) return; // item moved on
      final api = _conn.api;
      if (api == null || !_conn.isConnected) return;
      try {
        final track = await api.getTrack(trackId);
        if (gen != _confirmGen || _disposed) return;
        if (_player.nowPlaying?.trackId != trackId) return;
        if ((track.rating ?? 0) == value) {
          // Two-taps: only the CURRENT shadow may be confirmed — a stale
          // loop's match landing after a newer tap's optimistic set must
          // not re-apply the older value (flicker guard, PR #12 R1 nit).
          if (_overrideTrackId != trackId || _overrideValue != value) return;
          _overrideTrackId = null;
          _overrideValue = null;
          _nowPlayingTrackId = trackId;
          _nowPlayingRating = value;
          if (!_disposed) notifyListeners();
          return;
        }
      } catch (e) {
        _logger.e('rating confirm poll failed', error: e);
        // Keep polling within budget — one transient GET error must not
        // abandon the confirm window (_refresh/ws paths carry the guard
        // meanwhile regardless).
        continue;
      }
    }
    _logger.d(
      'rating write unconfirmed after $confirmPolls polls — '
      'holding optimistic until a matching GET lands',
    );
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
