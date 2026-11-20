import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owntone_remote/src/api/backoff.dart';
import 'package:owntone_remote/src/api/ws_client.dart';
import 'package:owntone_remote/src/connection/connection_controller.dart';
import 'package:owntone_remote/src/core/server_config.dart';
import 'package:owntone_remote/src/outputs/outputs_controller.dart';
import 'package:owntone_remote/src/player/player_controller.dart';
import 'package:owntone_remote/src/queue/queue_controller.dart';
import 'package:owntone_remote/src/rating/rating_controller.dart';
import 'package:owntone_remote/src/settings/settings_store.dart';
import 'package:owntone_remote/src/ui/now_playing_screen.dart';
import 'package:owntone_remote/src/ui/queue_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/fake_owntone_server.dart';
import 'fakes/fake_ws_channel.dart';

/// R-11 (unit 005b C2): the queue screen against fakes — server-order rows,
/// the now-playing highlight (the live-verified `item_id` = entry-`id`
/// match), clear (optimistic + rollback), WS `queue` refresh, offline
/// behaviour, and the play action's single add call.
void main() {
  late Fixture fx;
  late ScriptedAdapter adapter;
  late List<FakeWsChannel> channels;
  late ConnectionController conn;
  late PlayerController player;
  late OutputsController outputs;
  late QueueController queue;
  late RatingController rating;
  late SettingsStore store;

  const cfg = ServerConfig(host: '10.0.0.5', port: 3689);

  /// [configure] runs before the connection is made, so controllers' first
  /// fetches already see the configured fixture state.
  Future<void> wireUp({void Function(Fixture)? configure}) async {
    SharedPreferences.setMockInitialValues({});
    fx = Fixture();
    configure?.call(fx);
    adapter = ScriptedAdapter(responder: fx.handle);
    channels = [];
    conn = ConnectionController(
      dioFactory: (options) => Dio(options)..httpClientAdapter = adapter,
      wsFactory: (uri, subscriptions, backoff) => WsClient(
        uri: uri,
        subscriptions: subscriptions,
        backoff: Backoff(
          initial: const Duration(milliseconds: 5),
          maximum: const Duration(milliseconds: 20),
        ),
        channelFactory: (u) {
          final c = FakeWsChannel();
          channels.add(c);
          if (fx.serverDown) c.handshakeFails = true;
          return c;
        },
      ),
    );
    player = PlayerController(connection: conn);
    await player.init();
    outputs = OutputsController(connection: conn);
    await outputs.init();
    queue = QueueController(connection: conn);
    await queue.init();
    rating = RatingController(connection: conn, player: player);
    await rating.init();
    store = SettingsStore(await SharedPreferences.getInstance());
    await conn.connectTo(cfg);
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  Future<void> pumpScreen(WidgetTester tester, Widget screen) =>
      tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<SettingsStore>.value(value: store),
            ChangeNotifierProvider<ConnectionController>.value(value: conn),
            ChangeNotifierProvider<PlayerController>.value(value: player),
            ChangeNotifierProvider<OutputsController>.value(value: outputs),
            ChangeNotifierProvider<QueueController>.value(value: queue),
            ChangeNotifierProvider<RatingController>.value(value: rating),
            ChangeNotifierProvider<RatingController>.value(value: rating),
          ],
          child: MaterialApp(home: screen),
        ),
      );

  /// Lets the (fake) network futures complete, then renders frames.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  tearDown(() {
    rating.dispose();
    queue.dispose();
    outputs.dispose();
    player.dispose();
    conn.dispose();
  });

  /// Rows are asserted through their compound semantics label
  /// (`<title>[, now playing][, artist · album]` — no numbers in rows,
  /// user call 2026-10-26) — via the Semantics widget itself:
  /// `bySemanticsLabel` needs the semantics tree, which plain widget tests
  /// do not enable.
  Finder row(String title, {bool nowPlaying = false}) {
    final label =
        '$title'
        '${nowPlaying ? ', now playing' : ''}, Muse · Absolution';
    return find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == label,
    );
  }

  Finder nowPlayingRows() => find.byWidgetPredicate(
    (w) =>
        w is Semantics && w.properties.label?.contains('now playing') == true,
  );

  group('R-11 rendering + highlight', () {
    testWidgets('rows in server order; the item_id row is highlighted', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      // Server order, with title + artist · album + length.
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.text('Muse · Absolution'), findsWidgets);
      expect(find.text('Blues in the Attic'), findsOneWidget);
      expect(find.text('House Party'), findsOneWidget);

      // The highlight: item_id 196174 = the first entry's id.
      expect(row('Skunk', nowPlaying: true), findsOneWidget);
      expect(row('Blues in the Attic'), findsOneWidget);
      expect(row('Blues in the Attic', nowPlaying: true), findsNothing);
      // The highlighted row carries the play icon, the others numbers.
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('highlight follows item_id — not track_id (live-verified)', (
      tester,
    ) async {
      // item_id = a track_id no entry id holds: no highlight.
      await tester.runAsync(() => wireUp(configure: (f) => f.itemId = 1195));
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(nowPlayingRows(), findsNothing);

      // item_id = the second entry's id: that row highlights.
      fx.itemId = 196175;
      await tester.runAsync(() => player.refreshState());
      await settle(tester);
      expect(row('Blues in the Attic', nowPlaying: true), findsOneWidget);
      expect(row('Skunk', nowPlaying: true), findsNothing);
    });

    testWidgets('stopped server (no item_id): no highlight', (tester) async {
      await tester.runAsync(() => wireUp(configure: (f) => f.itemId = null));
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(nowPlayingRows(), findsNothing);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
    });

    testWidgets('empty queue: icon + message', (tester) async {
      await tester.runAsync(() => wireUp(configure: (f) => f.items.clear()));
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(find.text('The queue is empty.'), findsOneWidget);
    });

    testWidgets('first-fetch failure: error state + retry recovers', (
      tester,
    ) async {
      await tester.runAsync(
        () => wireUp(configure: (f) => f.failQueueGet = true),
      );
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(find.text('Could not load the queue.'), findsOneWidget);

      fx.failQueueGet = false;
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(find.text('Skunk'), findsOneWidget);
    });
  });

  group('R-11 clear', () {
    testWidgets('confirm → optimistic empty, one PUT /api/queue/clear', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      await tester.tap(find.byTooltip('Clear queue'));
      await tester.pump();
      expect(find.text('Clear the queue?'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      await settle(tester);
      expect(adapter.requests, contains('PUT /api/queue/clear'));
      expect(find.text('The queue is empty.'), findsOneWidget);
      expect(find.text('Skunk'), findsNothing);
    });

    testWidgets('cancel keeps the rows and sends nothing', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      await tester.tap(find.byTooltip('Clear queue'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      expect(find.text('Skunk'), findsOneWidget);
      expect(adapter.requests.where((r) => r.contains('clear')), isEmpty);
    });

    testWidgets('failed clear: rollback + snackbar', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      fx.failClear = true;

      await tester.tap(find.byTooltip('Clear queue'));
      await tester.pump();
      await tester.tap(find.text('Clear'));
      await settle(tester);

      // The rows came back (rollback) and the typed error is shown.
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.textContaining('Clear queue failed'), findsOneWidget);
    });
  });

  // Issue #23 (OwnTone web-UI parity): "remove from queue after playback"
  // is a PURE visibility toggle — hide everything before the now-playing
  // entry, zero queue mutation of any kind (no API call, no optimistic
  // removal), and the cut re-anchors when a WS event moves the current
  // track. R-11 is the queue requirement (docs/REQUIREMENTS.md; the issue's
  // "R-05 area" label follows the #19/#24 misnumbering precedent).
  group('R-11 hide items played earlier (pure visibility, issue #23)', () {
    // The cut only shows with a row BEFORE the current one: anchor on the
    // middle entry (id 196175 = 'Blues in the Attic').
    Future<void> pumpWithMiddleCurrent(WidgetTester tester) async {
      await tester.runAsync(() => wireUp(configure: (f) => f.itemId = 196175));
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.text('Blues in the Attic'), findsOneWidget);
      expect(find.text('House Party'), findsOneWidget);
    }

    testWidgets('toggle on hides rows before the current index (a)', (
      tester,
    ) async {
      await pumpWithMiddleCurrent(tester);
      final before = List.of(adapter.requests);

      await tester.tap(find.byTooltip('Hide items played earlier'));
      await settle(tester);

      // Cut anchored on the current row: everything before it is gone,
      // the current row (still highlighted) and everything after stay.
      expect(row('Skunk'), findsNothing);
      expect(find.text('Skunk'), findsNothing);
      expect(row('Blues in the Attic', nowPlaying: true), findsOneWidget);
      expect(row('House Party'), findsOneWidget);
      // The control flipped (tooltip/icon reflect state).
      expect(find.byTooltip('Show items played earlier'), findsOneWidget);
      // (b) PURE: the toggle fired NOTHING at the server — not a mutation,
      // not even a refetch (mutation-verified: any removal/refetch call on
      // the toggle path reddens this).
      expect(
        adapter.requests,
        before,
        reason: 'the hide toggle must be a pure view filter — zero requests',
      );
    });

    testWidgets('toggle off restores the hidden rows, still zero calls (c)', (
      tester,
    ) async {
      await pumpWithMiddleCurrent(tester);
      final before = List.of(adapter.requests);

      await tester.tap(find.byTooltip('Hide items played earlier'));
      await settle(tester);
      expect(find.text('Skunk'), findsNothing);

      await tester.tap(find.byTooltip('Show items played earlier'));
      await settle(tester);

      expect(row('Skunk'), findsOneWidget);
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.byTooltip('Hide items played earlier'), findsOneWidget);
      expect(
        adapter.requests,
        before,
        reason: 'toggle on AND off must leave the request log untouched',
      );
      expect(
        adapter.requests.where(
          (r) =>
              r.contains('/api/queue/clear') ||
              r.contains('/items/add') ||
              r.startsWith('DELETE') ||
              r.contains('remove'),
        ),
        isEmpty,
        reason: 'zero queue-mutating requests (issue #23 fix-unit note)',
      );
    });

    testWidgets('a WS queue/player event re-anchors the cut (d)', (
      tester,
    ) async {
      await pumpWithMiddleCurrent(tester);

      await tester.tap(find.byTooltip('Hide items played earlier'));
      await settle(tester);
      expect(find.text('Skunk'), findsNothing);
      expect(find.text('Blues in the Attic'), findsOneWidget);

      // The current track advances (any client — web UI included): a
      // `queue`-carrying WS event must re-anchor the cut at the NEW index,
      // not keep the one captured when the toggle was pressed.
      await tester.runAsync(() async {
        fx.itemId = 196176;
        channels.last.serverSend('{"notify":["queue","player"]}');
      });
      await settle(tester);

      expect(find.text('Skunk'), findsNothing);
      expect(
        find.text('Blues in the Attic'),
        findsNothing,
        reason:
            'the cut stayed on the old anchor — it must follow the '
            'current track (issue #23)',
      );
      expect(row('House Party', nowPlaying: true), findsOneWidget);

      // And back to the first entry (cut index 0) → everything is visible.
      await tester.runAsync(() async {
        fx.itemId = 196174;
        channels.last.serverSend('{"notify":["queue","player"]}');
      });
      await settle(tester);
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.text('Blues in the Attic'), findsOneWidget);
      expect(find.text('House Party'), findsOneWidget);
    });

    testWidgets('unanchorable cut (no current item) shows everything', (
      tester,
    ) async {
      await tester.runAsync(() => wireUp(configure: (f) => f.itemId = null));
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      await tester.tap(find.byTooltip('Hide items played earlier'));
      await settle(tester);
      // Stopped / no item_id: no anchor → hiding would be a guess, so all
      // rows stay (the server queue is untouched either way).
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.text('Blues in the Attic'), findsOneWidget);
      expect(find.text('House Party'), findsOneWidget);
    });

    testWidgets('toggle state lives on the controller (survives the screen)', (
      tester,
    ) async {
      await pumpWithMiddleCurrent(tester);
      await tester.tap(find.byTooltip('Hide items played earlier'));
      await settle(tester);
      expect(queue.hidePlayedItems, isTrue);
      expect(find.text('Skunk'), findsNothing);

      // Leave and re-enter the screen (the controller outlives the widget):
      // the session toggle persists; a widget-local bool would reset.
      await pumpScreen(tester, const NowPlayingScreen());
      await settle(tester);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(find.text('Skunk'), findsNothing);
      expect(find.text('House Party'), findsOneWidget);
    });
  });

  // Issue #21 (OwnTone web-UI parity): tapping a queued row advances the
  // queue IN PLACE — the item becomes the current track, the queue content
  // is untouched. The web UI's own row click is `PUT
  /// /api/player/play?item_id=<entry id>` (read from the served webplayer
  /// JS on 2026-11-19); the old add-with-clear+playback=start handler is
  /// the defect: it REPLACED the queue. R-11 is the queue requirement (the
  /// issue's "R-05 area" label follows the #19/#23/#24 misnumbering
  /// precedent).
  group('R-11 tap advances the queue in place (issue #21)', () {
    testWidgets('row tap → the skip call for that entry id, and NOTHING '
        'else mutating or transporting (a/b/c)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      final before = List.of(adapter.requests);

      await tester.tap(find.text('House Party'));
      await settle(tester);

      // (a) the skip call, keyed on the tapped entry's id (196176 = House
      // Party's queue-entry id, not its track_id 1193).
      final fired = adapter.requests.skip(before.length).toList();
      expect(
        fired,
        contains('PUT /api/player/play?item_id=196176'),
        reason: 'tap must fire the web-UI queue-skip (issue #21)',
      );
      // (b) ZERO queue-replacing calls: no add (with or without
      // clear/playback=start), no clear, no DELETE.
      expect(
        fired.where(
          (r) =>
              r.contains('/items/add') ||
              r.contains('/api/queue/clear') ||
              r.startsWith('DELETE'),
        ),
        isEmpty,
        reason:
            'the defect was the queue-replacing add call (issue #21) — '
            'an in-place advance must never fire one',
      );
      // (c) no transport calls: the only player-endpoint request is the
      // skip itself — no bare play/toggle, no next/previous/pause/stop.
      expect(fired.where((r) => r.contains('/api/player/')).toSet(), {
        'PUT /api/player/play?item_id=196176',
      }, reason: 'the handler must issue no play/toggle/next/previous call');
      // The rows stay (the fixture serves the untouched 3-item queue).
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.text('Blues in the Attic'), findsOneWidget);
      expect(find.text('House Party'), findsOneWidget);
    });

    testWidgets('after the skip lands, the current marker moves to the '
        'tapped row — queue content and order unchanged', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(row('Skunk', nowPlaying: true), findsOneWidget);

      await tester.tap(find.text('House Party'));
      await settle(tester);
      // The fixture flipped item_id on the skip call; the server's
      // player+queue events drive the UI (mirrored with a WS push, the
      // #23 pattern).
      await tester.runAsync(() async {
        channels.last.serverSend('{"notify":["player","queue"]}');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await settle(tester);

      // (a) the marker moved: the tapped row is now the now-playing one…
      expect(row('House Party', nowPlaying: true), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      // (b) …and the queue is UNCHANGED: same three rows, same order.
      expect(row('Skunk', nowPlaying: true), findsNothing);
      final titles = [
        'Skunk',
        'Blues in the Attic',
        'House Party',
      ].map((t) => find.text(t));
      for (final t in titles) {
        expect(t, findsOneWidget, reason: 'queue content must be unchanged');
      }
      expect(
        adapter.requests.where((r) => r.contains('/items/add')),
        isEmpty,
        reason: 'no re-add of any kind (issue #21)',
      );
    });

    testWidgets('failed skip: snackbar, rows unchanged, marker unmoved', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      fx.failSkip = true;

      await tester.tap(find.text('House Party'));
      await settle(tester);
      expect(find.textContaining('Skip to track failed'), findsOneWidget);
      expect(row('House Party', nowPlaying: true), findsNothing);
      expect(row('Skunk', nowPlaying: true), findsOneWidget);
      expect(find.text('House Party'), findsOneWidget);
    });
  });

  // Issue #46 (R-23): tap-and-hold drag reorder. The pure drop→position
  // mapping has its own unit tests (queue_move_test.dart); these drive
  // REAL long-press drags through ReorderableListView (Flutter 3.47.9:
  // `ReorderableDelayedDragStartListener` = the ReTune "tap and hold"
  // gesture, `onReorderItem` = already-adjusted indices) against the fake
  // API, asserting the captured PUT line and the now-playing-row inertness.
  group('R-23 drag reorder (issue #46)', () {
    Finder handle(String title) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == 'Reorder $title',
    );

    /// Titles currently on screen, top to bottom.
    List<String> rowOrder(WidgetTester tester) {
      const known = ['Skunk', 'Blues in the Attic', 'House Party', 'Mid Drag'];
      final located = <String, double>{};
      for (final t in known) {
        final f = find.text(t);
        if (f.evaluate().isNotEmpty) located[t] = tester.getCenter(f).dy;
      }
      final sorted = located.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      return [for (final e in sorted) e.key];
    }

    /// Long-press the drag handle (ReorderableDelayedDragStartListener
    /// starts the drag after the long-press timeout — hold past it without
    /// moving), then move in 4 steps and release.
    Future<void> dragFromHandleTo(
      WidgetTester tester,
      String title,
      Offset target,
    ) async {
      final start = tester.getCenter(handle(title));
      final g = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 600));
      for (var i = 1; i <= 4; i++) {
        await g.moveTo(Offset.lerp(start, target, i / 4)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
    }

    testWidgets('moveItem (controller): optimistic reorder, exactly one '
        'mapped PUT new_position=2, then the GET /api/queue trailing '
        'refresh — the _action pattern verbatim, no second refresh path', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      final before = adapter.requests.length;
      final blues = queue.queue.firstWhere(
        (e) => e.title == 'Blues in the Attic',
      );
      late bool ok;
      await tester.runAsync(() async {
        ok = await queue.moveItem(blues, 2);
      });
      await settle(tester);
      expect(ok, isTrue);
      final fired = adapter.requests.skip(before).toList();
      expect(fired.where((r) => r.contains('/api/queue/items/')), [
        'PUT /api/queue/items/196175?new_position=2',
      ], reason: 'exactly ONE move with the server-absolute index (R-23)');
      expect(
        fired,
        contains('GET /api/queue'),
        reason: 'trailing post-commit refresh (unit-011)',
      );
      expect(queue.queue.map((e) => e.title), [
        'Skunk',
        'House Party',
        'Blues in the Attic',
      ]);
    });

    testWidgets('moveItem failure (fake 500): pre-action list restored + '
        'typed _describeActionError (the clear-proven _action contract)', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      fx.failMove = true;
      final blues = queue.queue.firstWhere(
        (e) => e.title == 'Blues in the Attic',
      );
      late bool ok;
      await tester.runAsync(() async {
        ok = await queue.moveItem(blues, 2);
      });
      expect(ok, isFalse);
      expect(
        queue.actionError,
        contains('Move failed — server answered HTTP 500.'),
      );
      expect(queue.queue.map((e) => e.title), [
        'Skunk',
        'Blues in the Attic',
        'House Party',
      ], reason: 'rollback to the pre-action list');
    });

    testWidgets('real drag (Blues below House): exactly ONE PUT with the '
        'mapped new_position=2 — no other mutating call — and the rows '
        'land the moved order', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(rowOrder(tester), ['Skunk', 'Blues in the Attic', 'House Party']);
      final before = adapter.requests.length;
      final target = Offset(
        tester.getCenter(handle('Blues in the Attic')).dx,
        tester.getRect(find.text('House Party')).bottom + 12,
      );

      await dragFromHandleTo(tester, 'Blues in the Attic', target);
      await settle(tester);

      final fired = adapter.requests.skip(before).toList();
      expect(fired.where((r) => r.contains('/api/queue/items/')), [
        'PUT /api/queue/items/196175?new_position=2',
      ], reason: 'one drop commits exactly one PUT, server-absolute (R-23)');
      expect(
        fired.where(
          (r) =>
              r.contains('/items/add') ||
              r.contains('/api/queue/clear') ||
              r.startsWith('DELETE') ||
              r.contains('/api/player/play'),
        ),
        isEmpty,
        reason: 'drag must not transport or replace anything',
      );
      expect(fired, contains('GET /api/queue'));
      expect(rowOrder(tester), ['Skunk', 'House Party', 'Blues in the Attic']);
    });

    testWidgets('hide-played ON: the drop maps THROUGH the cut — display 0 '
        '→ PUT new_position=1, never the raw display 0 (issue #23 window)', (
      tester,
    ) async {
      await tester.runAsync(() => wireUp(configure: (f) => f.itemId = 196175));
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      await tester.tap(find.byTooltip('Hide items played earlier'));
      await settle(tester);
      expect(rowOrder(tester), ['Blues in the Attic', 'House Party']);
      final before = adapter.requests.length;
      final target = Offset(
        tester.getCenter(handle('House Party')).dx,
        tester.getRect(find.text('Blues in the Attic')).top + 2,
      );

      await dragFromHandleTo(tester, 'House Party', target);
      await settle(tester);

      final fired = adapter.requests.skip(before).toList();
      expect(
        fired.where((r) => r.contains('/api/queue/items/')),
        ['PUT /api/queue/items/196176?new_position=1'],
        reason:
            'display 0 + cut 1 = absolute 1 — an unmapped index would '
            'send new_position=0 into the hidden already-played region',
      );
      expect(fired.where((r) => r.contains('new_position=0')), isEmpty);
    });

    testWidgets('the now-playing row is INERT: no handle at all, a '
        'long-press-drag across it fires NO queue PUT and NO skip — the '
        'current entry stays fixed (R-23 client rule; server behaviour '
        'deliberately unprobed on the shared fixture)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(
        handle('Skunk'),
        findsNothing,
        reason: 'the current row gets no drag handle (R-23)',
      );
      expect(handle('Blues in the Attic'), findsOneWidget);
      final before = List.of(adapter.requests);
      final house = tester.getRect(find.text('House Party'));
      final start = tester.getCenter(row('Skunk', nowPlaying: true));
      final g = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 600));
      for (var i = 1; i <= 4; i++) {
        await g.moveTo(
          Offset.lerp(start, Offset(start.dx, house.bottom + 12), i / 4)!,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await settle(tester);

      expect(
        adapter.requests
            .skip(before.length)
            .where((r) => r.contains('/api/queue/items/')),
        isEmpty,
        reason: 'no move request may fire from the current row',
      );
      expect(
        adapter.requests
            .skip(before.length)
            .where((r) => r.contains('PUT /api/player/play')),
        isEmpty,
        reason: 'and the hold-drag is not a tap either',
      );
      expect(rowOrder(tester), ['Skunk', 'Blues in the Attic', 'House Party']);
    });

    testWidgets('drag handles carry the "Reorder <title>" semantics label '
        "(ReTune's drag is a11y-invisible — R-23 does better)", (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(handle('Blues in the Attic'), findsOneWidget);
      expect(handle('House Party'), findsOneWidget);
      expect(handle('Skunk'), findsNothing);
    });

    testWidgets('WS queue event MID-DRAG: the drag keeps its local order, '
        'commits exactly one PUT, and the post-commit refresh lands the '
        'SERVER order (reconciliation contract)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      final before = adapter.requests.length;
      final start = tester.getCenter(handle('Blues in the Attic'));
      final g = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 600));

      // An external client (web UI) changes the queue while the finger is
      // held: the refetch rebuilds the list UNDER the live overlay.
      await tester.runAsync(() async {
        fx.items.insert(0, Fixture.track(200005, 0, 'Mid Drag', 1205, 330000));
        fx.renumber();
        channels.last.serverSend('{"notify":["queue"]}');
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await settle(tester);
      // R-23 mid-drag contract: the refetch must NOT yank the rows — the
      // list stays at the LOCAL (frozen) order while the finger is down
      // (the server's new row lands only after the post-commit refresh,
      // asserted at the end). Mutation-verified: a list that rebuilds
      // mid-drag shows 'Mid Drag' here (and trips Flutter's duplicate-
      // GlobalKey assertion under the overlay).
      expect(
        find.text('Mid Drag'),
        findsNothing,
        reason: 'the drag keeps its local order (R-23)',
      );

      final house = tester.getRect(find.text('House Party'));
      for (var i = 1; i <= 4; i++) {
        await g.moveTo(
          Offset.lerp(start, Offset(start.dx, house.bottom + 12), i / 4)!,
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      for (var k = 0; k < 6; k++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final fired = adapter.requests.skip(before).toList();
      expect(
        fired.where((r) => r.startsWith('PUT /api/queue/items/')),
        hasLength(1),
        reason:
            'the drag commits exactly ONE move (unit-011: no second '
            'refresh path — the trailing _action refresh reconciles)',
      );
      // Whatever index the mid-drag insert shifted the drop to, the truth
      // after commit is the server's: rows match GET /api/queue order.
      expect(rowOrder(tester), [
        for (final e in fx.items) e['title'],
      ], reason: 'post-commit refresh reconciles the list (R-23)');
    });

    testWidgets('failed drag (fake 500): rows roll back + typed snackbar', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      fx.failMove = true;
      final target = Offset(
        tester.getCenter(handle('Blues in the Attic')).dx,
        tester.getRect(find.text('House Party')).bottom + 12,
      );

      await dragFromHandleTo(tester, 'Blues in the Attic', target);
      await settle(tester);

      expect(
        adapter.requests.where((r) => r.startsWith('PUT /api/queue/items/')),
        hasLength(1),
      );
      expect(
        find.textContaining('Move failed'),
        findsOneWidget,
        reason: 'typed _describeActionError snackbar (R-23)',
      );
      expect(rowOrder(tester), [
        'Skunk',
        'Blues in the Attic',
        'House Party',
      ], reason: 'the pre-action list is restored');
    });
  });

  // Issue #47 (R-24): ReTune's per-row accessory popup (Play Next ·
  // Remove — 23-playing-audit A3, machine-verified with the player
  // paused). PopupMenuButton = the repo's M3 overflow precedent; the
  // now-playing row exposes NEITHER action (its block is gated on
  // !isNowPlaying). Captured-request assertions follow the #21/#41/
  // #46 pattern — the fake API records the exact request lines.
  group('R-24 per-row Remove + Play Next (issue #47)', () {
    Finder menu(String title) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == 'Queue options $title',
    );
    Finder menuItem(String label) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == label,
    );

    Future<void> openMenu(WidgetTester tester, String title) async {
      await tester.tap(menu(title));
      await tester.pumpAndSettle();
    }

    testWidgets('removeItem (controller): exactly one DELETE with the '
        'entry id + the GET /api/queue trailing refresh, optimistic '
        'splice, zero other mutating/transporting calls — the _action '
        'pattern verbatim (R-24)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      final before = adapter.requests.length;
      final house = queue.queue.firstWhere((e) => e.title == 'House Party');
      late bool ok;
      await tester.runAsync(() async {
        ok = await queue.removeItem(house);
      });
      await settle(tester);
      expect(ok, isTrue);
      final fired = adapter.requests.skip(before).toList();
      expect(
        fired.where((r) => r.startsWith('DELETE')),
        ['DELETE /api/queue/items/196176'],
        reason:
            'exact DELETE path + the tapped row\'s QUEUE-ENTRY id '
            '(docs/API.md:95), keyed on id not index (hide-cut safe)',
      );
      expect(
        fired,
        contains('GET /api/queue'),
        reason: 'trailing post-commit refresh (unit-011)',
      );
      expect(
        fired.where(
          (r) =>
              r.contains('/items/add') ||
              r.contains('/api/queue/clear') ||
              r.startsWith('PUT /api/player') ||
              r.contains('new_position'),
        ),
        isEmpty,
        reason: 'remove must transport nothing and touch nothing else',
      );
      expect(queue.queue.map((e) => e.title), ['Skunk', 'Blues in the Attic']);
    });

    testWidgets('removeItem failure (fake 500): pre-action list restored '
        '+ typed _describeActionError (R-24 — the clear-proven _action '
        'contract)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      fx.failRemove = true;
      final house = queue.queue.firstWhere((e) => e.title == 'House Party');
      late bool ok;
      await tester.runAsync(() async {
        ok = await queue.removeItem(house);
      });
      expect(ok, isFalse);
      expect(
        queue.actionError,
        contains('Remove failed — server answered HTTP 500.'),
      );
      expect(queue.queue.map((e) => e.title), [
        'Skunk',
        'Blues in the Attic',
        'House Party',
      ], reason: 'rollback to the pre-action list');
    });

    testWidgets('playNext (controller): ONE add WITHOUT clear/start with '
        'position=current+1=1 (Skunk is current at 0) + trailing GET '
        '(R-24)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      final before = adapter.requests.length;
      final house = queue.queue.firstWhere((e) => e.title == 'House Party');
      late bool ok;
      await tester.runAsync(() async {
        ok = await queue.playNext(
          house,
          position: queuePlayNextPosition(queue.queue, 196174),
        );
      });
      await settle(tester);
      expect(ok, isTrue);
      final fired = adapter.requests.skip(before).toList();
      expect(
        fired.where((r) => r.contains('/items/add')),
        [
          'POST /api/queue/items/add'
              '?uris=library%3Atrack%3A1193&playback=add&position=1',
        ],
        reason:
            'the row\'s OWN uri re-added at current+1 — the #41 '
            'addUris position variant, no duplicate add method (R-24)',
      );
      expect(
        fired.where((r) => r.contains('clear=true')),
        isEmpty,
        reason: 'a queue INSERT must never clear (the #21 defect class)',
      );
      expect(
        fired.where((r) => r.contains('playback=start')),
        isEmpty,
        reason: 'playback untouched — safe unattended while paused',
      );
      expect(
        fired.where((r) => r.startsWith('PUT /api/player/play')),
        isEmpty,
        reason: 'Play next is not a skip either (that stays row-tap-only)',
      );
      expect(fired, contains('GET /api/queue'));
    });

    testWidgets('row menu on every NON-now-playing row; the now-playing '
        'row exposes NEITHER action (no button at all) (R-24)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(menu('Blues in the Attic'), findsOneWidget);
      expect(menu('House Party'), findsOneWidget);
      expect(
        menu('Skunk'),
        findsNothing,
        reason:
            'Skunk is the now-playing row (item_id 196174) — R-24 '
            'excludes it from both actions',
      );
      expect(
        find.byTooltip('Queue options'),
        findsNWidgets(2),
        reason: 'exactly the two non-current rows carry the accessory',
      );
    });

    testWidgets('Remove via the menu: exactly the DELETE + trailing GET, '
        'the row vanishes, zero add/clear/player calls (R-24)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      final before = adapter.requests.length;

      await openMenu(tester, 'House Party');
      await tester.tap(find.text('Remove'));
      await settle(tester);

      final fired = adapter.requests.skip(before).toList();
      expect(fired.where((r) => r.startsWith('DELETE')), [
        'DELETE /api/queue/items/196176',
      ]);
      expect(
        fired.where(
          (r) =>
              r.contains('/items/add') ||
              r.contains('/api/queue/clear') ||
              r.startsWith('PUT /api/player'),
        ),
        isEmpty,
      );
      expect(find.text('House Party'), findsNothing, reason: 'row gone');
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.text('Blues in the Attic'), findsOneWidget);
    });

    testWidgets('Play next via the menu: exact add position=1 without '
        'clear=true/start, and the tapped row STAYS — insert-COPY, not '
        'move (R-24 chosen semantics)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      final before = adapter.requests.length;

      await openMenu(tester, 'House Party');
      await tester.tap(find.text('Play next'));
      await settle(tester);

      final fired = adapter.requests.skip(before).toList();
      expect(fired.where((r) => r.contains('/items/add')), [
        'POST /api/queue/items/add'
            '?uris=library%3Atrack%3A1193&playback=add&position=1',
      ]);
      expect(fired.where((r) => r.contains('clear=true')), isEmpty);
      expect(fired.where((r) => r.contains('playback=start')), isEmpty);
      expect(
        fired.where((r) => r.startsWith('DELETE')),
        isEmpty,
        reason:
            'insert-COPY (ReTune-safe default, orchestrator-frozen): '
            'a move would DELETE the original row too',
      );
      expect(fired, contains('GET /api/queue'));
      // The copy landed at 1 (fixture-inserted); the ORIGINAL row stays.
      expect(find.text('House Party'), findsOneWidget);
      expect(find.text('Added library:track:1193'), findsOneWidget);
    });

    testWidgets('failed remove (fake 500): rows roll back + typed '
        'snackbar (R-24)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      fx.failRemove = true;

      await openMenu(tester, 'House Party');
      await tester.tap(find.text('Remove'));
      await settle(tester);

      expect(
        find.textContaining('Remove failed'),
        findsOneWidget,
        reason: 'typed _describeActionError snackbar (R-24)',
      );
      expect(find.text('House Party'), findsOneWidget, reason: 'rollback');
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.text('Blues in the Attic'), findsOneWidget);
    });

    testWidgets('menu items carry tooltips AND semantics labels (R-24 — '
        "do better than ReTune's a11y-invisible CheckedTextView popup)", (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      await openMenu(tester, 'House Party');
      expect(find.byTooltip('Play next'), findsOneWidget);
      expect(find.byTooltip('Remove from queue'), findsOneWidget);
      expect(menuItem('Play next House Party'), findsOneWidget);
      expect(menuItem('Remove House Party from queue'), findsOneWidget);
    });

    testWidgets('row tap STILL fires the #21 skip-in-place and opens no '
        'popup — the accessory must not regress the tap (R-10/R-11, '
        'issue #21 non-regression)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      final before = adapter.requests.length;

      await tester.tap(find.text('House Party'));
      await settle(tester);

      final fired = adapter.requests.skip(before).toList();
      expect(
        fired,
        contains('PUT /api/player/play?item_id=196176'),
        reason: 'row body tap = skip in place (issue #21)',
      );
      expect(
        fired.where((r) => r.contains('/items/add') || r.startsWith('DELETE')),
        isEmpty,
      );
      expect(
        find.text('Play next'),
        findsNothing,
        reason: 'a body tap must NOT open the accessory popup',
      );
    });

    testWidgets('hide-played interplay (R-24 × issue #23): rows ABOVE the '
        'cut are unremovable (no menu rendered), and removing a visible '
        'row leaves the hidden region untouched', (tester) async {
      await tester.runAsync(() => wireUp(configure: (f) => f.itemId = 196175));
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      await tester.tap(find.byTooltip('Hide items played earlier'));
      await settle(tester);
      // Visible window [Blues (current), House Party]; Skunk is above the
      // cut — not rendered, hence no menu to reach either (the only way
      // "remove a row above the cut" could happen is an index bug; the
      // id-keyed DELETE makes that structurally impossible).
      expect(find.text('Skunk'), findsNothing);
      expect(menu('Skunk'), findsNothing);
      expect(menu('House Party'), findsOneWidget);
      final before = adapter.requests.length;

      await openMenu(tester, 'House Party');
      await tester.tap(find.text('Remove'));
      await settle(tester);

      final fired = adapter.requests.skip(before).toList();
      expect(
        fired.where((r) => r.startsWith('DELETE')),
        ['DELETE /api/queue/items/196176'],
        reason:
            'exactly the tapped row; the hidden row above the cut '
            'is untouched (no DELETE for id 196174 anywhere)',
      );
      expect(
        adapter.requests.where((r) => r.contains('196174')),
        isEmpty,
        reason: 'id-keyed delete can never reach the hidden region',
      );
      expect(find.text('House Party'), findsNothing);
      // Toggle back: the cut re-derives over the new full list — Skunk
      // (above the old cut) is STILL there; House Party is gone from the
      // underlying list, not just the window.
      await tester.tap(find.byTooltip('Show items played earlier'));
      await settle(tester);
      expect(find.text('Skunk'), findsOneWidget);
      expect(find.text('Blues in the Attic'), findsOneWidget);
      expect(find.text('House Party'), findsNothing);
    });
  });

  group('R-11 refresh (R-02)', () {
    testWidgets('WS queue event (external change) refetches', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(find.text('Skunk'), findsOneWidget);

      // An external client (web UI) adds a track → the server notifies.
      await tester.runAsync(() async {
        fx.items.insert(0, Fixture.track(200001, 0, 'New Track', 1201, 300000));
        fx.renumber();
        channels.last.serverSend('{"notify":["queue"]}');
      });
      await settle(tester);
      expect(find.text('New Track'), findsOneWidget);
    });

    testWidgets('reconnect refetches the queue', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      // The server drops and stays down (failed handshakes), so the
      // backoff retries keep the app in its offline window.
      await tester.runAsync(() async {
        fx.serverDown = true;
        channels.last.serverClose();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      // Offline: the banner is up and the stale rows stay.
      await settle(tester);
      expect(find.textContaining('Queue disabled'), findsOneWidget);
      expect(find.text('Skunk'), findsOneWidget);

      // The queue changes while we are out; the server comes back and the
      // backoff reconnect lands.
      await tester.runAsync(() async {
        fx.items.insert(
          0,
          Fixture.track(200002, 0, 'Offline Change', 1202, 400000),
        );
        fx.renumber();
        fx.serverDown = false;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await settle(tester);
      expect(find.textContaining('Queue disabled'), findsNothing);
      expect(find.text('Offline Change'), findsOneWidget);
    });
  });

  // Unit 011 (race candidate from unit 009's Result: the queue chip held a
  // stale count while the server churned): R-11 "queue list matches the
  // server" + R-02 (D2 event → refetch) require per-event refreshes to be
  // serialized — one GET in flight, coalesced trailing refetch, and a
  // superseded response can never overwrite a newer list. Zone note: the
  // gates here are polling flags, not Completers — the fetch chain crosses
  // runAsync zones and a Completer created in the testWidgets (fake-async)
  // zone never resumes a waiter inside runAsync (deadlock: its completion
  // microtasks queue on the paused fake clock).
  group('R-11 refresh serialization (unit 011)', () {
    Future<void> waitUntil(
      WidgetTester tester,
      bool Function() cond,
      String what,
    ) => tester.runAsync(() async {
      for (var i = 0; i < 400 && !cond(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      if (!cond()) fail('$what timed out');
    });

    testWidgets('a superseded fetch answering late must not clobber the '
        'newer list (stale-write race)', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);
      expect(find.text('Skunk'), findsOneWidget);

      // The next queue GET blocks inside the adapter until released,
      // answering from a snapshot taken at REQUEST time (a real server
      // answers from the state it saw handling the request).
      var gateUsed = false;
      var gateArrived = false;
      var gateRelease = false;
      final live = fx.handle;
      adapter.responder = (o) async {
        if (!gateUsed && o.method == 'GET' && o.uri.path == '/api/queue') {
          gateUsed = true;
          final snap = jsonDecode(jsonEncode(fx.items)) as List;
          gateArrived = true;
          for (var i = 0; i < 400 && !gateRelease; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          return jsonResponse(o, {
            'version': 1,
            'count': snap.length,
            'items': snap,
          });
        }
        return live(o);
      };

      // Event 1 → refresh A starts and blocks in the adapter holding the
      // pre-change snapshot (waited for: a blind delay let A's snapshot
      // race past the change and hid a lost trailing refetch).
      await tester.runAsync(() async {
        channels.last.serverSend('{"notify":["queue"]}');
      });
      await waitUntil(tester, () => gateArrived, 'event 1 fetch arrival');

      // External change while A is in flight; event 2 arrives during the
      // same flight — the contract is on the FINAL state: after A lands,
      // the list must show the server's current state (a single-flight
      // impl defers event 2 into a trailing fetch; an unserialized impl
      // lets A's stale response overwrite B's newer one; a skipping impl
      // drops event 2 and keeps the stale list).
      await tester.runAsync(() async {
        fx.items.insert(
          0,
          Fixture.track(200003, 0, 'Fresh Change', 1203, 310000),
        );
        fx.renumber();
        channels.last.serverSend('{"notify":["queue"]}');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });

      gateRelease = true; // A's superseded response lands
      await settle(tester);
      expect(
        find.text('Fresh Change'),
        findsOneWidget,
        reason:
            'the stale response from the superseded fetch overwrote '
            'the newer list (unit 011: per-event refreshes must be '
            'serialized)',
      );
    });

    testWidgets('a burst of queue events keeps at most one GET in flight '
        'and the mid-burst change still lands (trailing refetch)', (
      tester,
    ) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      // Every queue GET is slowed and counted, to observe concurrency;
      // the response body is snapshotted at REQUEST time (response-time
      // reads would hide a lost trailing refetch).
      final live = fx.handle;
      var inFlight = 0;
      var maxInFlight = 0;
      var arrivals = 0;
      adapter.responder = (o) async {
        if (o.method == 'GET' && o.uri.path == '/api/queue') {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          final snap = jsonDecode(jsonEncode(fx.items)) as List;
          arrivals++;
          try {
            // A ONLY, 150 ms: 6× the burst's ~25 ms firing window, so
            // late handling cannot slip past the flight even under CI
            // timer stretch (PR #4 review nit; a 45 ms hold left 20 ms
            // of headroom — an 80 ms-spacing mutation slipped past it
            // and a skipping impl survived). The trailing refetch must
            // answer promptly so the test can observe it.
            if (arrivals == 1) {
              await Future<void>.delayed(const Duration(milliseconds: 150));
            }
            return jsonResponse(o, {
              'version': 1,
              'count': snap.length,
              'items': snap,
            });
          } finally {
            inFlight--;
          }
        }
        return live(o);
      };

      // Event 1 → fetch A starts against the OLD list. The external
      // change lands only AFTER A's request has arrived (deterministic
      // gate); four more events pile on that same flight (the unit 009
      // churn pattern).
      await tester.runAsync(() async {
        channels.last.serverSend('{"notify":["queue"]}');
      });
      await waitUntil(tester, () => arrivals >= 1, 'event 1 fetch arrival');
      // Delivery-confirmed gate (unit 012, PR #4 re-review nit): a
      // probe listener on the SAME stream the controller listens to,
      // registered AFTER it — broadcast dispatch runs listeners in
      // registration order, so probe==4 proves the controller's handler
      // (and its guard check) already saw all four burst events; a
      // stalled delivery becomes an honest red at the gate below
      // instead of silently sparing a skipping impl. No mid-test
      // cancel (from the fake zone it hangs the next runAsync —
      // observed); the conn is disposed in tearDown.
      var probe = 0;
      await tester.runAsync(() async {
        conn.events.listen((e) {
          if (e.contains('queue')) probe++;
        });
        fx.items.insert(
          0,
          Fixture.track(200004, 0, 'Burst Track', 1204, 320000),
        );
        fx.renumber();
        for (var i = 0; i < 4; i++) {
          channels.last.serverSend('{"notify":["queue"]}');
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      // A's hold ticks on real time, which flows only inside settle()'s
      // runAsync window (80 ms) — iterate settles until the coalesced
      // trailing fetch has reached the server, then one more to answer
      // and paint it.
      for (var i = 0; i < 6 && arrivals < 2; i++) {
        await settle(tester);
      }
      await settle(tester);
      expect(
        arrivals,
        2,
        reason:
            'A plus EXACTLY one coalesced trailing refetch — a third '
            'GET means per-event fetches slipped through the guard, '
            'one means the trailing refetch was lost (unit 011)',
      );
      expect(
        find.text('Burst Track'),
        findsOneWidget,
        reason:
            'events arriving during the in-flight fetch were lost — '
            'they must coalesce into a trailing refetch (R-11: the '
            'list matches the server)',
      );
      expect(
        maxInFlight,
        1,
        reason:
            'per-event refreshes must be single-flight: $maxInFlight '
            'concurrent GET /api/queue observed (unit 011)',
      );
      expect(
        probe,
        4,
        reason:
            'all four burst events must have been HANDLED by the '
            'controller before the outcome was judged — a stalled '
            'delivery would otherwise spare a skipping impl (unit 012 '
            'delivery gate)',
      );
    });
  });

  group('R-11 offline', () {
    testWidgets('offline: banner + stale rows, taps inert', (tester) async {
      await tester.runAsync(wireUp);
      await pumpScreen(tester, const QueueScreen());
      await settle(tester);

      await tester.runAsync(() async {
        fx.serverDown = true;
        channels.last.serverClose();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await settle(tester);
      expect(
        find.text('Server unreachable — retrying. Queue disabled.'),
        findsOneWidget,
      );
      expect(find.text('Skunk'), findsOneWidget);

      // Taps do nothing while offline (neither the queue-replacing add
      // nor the issue #21 skip call is recorded — the backoff retries
      // also hit the adapter, so compare counts on the two action paths).
      int countOf(String needle) =>
          adapter.requests.where((r) => r.contains(needle)).length;
      final addsBefore = countOf('/items/add');
      final skipsBefore = countOf('/api/player/play');
      await tester.tap(find.text('Skunk'));
      await settle(tester);
      expect(countOf('/items/add'), addsBefore);
      expect(
        countOf('/api/player/play'),
        skipsBefore,
        reason: 'offline row taps must fire the skip neither',
      );
    });
  });

  testWidgets('now-playing entry: "Queue · N" opens the queue screen', (
    tester,
  ) async {
    await tester.runAsync(wireUp);
    await pumpScreen(tester, const NowPlayingScreen());
    await settle(tester);
    expect(find.text('Queue · 3'), findsOneWidget);

    await tester.tap(find.text('Queue · 3'));
    await settle(tester);
    expect(find.text('Skunk'), findsOneWidget);
  });
}

/// A minimal live-shaped fixture: the three-item queue, a mutable player
/// item_id, and per-endpoint failure switches.
class Fixture {
  int? itemId = 196174;

  final List<Map<String, dynamic>> items = [
    track(196174, 0, 'Skunk', 1195, 343835),
    track(196175, 1, 'Blues in the Attic', 1194, 242640),
    track(196176, 2, 'House Party', 1193, 250720),
  ];

  bool failQueueGet = false;
  bool failClear = false;
  bool failPlay = false;

  /// Issue #21: when true, the queue-skip call (`PUT /api/player/play
  /// ?item_id=…`) fails, so the snackbar path can be asserted.
  bool failSkip = false;

  /// R-23 (issue #46): when true, the drag-reorder PUT fails, so the
  /// rollback + snackbar path can be asserted.
  bool failMove = false;

  /// R-24 (issue #47): when true, the per-row remove DELETE fails with a
  /// 500, so the rollback + snackbar path can be asserted.
  bool failRemove = false;

  /// Fresh ids for added entries (210000+ keeps them clear of the
  /// 196xxx/200xxx ids other tests insert).
  int _addId = 210000;

  /// While true, REST calls fail and new WS handshakes fail — the app stays
  /// in its offline state until this is cleared (the unit 002 dropServer
  /// pattern), so a test can observe the offline window before the backoff
  /// reconnect lands.
  bool serverDown = false;

  static Map<String, dynamic> track(
    int id,
    int position,
    String title,
    int trackId,
    int lengthMs,
  ) => {
    'id': id,
    'position': position,
    'track_id': trackId,
    'title': title,
    'artist': 'Muse',
    'album': 'Absolution',
    'length_ms': lengthMs,
    'uri': 'library:track:$trackId',
  };

  /// Keep the wire `position` field in list order (the server always does).
  void renumber() {
    for (var i = 0; i < items.length; i++) {
      items[i]['position'] = i;
    }
  }

  Map<String, dynamic> get _playerJson => {
    'state': 'stop',
    'volume': 50,
    'item_id': itemId,
    'item_length_ms': 343835,
    'item_progress_ms': 0,
  };

  Response<dynamic> handle(RequestOptions o) {
    if (serverDown) {
      throw networkError(
        o,
        socketFailure('Connection refused (ECONNREFUSED)', 111),
      );
    }
    final p = o.uri.path;
    if (p.startsWith('/api/queue') && failQueueGet && o.method == 'GET') {
      throw DioException(
        requestOptions: o,
        type: DioExceptionType.badResponse,
        response: Response(requestOptions: o, statusCode: 500),
      );
    }
    // R-23 (issue #46): drag-reorder. Server-true semantics per the
    // official json-api docs (verified 2026-11-20): `new_position` is the
    // entry's FINAL index — a MOVE (remove + insert), not a swap — and
    // 204 on success.
    final itemMatch = RegExp(r'^/api/queue/items/(\d+)$').firstMatch(p);
    if (itemMatch != null) {
      final id = int.parse(itemMatch.group(1)!);
      // R-24 (issue #47): per-row remove. Server-true semantics per the
      // official json-api docs (docs-mcp 2026-11-20): 204, the entry is
      // gone, remaining entries renumber. Keyed on the ENTRY id (never
      // an index — mirror of OwntoneApi.deleteQueueItem).
      if (o.method == 'DELETE') {
        if (failRemove) {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 500),
          );
        }
        final at = items.indexWhere((e) => e['id'] == id);
        if (at == -1) return Response(requestOptions: o, statusCode: 404);
        items.removeAt(at);
        renumber();
        return Response(requestOptions: o, statusCode: 204);
      }
      if (o.method != 'PUT') {
        return Response(requestOptions: o, statusCode: 405);
      }
      if (failMove) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: o, statusCode: 500),
        );
      }
      final from = items.indexWhere((e) => e['id'] == id);
      if (from == -1) return Response(requestOptions: o, statusCode: 404);
      final to = int.tryParse(o.uri.queryParameters['new_position'] ?? '');
      if (to == null) return Response(requestOptions: o, statusCode: 400);
      final moved = items.removeAt(from);
      items.insert(to.clamp(0, items.length), moved);
      renumber();
      return Response(requestOptions: o, statusCode: 204);
    }
    switch (p) {
      case '/api/config':
        return jsonResponse(o, {'websocket_port': 3688, 'version': '29.3'});
      case '/api/player':
        return jsonResponse(o, _playerJson);
      case '/api/outputs':
        return jsonResponse(o, {'outputs': []});
      case '/api/queue':
        return jsonResponse(o, {
          'version': 1,
          'count': items.length,
          'items': items,
        });
      case '/api/queue/clear':
        if (failClear) {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 500),
          );
        }
        items.clear();
        return Response(requestOptions: o, statusCode: 204);
      case '/api/player/play':
        // Issue #21: the in-place queue-skip. Server-true semantics —
        // item_id moves to the named ENTRY, the items[] list is untouched
        // (no add, no clear ever reaches this branch from a row tap).
        if (o.method != 'PUT') {
          return Response(requestOptions: o, statusCode: 405);
        }
        if (failSkip) {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 500),
          );
        }
        final id = int.tryParse(o.uri.queryParameters['item_id'] ?? '');
        if (id == null || !items.any((e) => e['id'] == id)) {
          return Response(requestOptions: o, statusCode: 404);
        }
        itemId = id;
        return Response(requestOptions: o, statusCode: 204);
      case '/api/queue/items/add':
        if (failPlay) {
          throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 500),
          );
        }
        final q = o.uri.queryParameters;
        final uris = (q['uris'] ?? '').split(',');
        final shouldClear = q['clear'] == 'true';
        if (shouldClear) items.clear();
        // Expand each uri as one fresh entry (the server expands containers;
        // the fixture's uris are all tracks). R-24 (issue #47): `position`
        // honoured per the official docs — "items are inserted starting
        // from this position" (the first lands AT it); omitted → tail
        // append (out-of-range is deliberately NOT modelled: every caller
        // pins an in-range position, see OwntoneApi.addUris).
        final at = int.tryParse(q['position'] ?? '');
        for (var i = 0; i < uris.length; i++) {
          final m = RegExp(r'library:track:(\d+)').firstMatch(uris[i]);
          items.insert(
            (at == null ? items.length : at + i).clamp(0, items.length),
            track(
              _addId++,
              0,
              'Added ${uris[i]}',
              int.parse(m?.group(1) ?? '0'),
              100000,
            ),
          );
        }
        renumber();
        return jsonResponse(o, {
          'version': 2,
          'count': items.length,
          'items': items,
        });
      default:
        return Response(requestOptions: o, statusCode: 404);
    }
  }
}
