import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/library/library_models.dart';
import 'package:owntone_remote/src/library/paged_list.dart';

/// A scriptable paged source for [PagedList] (unit 005a C2/C3): records the
/// offsets fetched, can fail one offset, and can gate a response behind a
/// completer (stale-response test).
class FakeSource<T> {
  FakeSource(this.all) : totalOverride = all.length;

  final List<T> all;

  /// Mutable so a test can simulate a library change mid-browse.
  int totalOverride;
  final List<int> offsets = [];
  int failAtOffset = -1;
  Completer<void>? gate;

  Future<Paging<T>> fetch(int offset, int limit) async {
    offsets.add(offset);
    // Snapshot before the gate so a gated response keeps the old data.
    final items = offset < all.length
        ? all.sublist(offset, min(offset + limit, all.length))
        : <T>[];
    if (gate != null && !gate!.isCompleted) await gate!.future;
    if (offset == failAtOffset) {
      final opts = RequestOptions(path: '/lib');
      throw DioException(
        requestOptions: opts,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: opts, statusCode: 500),
      );
    }
    return Paging(
      items: items,
      total: totalOverride,
      offset: offset,
      limit: limit,
    );
  }
}

/// R-10 (unit 005a C2): pagination math — offsets, totals, no duplication,
/// failure + retry, stale-response safety.
void main() {
  List<String> names(int n, [String prefix = 'a']) => [
    for (var i = 0; i < n; i++) '$prefix$i',
  ];

  group('pagination', () {
    test('first load: page 1 at offset 0, total, hasLoaded', () async {
      final source = FakeSource(names(120));
      final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
      await list.loadFirst();
      expect(source.offsets, [0]);
      expect(list.items, hasLength(50));
      expect(list.total, 120);
      expect(list.hasLoaded, isTrue);
      expect(list.error, isNull);
    });

    test('loadNext: appends at offset = items.length (C2)', () async {
      final source = FakeSource(names(120));
      final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
      await list.loadFirst();
      await list.loadNext();
      expect(source.offsets, [0, 50]);
      expect(list.items, hasLength(100));
      expect(list.items.map((s) => s).toSet(), hasLength(100));
      expect(list.items[50], 'a50');
    });

    test('exhausted at total: loadNext is a no-op', () async {
      final source = FakeSource(names(50));
      final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
      await list.loadFirst();
      expect(list.exhausted, isTrue);
      await list.loadNext();
      expect(source.offsets, [0]);
      expect(list.items, hasLength(50));
    });

    test('full walk of 120 items: three pages, then exhausted', () async {
      final source = FakeSource(names(120));
      final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
      await list.loadFirst();
      await list.loadNext();
      await list.loadNext();
      await list.loadNext(); // no-op
      expect(source.offsets, [0, 50, 100]);
      expect(list.items, hasLength(120));
      expect(list.exhausted, isTrue);
      expect(list.items.map((s) => s).toSet(), hasLength(120));
    });

    test('custom page size', () async {
      final source = FakeSource(names(10));
      final list = PagedList<String>(
        fetch: source.fetch,
        keyOf: (s) => s,
        pageSize: 3,
      );
      await list.loadFirst();
      await list.loadNext();
      expect(source.offsets, [0, 3]);
      expect(list.items, hasLength(6));
    });

    test('a second loadNext while one is in flight is ignored', () async {
      final source = FakeSource(names(120));
      final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
      await list.loadFirst();
      source.gate = Completer<void>();
      final first = list.loadNext();
      final second = list.loadNext();
      source.gate!.complete();
      await first;
      await second;
      expect(source.offsets, [0, 50], reason: 'exactly one append fetch');
      expect(list.items, hasLength(100));
    });

    test('a server shift mid-browse never duplicates rows (C2)', () async {
      final source = FakeSource(names(120));
      final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
      await list.loadFirst(); // a0..a49
      source.all.insert(0, 'NEW'); // the library shifted: a49 moved into
      source.totalOverride = 121; // page 2's range
      await list.loadNext(); // offset 50 → a49..a98 (a49 already loaded)
      expect(list.items.map((s) => s).toSet(), hasLength(list.items.length));
      expect(list.items, hasLength(99), reason: 'a49 deduped, rest appended');
      expect(
        list.items.where((s) => s == 'a49'),
        hasLength(1),
        reason: 'no duplicate',
      );
      expect(list.items.last, 'a98');
    });

    test('stale total: an empty page stops the load-more loop', () async {
      final source = FakeSource(names(50));
      source.totalOverride = 120; // the server over-reports
      final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
      await list.loadFirst();
      expect(list.exhausted, isFalse);
      await list.loadNext(); // empty page
      expect(source.offsets, [0, 50]);
      expect(list.exhausted, isTrue, reason: 'total clamped to what arrived');
      await list.loadNext();
      expect(source.offsets, [0, 50], reason: 'no third fetch');
    });
  });

  group('failure + retry (C3 error state)', () {
    test('first-page failure: typed error, retry loads from scratch', () async {
      final source = FakeSource(names(120));
      source.failAtOffset = 0;
      final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
      await list.loadFirst();
      expect(list.items, isEmpty);
      expect(list.hasLoaded, isFalse);
      expect(list.failedOffset, 0);
      expect(list.error, 'Server answered HTTP 500.');

      source.failAtOffset = -1;
      await list.retry();
      expect(list.items, hasLength(50));
      expect(list.error, isNull);
      expect(list.hasLoaded, isTrue);
    });

    test(
      'later-page failure: rows kept, retry resumes at the failed offset',
      () async {
        final source = FakeSource(names(120));
        final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
        await list.loadFirst();
        source.failAtOffset = 50;
        await list.loadNext();
        expect(list.items, hasLength(50), reason: 'loaded rows stay');
        expect(list.failedOffset, 50);
        expect(list.error, 'Server answered HTTP 500.');

        source.failAtOffset = -1;
        await list.retry();
        expect(source.offsets, [0, 50, 50]);
        expect(list.items, hasLength(100));
        expect(list.error, isNull);
      },
    );

    test('retry before any load behaves as the first load', () async {
      final source = FakeSource(names(120));
      final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
      await list.retry();
      expect(source.offsets, [0]);
      expect(list.items, hasLength(50));
    });
  });

  group('stale responses', () {
    test('reload drops an in-flight first page from the old data', () async {
      final source = FakeSource(names(120));
      source.gate = Completer<void>();
      final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
      final first = list.loadFirst(); // in flight, holding the old snapshot
      // The library changes while the first page is still in flight.
      source.all
        ..clear()
        ..addAll(names(10, 'b'));
      source.totalOverride = 10;
      final second = list.reload();
      source.gate!.complete(); // both fetches may resolve now
      await second;
      expect(list.items, names(10, 'b'));

      await first; // the stale first page settles — it must be dropped
      expect(
        list.items,
        names(10, 'b'),
        reason: 'the stale generation cannot overwrite the fresh slice',
      );
    });

    test(
      'a fetch that fails across a reload does not surface its error',
      () async {
        final source = FakeSource(names(120));
        source.gate = Completer<void>();
        source.failAtOffset = 0;
        final list = PagedList<String>(fetch: source.fetch, keyOf: (s) => s);
        final first = list.loadFirst();
        source.gate!.complete();
        // The first page fails, but a reload already superseded it.
        source.failAtOffset = -1;
        source.all
          ..clear()
          ..addAll(names(10, 'b'));
        source.totalOverride = 10;
        final second = list.reload();
        await first; // fails (offset 0), stale generation
        await second;
        expect(list.error, isNull, reason: 'stale failure is dropped');
        expect(list.items, names(10, 'b'));
      },
    );
  });

  group('describePagedFetchError', () {
    DioException dio500(String path) => DioException(
      requestOptions: RequestOptions(path: path),
      type: DioExceptionType.badResponse,
      response: Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 500,
      ),
    );

    test('typed messages (same shape as the controllers)', () {
      expect(
        describePagedFetchError(dio500('/x')),
        'Server answered HTTP 500.',
      );
      expect(
        describePagedFetchError(
          DioException(
            requestOptions: RequestOptions(path: '/x'),
            type: DioExceptionType.connectionError,
          ),
        ),
        'Could not reach the server.',
      );
      expect(describePagedFetchError('boom'), 'boom');
    });
  });
}
