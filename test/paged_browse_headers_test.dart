import 'dart:math' show min;
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/library/library_models.dart';
import 'package:owntone_remote/src/library/paged_list.dart';
import 'package:owntone_remote/src/ui/paged_browse_list.dart';

/// R-25 (issue #48, N-05): alphabetical section headers in the loaded
/// branch of [PagedBrowseList] — ReTune's `basic_header` pattern
/// (`docs/retune-capture/10-genres/`), computed client-side per loaded
/// page, exactly once across page boundaries and reloads.

class FakeSource<T> {
  FakeSource(this.all);

  final List<T> all;
  final List<int> offsets = [];

  Future<Paging<T>> fetch(int offset, int limit) async {
    offsets.add(offset);
    return Paging(
      items: offset < all.length
          ? all.sublist(offset, min(offset + limit, all.length))
          : <T>[],
      total: all.length,
      offset: offset,
      limit: limit,
    );
  }
}

Future<PagedList<String>> pumpBrowse(
  WidgetTester tester,
  List<String> all, {
  String Function(String item)? groupKeyOf,
  int pageSize = 2,
}) async {
  final source = FakeSource<String>(all);
  final list = PagedList<String>(
    fetch: source.fetch,
    keyOf: (s) => s,
    pageSize: pageSize,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PagedBrowseList<String>(
          list: list,
          enabled: true,
          groupKeyOf: groupKeyOf,
          emptyMessage: 'Nothing here.',
          what: 'items',
          itemBuilder: (context, i, item) => Text(item),
        ),
      ),
    ),
  );
  await list.loadFirst();
  await tester.pump();
  return list;
}

SemanticsFinder headers() => find.semantics.byFlag(SemanticsFlag.isHeader);

void main() {
  String identityKey(String item) => item;

  group('R-25 header rendering', () {
    testWidgets('page [Ann, Bob] renders headers A and B exactly once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpBrowse(tester, ['Ann', 'Bob'], groupKeyOf: identityKey);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(headers(), findsNWidgets(2));
      handle.dispose();
    });

    testWidgets('next page [Cid] adds the B->C transition exactly once', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final list = await pumpBrowse(tester, [
        'Ann',
        'Bob',
        'Cid',
      ], groupKeyOf: identityKey);
      await list.loadNext();
      await tester.pump();
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      expect(headers(), findsNWidgets(3));
      handle.dispose();
    });

    testWidgets('page continuing the open group emits no duplicate header', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      // Boundary in the other direction: the new page starts inside B.
      final list = await pumpBrowse(tester, [
        'Ann',
        'Bob',
        'Brenda',
      ], groupKeyOf: identityKey);
      await list.loadNext();
      await tester.pump();
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(headers(), findsNWidgets(2));
      handle.dispose();
    });

    testWidgets('reload re-renders headers identically (no duplicates)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final list = await pumpBrowse(tester, [
        'Ann',
        'Bob',
        'Cid',
      ], groupKeyOf: identityKey);
      await list.loadNext();
      await tester.pump();
      expect(headers(), findsNWidgets(3));
      await list.reload();
      await tester.pump();
      await list.loadNext();
      await tester.pump();
      expect(find.text('Ann'), findsOneWidget);
      expect(find.text('Cid'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      expect(headers(), findsNWidgets(3));
      handle.dispose();
    });

    testWidgets('digits and symbols collapse to a single # header', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      // Server order (name_sort puts symbols/digits before letters).
      final list = await pumpBrowse(tester, [
        '311',
        '&Co',
        'Ann',
      ], groupKeyOf: identityKey);
      await list.loadNext();
      await tester.pump();
      expect(find.text('#'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(headers(), findsNWidgets(2));
      handle.dispose();
    });

    testWidgets('groupKeyOf null keeps the plain list (no headers)', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpBrowse(tester, ['Ann', 'Bob']);
      expect(headers(), findsNothing);
      expect(find.text('Ann'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('empty state unchanged — no headers', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBrowse(tester, const <String>[], groupKeyOf: identityKey);
      expect(find.text('Nothing here.'), findsOneWidget);
      expect(headers(), findsNothing);
      handle.dispose();
    });
  });

  group('R-25 header semantics and input', () {
    testWidgets('header is a semantics heading, not a control: header flag, '
        'label kept, no tap action, not focusable', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBrowse(tester, ['Ann', 'Bob'], groupKeyOf: identityKey);
      final data = tester.getSemantics(find.text('A')).getSemanticsData();
      expect(data.flagsCollection.isHeader, isTrue);
      expect(data.label, contains('A'));
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      expect(data.flagsCollection.isFocused, Tristate.none);
      handle.dispose();
    });

    testWidgets('tapping a header does nothing', (tester) async {
      await pumpBrowse(tester, ['Ann', 'Bob'], groupKeyOf: identityKey);
      await tester.tap(find.text('A'), warnIfMissed: false);
      await tester.pump();
      expect(tester.takeException(), isNull);
      // Same rows, same headers — the tap had no effect.
      expect(find.text('Ann'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    });
  });

  group('R-25 browseSectionKey derivation', () {
    test('first character, uppercased', () {
      expect(browseSectionKey('ann'), 'A');
      expect(browseSectionKey('Bob'), 'B');
      expect(browseSectionKey('  cedar'), 'C');
    });

    test('digits, symbols and empty fold to #', () {
      expect(browseSectionKey('311'), '#');
      expect(browseSectionKey('&Co'), '#');
      expect(browseSectionKey("'N Sync"), '#');
      expect(browseSectionKey(''), '#');
      expect(browseSectionKey('   '), '#');
    });

    test('groups by the server sort key (name_sort) — verified live '
        '2026-11-20: "Daniela Andrade" is ordered as "Andrade, Daniela"', () {
      const artist = Artist(
        id: '1',
        name: 'Daniela Andrade',
        albumCount: 1,
        trackCount: 3,
        lengthMs: 1000,
        nameSort: 'Andrade, Daniela',
      );
      expect(browseSectionKey(artist.sortName), 'A');
      // Without name_sort the model falls back to the display name.
      const bare = Artist(
        id: '2',
        name: 'Zappa',
        albumCount: 0,
        trackCount: 0,
        lengthMs: 0,
      );
      expect(browseSectionKey(bare.sortName), 'Z');
    });
  });
}
