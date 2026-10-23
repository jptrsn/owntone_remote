import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'library_models.dart';

/// One paged slice of the library (R-10, unit 005a): first page +
/// load-more, no duplication, `total` respected, stale responses dropped.
///
/// Pure logic — no connection awareness. The owning screen decides *when*
/// a load starts (BrowseScreenScaffold) and passes a fetch closure that
/// resolves the current API client at call time.
class PagedList<T> extends ChangeNotifier {
  PagedList({
    required Future<Paging<T>> Function(int offset, int limit) fetch,
    required String Function(T item) keyOf,
    int pageSize = 50,
  }) : _fetch = fetch,
       _keyOf = keyOf,
       _pageSize = pageSize;

  final Future<Paging<T>> Function(int offset, int limit) _fetch;
  final String Function(T item) _keyOf;
  final int _pageSize;

  List<T> _items = const [];
  int _total = 0;
  bool _hasLoaded = false;

  /// Generation of the in-flight load (null = idle); a [reload] bumps
  /// [_gen] so a slow stale response can neither land nor block the
  /// replacement load.
  int _gen = 0;
  int? _loadGen;

  /// Set when a fetch failed: 0 = the first page (full error state),
  /// otherwise the offset that failed (the loaded rows stay, with a
  /// retry row at the bottom).
  int? _failedOffset;
  String? _error;
  bool _started = false;
  bool _disposed = false;

  List<T> get items => _items;
  int get total => _total;
  bool get hasLoaded => _hasLoaded;
  bool get started => _started;

  /// A fetch is in flight for the *current* generation.
  bool get loading => _loadGen != null && _loadGen == _gen;

  int? get failedOffset => _failedOffset;
  String? get error => _error;

  bool get exhausted => _hasLoaded && _items.length >= _total;

  /// Loads page 1 (replaces whatever is loaded).
  Future<void> loadFirst() => _load(offset: 0, initial: true);

  /// Appends the next page. No-op unless a first page loaded, there is
  /// more to fetch, nothing is in flight, and no failure is pending.
  Future<void> loadNext() =>
      _hasLoaded &&
          _items.length < _total &&
          _loadGen == null &&
          _failedOffset == null
      ? _load(offset: _items.length, initial: false)
      : Future.value();

  /// Retry after a failure: the failed page is refetched — a full reload
  /// when the first page failed, an append when a later page failed.
  Future<void> retry() {
    final offset = _failedOffset ?? 0;
    return _load(offset: offset, initial: offset == 0);
  }

  /// Drops the loaded rows and refetches from the start (reconnect / WS
  /// `database`+`update` invalidation).
  Future<void> reload() {
    _gen++;
    _loadGen = null; // abandon any in-flight fetch of the old generation
    _items = const [];
    _total = 0;
    _hasLoaded = false;
    _failedOffset = null;
    _error = null;
    _notify();
    return loadFirst();
  }

  Future<void> _load({required int offset, required bool initial}) async {
    if (_loadGen != null) return;
    final gen = _gen;
    _loadGen = gen;
    _started = true;
    _failedOffset = null;
    _error = null;
    _notify();
    try {
      final page = await _fetch(offset, _pageSize);
      if (gen != _gen) return; // stale — a reload invalidated this load
      _total = page.total;
      if (initial) {
        _items = _dedupe(page.items);
        _hasLoaded = true;
      } else {
        _items = [..._items, ..._dedupe(page.items, existing: _items)];
        // A server that reports more in [Paging.total] than it actually
        // serves must not loop the load-more.
        if (page.items.isEmpty) _total = _items.length;
      }
    } catch (e) {
      if (gen != _gen) return;
      _failedOffset = offset;
      _error = describePagedFetchError(e);
    } finally {
      if (_loadGen == gen) _loadGen = null;
      if (gen == _gen) _notify();
    }
  }

  /// Load-more must never duplicate a row the server re-served (a library
  /// shift mid-browse).
  List<T> _dedupe(List<T> incoming, {List<T> existing = const []}) {
    final seen = <String>{for (final i in existing) _keyOf(i)};
    return [
      for (final i in incoming)
        if (seen.add(_keyOf(i))) i,
    ];
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _gen++;
    _disposed = true;
    super.dispose();
  }
}

/// A readable, typed message for a failed fetch (the error-state text) —
/// same shape as the controllers' action errors.
String describePagedFetchError(Object e) {
  if (e is DioException) {
    final status = e.response?.statusCode;
    if (status != null) {
      return 'Server answered HTTP $status.';
    }
    return 'Could not reach the server.';
  }
  return '$e';
}
